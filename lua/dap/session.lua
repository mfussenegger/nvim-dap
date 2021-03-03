local api = vim.api
local uv = vim.loop

local log = require('dap.log').create_logger('dap.log')
local reloadable = require('dap.reloadable')
local repl = require('dap.repl')
local rpc = require('dap.rpc')
local ui = require('dap.ui')
local utils = require('dap.utils')

local ns_pos = require('dap.constants').ns_pos

local non_empty = utils.non_empty
local convert_nil = utils.convert_nil

local function launch_external_terminal(terminal, args)
  local handle
  local pid_or_err
  local full_args = {}
  vim.list_extend(full_args, terminal.args or {})
  vim.list_extend(full_args, args)
  local opts = {
    args = full_args,
    detached = true
  }
  handle, pid_or_err = uv.spawn(terminal.command, opts, function(code)
    handle:close()
    if code ~= 0 then
      print('Terminal exited', code, 'running', terminal.command, table.concat(full_args, ' '))
    end
  end)
  return handle, pid_or_err
end

local get_default = function(key)
  return require('dap').defaults[key]
end

local get_custom_response_handler = function(key)
  return require('dap').custom_response_handlers[key]
end

local get_custom_event_handler = function(key)
  return require('dap').custom_event_handlers['event_' .. key]
end

local function session_defaults(opts)
  return {
    handlers = { after = opts.after };
    message_callbacks = {};
    message_requests = {};
    initialized = false;
    seq = 0;
    stopped_thread_id = nil;
    current_frame = nil;
    threads = {};
  }
end


local Session = {}
Session.__index = Session

function Session:spawn(adapter, opts)
  local o = setmetatable(session_defaults(opts or {}), self)

  local stdin = uv.new_pipe(false)
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)
  local handle
  local function onexit()
    stdin:close()
    stdout:close()
    stderr:close()
    handle:close()
  end
  local options = adapter.options or {}
  local pid_or_err
  handle, pid_or_err = uv.spawn(adapter.command, {
    args = adapter.args;
    stdio = {stdin, stdout, stderr};
    cwd = options.cwd;
    env = options.env;
    detached = true;
  }, onexit)
  assert(handle, 'Error running ' .. adapter.command .. ': ' .. pid_or_err)
  o.client = {
    write = function(line) stdin:write(line) end;
    close = function()
      if handle then
        pcall(handle.close, handle)
      end
    end;
  }

  stdout:read_start(rpc.create_read_loop(function(body)
    self:handle_body(body)
  end))

  stderr:read_start(function(err, chunk)
    assert(not err, err)
    local _ = chunk and log.error() and log.error("stderr", adapter, chunk)
  end)

  return o
end

function Session:connect(host, port, opts)
  local o = setmetatable(session_defaults(opts or {}), self)

  local client = uv.new_tcp()
  o.client = {
    write = function(line) client:write(line) end;
    close = function()
      client:shutdown()
      client:close()
    end;
  }
  client:connect(host or '127.0.0.1', tonumber(port), function(err)
    if (err) then print(err) end
  end)
  client:read_start(rpc.create_read_loop(function(body) self:handle_body(body) end))
  return o
end


function Session:handle_body(body)
  if self.closed then
    return
  end

  local decoded = convert_nil(vim.fn.json_decode(body))
  self.seq = decoded.seq + 1
  local _ = log.debug() and log.debug(decoded)
  if decoded.request_seq then
    local callback = self.message_callbacks[decoded.request_seq]
    local request = self.message_requests[decoded.request_seq]
    if not callback then
      log.warn('No callback for ', decoded)
      return
    end
    self.message_callbacks[decoded.request_seq] = nil
    self.message_requests[decoded.request_seq] = nil
    if decoded.success then
      vim.schedule(function()
        callback(nil, decoded.body)
        for _, c in pairs(get_custom_response_handler(decoded.command)) do
          c(self, decoded.body, request)
        end
      end)
    else
      vim.schedule(function()
        callback({ message = decoded.message; body = decoded.body; }, nil)
      end)
    end
  elseif decoded.event then
    local callback = self['event_' .. decoded.event]
    if callback then
      vim.schedule(function()
        callback(self, decoded.body)
        for _, c in pairs(get_custom_event_handler(decoded.event)) do
          c(self, decoded.body)
        end
      end)
    else
      log.warn('No event handler for ', decoded)
    end
  elseif decoded.type == 'request' and decoded.command == 'runInTerminal' then
    self:run_in_terminal(decoded)
  else
    local _ = log.warn() and log.warn('Received unexpected message', decoded)
  end
end

function Session:close()
  self.closed = true

  vim.fn.sign_unplace(ns_pos)
  self.threads = {}
  self.message_callbacks = {}
  self.message_requests = {}
  self.client.close()
  repl.set_session(nil)
end

function Session:set_terminal(buf)
  assert(self and buf)

  reloadable.set_value('SessionTerminalBuf', buf)
end

function Session:get_terminal()
  reloadable.get_value('SessionTerminalBuf')
end

