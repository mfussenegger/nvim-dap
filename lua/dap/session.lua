local uv = vim.loop
local api = vim.api
local rpc = require('dap.rpc')

local utils = require('dap.utils')
local breakpoints = require('dap.breakpoints')
local progress = require('dap.progress')
local log = require('dap.log').create_logger('dap.log')
local non_empty = utils.non_empty
local index_of = utils.index_of

local Session = {}
local ns_pos = 'dap_pos'
local terminal_buf


local function dap()
  return require('dap')
end

local function ui()
  return require('dap.ui')
end


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


function Session:run_in_terminal(request)
  local body = request.arguments
  log.debug('run_in_terminal', body)
  local settings = dap().defaults[self.config.type]
  if body.kind == 'external' or (settings.force_external_terminal and settings.external_terminal) then
    local terminal = settings.external_terminal
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
  if terminal_buf and api.nvim_buf_is_valid(terminal_buf) then
    api.nvim_buf_delete(terminal_buf, {force=true})
  end
  local cur_buf = api.nvim_get_current_buf()
  api.nvim_command(dap().defaults[self.config.type].terminal_win_cmd)
  terminal_buf = api.nvim_get_current_buf()
  local ok, path = pcall(api.nvim_buf_get_option, cur_buf, 'path')
  if ok then
    api.nvim_buf_set_option(terminal_buf, 'path', path)
  end
  local opts = {
    clear_env = false;
    env = next(body.env or {}) and body.env or vim.empty_dict()
  }
  local jobid = vim.fn.termopen(body.args, opts)
  api.nvim_set_current_win(win)
  if jobid == 0 or jobid == -1 then
    log.error('Could not spawn terminal', jobid, request)
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


function Session:event_initialized()
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
      self:set_exception_breakpoints(dap().defaults[self.config.type].exception_breakpoints, nil, on_done)
    else
      on_done()
    end
  end)
end


function Session:_show_exception_info()
  if not self.capabilities.supportsExceptionInfoRequest then return end

  -- exceptionInfo (https://microsoft.github.io/debug-adapter-protocol/specification#Requests_ExceptionInfo)
  --- threadId: number
  self:request('exceptionInfo', {threadId = self.stopped_thread_id}, function(err, response)
    if err then
      print("Error getting exception info: "..err.message)
    end

    -- ExceptionInfoResponse
    --- exceptionId: string
    --- description?: string
    --- breakMode: ExceptionBreakMode (https://microsoft.github.io/debug-adapter-protocol/specification#Types_ExceptionBreakMode)
    --- details?: ExceptionDetails (https://microsoft.github.io/debug-adapter-protocol/specification#Types_ExceptionDetails)
    if response then
      local exception_type = response.details and response.details.typeName
      local of_type = exception_type and ' of type '..exception_type or ''
      local repl = require('dap.repl')
      repl.append('Thread stopped due to exception'..of_type..' ('..response.breakMode..')')
      if response.description then
        repl.append('Description: '..response.description)
      end
      -- ExceptionDetails (https://microsoft.github.io/debug-adapter-protocol/specification#Types_ExceptionDetails)
      --- message?: string
      --- typeName?: string
      --- fullTypeName?: string
      --- evaluateName?: string
      --- stackTrace?: string
      --- innerException?: ExceptionDetails[]
      if response.details then
        if response.details.stackTrace then
          repl.append("Stack trace:")
          repl.append(response.details.stackTrace)
        end
        if response.details.innerException then
          repl.append("Inner Exceptions:")
          for _, e in pairs(response.details.innerException) do
            repl.append(vim.inspect(e))
          end
        end
      end
    end
  end)
end


local function with_win(win, fn, ...)
  local cur_win = api.nvim_get_current_win()
  api.nvim_set_current_win(win)
  local ok, err = pcall(fn, ...)
  api.nvim_set_current_win(cur_win)
  assert(ok, err)
end


local function jump_to_location(bufnr, line, column)
  local ok, failure = pcall(vim.fn.sign_place, 0, ns_pos, 'DapStopped', bufnr, { lnum = line; priority = 12 })
  if not ok then
    print(failure)
  end
  progress.report('Stopped at line ' .. line)
  -- vscode-go sends columns with 0
  -- That would cause a "Column value outside range" error calling nvim_win_set_cursor
  -- nvim-dap says "columnsStartAt1 = true" on initialize :/
  if column == 0 then
    column = 1
  end
  for _, win in pairs(api.nvim_tabpage_list_wins(0)) do
    if api.nvim_win_get_buf(win) == bufnr then
      api.nvim_win_set_cursor(win, { line, column - 1 })
      with_win(win, api.nvim_command, 'normal zv')
      return
    end
  end
  -- Buffer isn't active in any window; use the first window that is not special
  -- (Don't want to move to code in the REPL...)
  for _, win in pairs(api.nvim_tabpage_list_wins(0)) do
    local winbuf = api.nvim_win_get_buf(win)
    if api.nvim_buf_get_option(winbuf, 'buftype') == '' then
      local bufchanged, _ = pcall(api.nvim_win_set_buf, win, bufnr)
      if bufchanged then
        api.nvim_win_set_cursor(win, { line, column - 1 })
        with_win(win, api.nvim_command, 'normal zv')
        return
      end
    end
  end
end


local function jump_to_frame(cur_session, frame, preserve_focus_hint)
  local source = frame.source
  if not source then
    print('Source not available, cannot jump to frame')
    return
  end
  vim.fn.sign_unplace(ns_pos)
  if preserve_focus_hint or frame.line < 0 then
    return
  end
  if not source.sourceReference or source.sourceReference == 0 then
    if not source.path then
      print('Source path not available, cannot jump to frame')
      return
    end
    local scheme = source.path:match('^([a-z]+)://.*')
    local bufnr
    if scheme then
      bufnr = vim.uri_to_bufnr(source.path)
    else
      bufnr = vim.uri_to_bufnr(vim.uri_from_fname(source.path))
    end
    vim.fn.bufload(bufnr)
    jump_to_location(bufnr, frame.line, frame.column)
  else
    local params = {
      source = source,
      sourceReference = source.sourceReference
    }
    cur_session:request('source', params, function(err, response)
      assert(not err, vim.inspect(err))

      local buf = api.nvim_create_buf(false, true)
      api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(response.content, '\n'))
      jump_to_location(buf, frame.line, frame.column)
    end)
  end
end

function Session:event_stopped(stopped)
  if self.stopped_thread_id then
    log.debug('Thread stopped, but another thread is already stopped, telling thread to continue')
    self:request('continue', { threadId = stopped.threadId })
    return
  end
  progress.report('Thread stopped: ' .. stopped.threadId)
  self.stopped_thread_id = stopped.threadId
  self:request('threads', nil, function(err0, threads_resp)
    if err0 then
      print('Error retrieving threads: ' .. err0.message)
      return
    end
    local threads = {}
    self.threads = threads
    for _, thread in pairs(threads_resp.threads) do
      threads[thread.id] = thread
    end

    if stopped.reason == 'exception' then
      self:_show_exception_info()
    end

    self:request('stackTrace', { threadId = stopped.threadId; }, function(err1, frames_resp)
      if err1 then
        print('Error retrieving stack traces: ' .. err1.message)
        return
      end
      local frames = {}
      local current_frame = nil
      self.current_frame = nil
      threads[stopped.threadId].frames = frames
      for _, frame in pairs(frames_resp.stackFrames) do
        if not current_frame and frame.source and frame.source.path then
          current_frame = frame
          self.current_frame = frame
        end
        table.insert(frames, frame)
      end
      if not current_frame then
        if #frames > 0 then
          current_frame = frames[1]
          self.current_frame = current_frame
        else
          return
        end
      end
      local preserve_focus
      if stopped.reason ~= 'pause' then
        preserve_focus = stopped.preserveFocusHint
      end
      jump_to_frame(self, current_frame, preserve_focus)
      self:_request_scopes(current_frame)
    end)
  end)
end


function Session:event_terminated()
  self:close()
  if self.handlers.after then
    self.handlers.after()
  end
  dap()._reset_session()
end


function Session.event_output(_, body)
  require('dap.repl').append(body.output, '$')
end


function Session:_request_scopes(current_frame)
  self:request('scopes', { frameId = current_frame.id }, function(_, scopes_resp)
    if not scopes_resp or not scopes_resp.scopes then return end

    current_frame.scopes = {}
    for _, scope in pairs(scopes_resp.scopes) do

      table.insert(current_frame.scopes, scope)
      if not scope.expensive then
        self:request('variables', { variablesReference = scope.variablesReference }, function(_, variables_resp)
          if not variables_resp then return end

          scope.variables = utils.to_dict(
            variables_resp.variables,
            function(v) return v.name end
          )
        end)
      end
    end
  end)
end


--- Goto specified line (source and col are optional)
function Session:_goto(line, source, col)
  local frame = self.current_frame
  if not frame then
    return
  end
  if not self.capabilities.supportsGotoTargetsRequest then
    print("Debug Adapter doesn't support GotoTargetRequest")
    return
  end
  self:request('gotoTargets',  {source = source or frame.source, line = line, col = col}, function(err, response)
    if err then
      print('Error getting gotoTargets: ' .. err.message)
      return
    end
    if not response or not response.targets then
      print("No goto targets available. Can't execute goto")
      return
    end
    local params = {threadId = self.stopped_thread_id, targetId = response.targets[1].id }
    self:request('goto', params, function(err1, _)
      if err1 then
        print('Error executing goto: ' .. err1.message)
      end
    end)
  end)
end


do
  local function notify_if_missing_capability(bufnr, bps, capabilities)
    for _, bp in pairs(bps) do
      if non_empty(bp.condition) and not capabilities.supportsConditionalBreakpoints then
        print("Debug adapter doesn't support breakpoints with conditions", bufnr, bp.line)
      end
      if non_empty(bp.hitCondition) and not capabilities.supportsHitConditionalBreakpoints then
        print("Debug adapter doesn't support breakpoints with hit conditions", bufnr, bp.line)
      end
      if non_empty(bp.logMessage) and not capabilities.supportsLogPoints then
        print("Debug adapter doesn't support log points", bufnr, bp.line)
      end
    end
  end

  function Session:set_breakpoints(bufexpr, on_done)
    local bps = breakpoints.get(bufexpr)
    local num_requests = vim.tbl_count(bps)
    if num_requests == 0 then
      if on_done then
        on_done()
      end
      return
    end
    for bufnr, buf_bps in pairs(bps) do
      notify_if_missing_capability(bufnr, buf_bps, self.capabilities)
      local path = api.nvim_buf_get_name(bufnr)
      local payload = {
        source = {
          path = path;
          name = vim.fn.fnamemodify(path, ':t')
        };
        breakpoints = buf_bps;
        lines = vim.tbl_map(function(x) return x.line end, buf_bps);
      }
      self:request('setBreakpoints', payload, function(err1, resp)
        if err1 then
          print("Error setting breakpoints: " .. err1.message)
        else
          for _, bp in pairs(resp.breakpoints) do
            breakpoints.set_state(bufnr, bp.line, bp)
            if not bp.verified then
              log.info('Server rejected breakpoint', bp)
              if bp.message then
                vim.notify(bp.message)
              end
            end
          end
        end
        num_requests = num_requests - 1
        if num_requests == 0 and on_done then
          on_done()
        end
      end)
    end
  end
end

function Session:set_exception_breakpoints(filters, exceptionOptions, on_done)
  if not self.capabilities.exceptionBreakpointFilters then
    print("Debug adapter doesn't support exception breakpoints")
    return
  end

  if filters == 'default' then
    local default_filters = {}
    for _, f in pairs(self.capabilities.exceptionBreakpointFilters) do
      if f.default then
        table.insert(default_filters, f.filter)
      end
    end
    filters = default_filters
  end

  if not filters then
    local possible_filters = {}
    for _, f in ipairs(self.capabilities.exceptionBreakpointFilters) do
      table.insert(possible_filters, f.filter)
    end
    filters = vim.split(vim.fn.input("Exception breakpoint filters: ", table.concat(possible_filters, ' ')), ' ')
  end

  if exceptionOptions and not self.capabilities.supportsExceptionOptions then
    print("Debug adapter does not support ExceptionOptions")
    return
  end

  -- setExceptionBreakpoints (https://microsoft.github.io/debug-adapter-protocol/specification#Requests_SetExceptionBreakpoints)
  --- filters: string[]
  --- exceptionOptions: exceptionOptions?: ExceptionOptions[] (https://microsoft.github.io/debug-adapter-protocol/specification#Types_ExceptionOptions)
  self:request(
    'setExceptionBreakpoints',
    { filters = filters, exceptionOptions = exceptionOptions },
    function(err, _)
      if err then
        print("Error setting exception breakpoints: "..err.message)
      end
      if on_done then
        on_done()
      end
  end)
end


local NIL = vim.NIL
local function convert_nil(v)
  if v == NIL then
    return nil
  elseif type(v) == 'table' then
    return vim.tbl_map(convert_nil, v)
  else
    return v
  end
end


function Session:handle_body(body)
  local decoded = convert_nil(vim.fn.json_decode(body))
  log.debug(decoded)
  local listeners = dap().listeners
  if decoded.request_seq then
    local callback = self.message_callbacks[decoded.request_seq]
    local request = self.message_requests[decoded.request_seq]
    self.message_requests[decoded.request_seq] = nil
    self.message_callbacks[decoded.request_seq] = nil
    if not callback then
      log.warn('No callback for ', decoded)
      return
    end
    if decoded.success then
      vim.schedule(function()
        for _, c in pairs(listeners.before[decoded.command]) do
          c(self, nil, decoded.body, request)
        end
        callback(nil, decoded.body)
        for _, c in pairs(listeners.after[decoded.command]) do
          c(self, nil, decoded.body, request)
        end
      end)
    else
      vim.schedule(function()
        local err = { message = decoded.message; body = decoded.body; }
        for _, c in pairs(listeners.before[decoded.command]) do
          c(self, err, nil, request)
        end
        callback(err, nil)
        for _, c in pairs(listeners.after[decoded.command]) do
          c(self, err, nil, request)
        end
      end)
    end
  elseif decoded.event then
    local callback = self['event_' .. decoded.event]
    vim.schedule(function()
      local event_handled = false
      for _, c in pairs(listeners.before['event_' .. decoded.event]) do
        event_handled = true
        c(self, decoded.body)
      end
      if callback then
        event_handled = true
        callback(self, decoded.body)
      end
      for _, c in pairs(listeners.after['event_' .. decoded.event]) do
        event_handled = true
        c(self, decoded.body)
      end
      if not event_handled then
        log.warn('No event handler for ', decoded)
      end
    end)
  elseif decoded.type == 'request' and decoded.command == 'runInTerminal' then
    self:run_in_terminal(decoded)
  else
    log.warn('Received unexpected message', decoded)
  end
end


local function session_defaults(opts)
  local handlers = {}
  handlers.after = opts.after
  return {
    handlers = handlers;
    message_callbacks = {};
    message_requests = {};
    initialized = false;
    seq = 0;
    stopped_thread_id = nil;
    current_frame = nil;
    threads = {};
  }
end


function Session:connect(host, port, opts)
  local session = session_defaults(opts or {})
  setmetatable(session, self)
  self.__index = self

  local client = uv.new_tcp()
  session.client = {
    write = function(line) client:write(line) end;
    close = function()
      client:shutdown()
      client:close()
    end;
  }
  client:connect(host or '127.0.0.1', tonumber(port), function(err)
    if (err) then print(err) end
    client:read_start(rpc.create_read_loop(function(body)
      session:handle_body(body)
    end))
  end)
  return session
end


function Session:spawn(adapter, opts)
  local session = session_defaults(opts or {})
  setmetatable(session, self)
  self.__index = self

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
  session.client = {
    write = function(line) stdin:write(line) end;
    close = function()
      if handle then
        pcall(handle.close, handle)
      end
    end;
  }
  stdout:read_start(rpc.create_read_loop(function(body)
    session:handle_body(body)
  end))
  stderr:read_start(function(err, chunk)
    assert(not err, err)
    if chunk then
      log.error("stderr", adapter, chunk)
    end
  end)
  return session
end


local function pause_thread(session, thread_id)
  assert(session, 'Cannot pause thread without active session')
  assert(thread_id, 'thread_id is required to pause thread')

  session:request('pause', { threadId = thread_id; }, function(err)
    if err then
      print('Error pausing: ' .. err.message)
    else
      print('Thread paused', thread_id)
    end
  end)
end


function Session:_pause(thread_id)
  if self.stopped_thread_id then
    print(
      'Thread', self.stopped_thread_id, 'is stopped.',
      'Cannot pause another one. Use `continue()` to resume paused thread.'
    )
    return
  end
  if thread_id then
    pause_thread(self, thread_id)
    return
  end
  self:request('threads', nil, function(err0, response)
    if err0 then
      print('Error requesting threads: ' .. err0.message)
      return
    end
    ui().pick_if_many(
      response.threads,
      "Which thread?: ",
      function(t) return t.name end,
      function(thread)
        if not thread or not thread.id then
          print('No thread to stop. Not pausing...')
        else
          pause_thread(self, thread.id)
        end
      end
    )
  end)
end


function Session:_step(step, params)
  if not self.stopped_thread_id then
    print('No stopped thread. Cannot move')
    return
  end
  vim.fn.sign_unplace(ns_pos)
  params = params or {}
  params.threadId = self.stopped_thread_id
  if not params.granularity then
    params.granularity = dap().defaults[self.config.type].stepping_granularity
  end
  self.stopped_thread_id = nil
  self:request(step, params, function(err)
    if err then
      print('Error on '.. step .. ': ' .. err.message)
    end
    progress.report('Running')
  end)
end



function Session:close()
  vim.fn.sign_unplace(ns_pos)
  self.threads = {}
  self.message_callbacks = {}
  self.message_requests = {}
  self.client.close()
  require('dap.repl').set_session(nil)
end


function Session:request(command, arguments, callback)
  local payload = {
    seq = self.seq;
    type = 'request';
    command = command;
    arguments = arguments
  }
  log.debug('request', payload)
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
  log.debug('response', payload)
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
    supportsVariableType = true;
    locale = os.getenv('LANG') or 'en_US';
  }, function(err0, result)
    if err0 then
      print("Could not initialize debug adapter: " .. err0.message)
      return
    end
    local capabilities = self.capabilities or {}
    self.capabilities = vim.tbl_extend('force', capabilities, result or {})
    self:request(config.request, config, function(err)
      if err then
        print(string.format('Error on %s: %s', config.request, err.message))
        self:close()
        dap()._reset_session()
        return
      end
      require('dap.repl').set_session(self)
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


function Session:disconnect(opts)
  opts = vim.tbl_extend('force', {
    restart = false,
    terminateDebuggee = true;
  }, opts or {})
  self:request('disconnect', opts)
end


function Session:_frame_set(frame)
  if not frame then
    return
  end
  self.current_frame = frame
  jump_to_frame(self, frame, false)
  self:_request_scopes(frame)
end


function Session:_frame_delta(delta)
  if not self.stopped_thread_id then
    print('Cannot move frame if not stopped')
    return
  end
  local frames = self.threads[self.stopped_thread_id].frames
  assert(frames, 'Stopped thread must have frames')
  local current_frame_index = index_of(frames, function(i) return i.id == self.current_frame.id end)
  assert(current_frame_index, 'id of current frame must be present in frames')

  current_frame_index = current_frame_index + delta
  if current_frame_index < 1 then
    current_frame_index = #frames
  elseif current_frame_index > #frames then
    current_frame_index = 1
  end
  self:_frame_set(frames[current_frame_index])
end


function Session.event_exited()
end

function Session.event_module()
end

function Session.event_process()
end

function Session.event_thread()
end

function Session.event_continued()
end

function Session.event_breakpoint()
end

function Session:event_capabilities(body)
  local capabilities = self.capabilities or {}
  self.capabilities = vim.tbl_extend('force', capabilities, body.capabilities)
end

return Session