function Session:run_in_terminal(request)
  local body = request.arguments
  local _ = log.debug() and log.debug('run_in_terminal', body)
  if body.kind == 'external' then
    local terminal = get_default(self.config.type).external_terminal

    if not terminal then
      print('Requested external terminal, but none configured. Fallback to integratedTerminal')
    else
      local handle, pid = launch_external_terminal(terminal, body.args)
      if not handle then
        print('Could not launch terminal', terminal.command)
      end
      self:response(request, {
        success = handle ~= nil;
        body = { processId = pid; };
      })
      return
    end
  end
  local win = api.nvim_get_current_win()
  if self:get_terminal() and api.nvim_buf_is_valid(self:get_terminal()) then
    api.nvim_buf_delete(self:get_terminal(), {force=true})
  end
  api.nvim_command('belowright new')
  self:set_terminal(api.nvim_get_current_buf())
  local opts = {
    clear_env = false;
    env = non_empty(body.env) and body.env or vim.empty_dict()
  }
  local jobid = vim.fn.termopen(body.args, opts)
  api.nvim_set_current_win(win)
  if jobid == 0 or jobid == -1 then
    local _ = log.error() and log.error('Could not spawn terminal', jobid, request)
    self:response(request, {
      success = false;
      message = 'Could not spawn terminal';
    })
  else
    self:response(request, {
      success = true;
      body = {
        processId = vim.fn.jobpid(jobid);
      };
    })
  end
end

function Session:event_initialized(_)
  local function on_done()
    if self.capabilities.supportsConfigurationDoneRequest then
      self:request('configurationDone', nil, function(err1, _)
        if err1 then
          print(err1.message)
        end
        self.initialized = true
      end)
    else
      self.initialized = true
    end
  end

  self:set_breakpoints(nil, function()
    if self.capabilities.exceptionBreakpointFilters then
      self:set_exception_breakpoints(get_default(self.config.type).exception_breakpoints, nil, on_done)
    else
      on_done()
    end
  end)
end

function Session:request(command, arguments, callback)
  local payload = {
    seq = self.seq;
    type = 'request';
    command = command;
    arguments = arguments
  }
  local _ = log.debug() and log.debug('request', payload)
  local current_seq = self.seq
  self.seq = self.seq + 1
  vim.schedule(function()
    local msg = rpc.msg_with_content_length(vim.fn.json_encode(payload))
    self.client.write(msg)
    if callback then
      self.message_callbacks[current_seq] = callback
      self.message_requests[current_seq] = arguments
    end
  end)
end


function Session:response(request, payload)
  payload.seq = self.seq
  self.seq = self.seq + 1
  payload.type = 'response'
  payload.request_seq = request.seq;
  payload.command = request.command;
  local _ = log.debug() and log.debug('response', payload)
  vim.schedule(function()
    local msg = rpc.msg_with_content_length(vim.fn.json_encode(payload))
    self.client.write(msg)
  end)
end


function Session:initialize(config)
  self.config = config
  self:request('initialize', {
    clientId = 'neovim';
    clientname = 'neovim';
    adapterID = 'nvim-dap';
    pathFormat = 'path';
    columnsStartAt1 = true;
    linesStartAt1 = true;
    supportsRunInTerminalRequest = true;
    locale = os.getenv('LANG') or 'en_US';
  }, function(err0, result)
    if err0 then
      print("Could not initialize debug adapter: " .. err0.message)
      return
    end
    self.capabilities = result
    self:request(config.request, config, function(err)
      if err then
        print(string.format('Error on %s: %s', config.request, err.message))
        self:close()
        return
      end
      repl.set_session(self)
    end)
  end)
end


function Session:evaluate(expression, fn)
  self:request('evaluate', {
    expression = expression;
    context = 'repl';
    frameId = (self.current_frame or {}).id;
  }, fn)
end


function Session:disconnect()
  self:request('disconnect', {
    restart = false,
    terminateDebuggee = true;
  })
end

function Session:_pause_thread(thread_id)
  self:request('pause', { threadId = thread_id; }, function(err)
    if err then
      print('Error pausing: ' .. err.message)
    else
      print('Thread paused', thread_id)
    end
  end)
end

function Session:_pause(thread_id)
  if self.stopped_thread_id then
    print('One thread is already stopped. Cannot pause!')
    return
  end
  if thread_id then
    self:_pause_thread(thread_id)
    return
  end
  self:request('threads', nil, function(err0, response)
    if err0 then
      print('Error requesting threads: ' .. err0.message)
      return
    end
    ui.pick_one(
      response.threads,
      "Which thread?: ",
      function(t) return t.name end,
      function(thread)
        if not thread or not thread.id then
          print('No thread to stop. Not pausing...')
        else
          self:_pause_thread(thread.id)
        end
      end
    )
  end)
end


function Session:_step(step)
  if vim.tbl_contains({"stepBack", "reverseContinue"}, step) and not self.capabilities.supportsStepBack then
    print("Debug Adapter does not support "..step.."!")
    return
  end
  if not self.stopped_thread_id then
    print('No stopped thread. Cannot move')
    return
  end
  local thread_id = self.stopped_thread_id
  self.stopped_thread_id = nil
  vim.fn.sign_unplace(ns_pos)
  self:request(step, { threadId = thread_id; }, function(err0, _)
    if err0 then
      print('Error on '.. step .. ': ' .. err0.message)
    end
  end)
end



return Session
