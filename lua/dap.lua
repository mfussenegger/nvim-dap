dap = {} -- luacheck: ignore 111 - to support v:lua.dap... uses


local uv = vim.loop
local api = vim.api
local log = require('dap.log').create_logger('vim-dap.log')
local ui = require('dap.ui')
local repl = require('dap.repl')
local M = {}
local ns_breakpoints = 'dap_breakpoints'
local ns_pos = 'dap_pos'
local Session = {}
local session = nil
local bp_info = {}
local last_run = nil

M.repl = repl
M.custom_event_handlers = setmetatable({}, {
  __index = function(tbl, key)
    rawset(tbl, key, {})
    return rawget(tbl, key)
  end
})
M.custom_response_handlers = setmetatable({}, {
  __index = function(tbl, key)
    rawset(tbl, key, {})
    return rawget(tbl, key)
  end
})

local DAP_QUICKFIX_TITLE = "DAP Breakpoints"
local DAP_QUICKFIX_CONTEXT = DAP_QUICKFIX_TITLE

--- For extension of language specific debug adapters.
--
-- `adapters.<type>` where <type> is specified in a configuration.
--
-- For example:
--
-- require('dap').adapters.python = {
--    type = 'executable';
--    command = '/path/to/python';
--    args = {'-m', 'debugpy.adapter' };
-- }
--
M.adapters = {}


--- Configurations for languages
--
-- Example:
--
-- require('dap').configurations.python = {
--  {
--    type = 'python';
--    request = 'launch';
--    name = "Launch file";
--
--    -- ${file} and ${workspaceFolder} variables are supported
--    program = "${file}";
--
--    -- values other than type, request and name can be functions, they'll be evaluated when the configuration is used
--    pythonPath = function()
--      local cwd = vim.fn.getcwd()
--      if vim.fn.executable(cwd .. '/venv/bin/python') then
--        return cwd .. '/venv/bin/python'
--      elseif vim.fn.executable(cwd .. '/.venv/bin/python') then
--        return cwd .. '/.venv/bin/python'
--      else
--        return '/usr/bin/python'
--      end
--    end;
--  }
-- }
--
M.configurations = {}


vim.fn.sign_define('DapBreakpoint', {text='B', texthl='', linehl='', numhl=''})
vim.fn.sign_define('DapLogPoint', {text='L', texthl='', linehl='', numhl=''})
vim.fn.sign_define('DapStopped', {text='→', texthl='', linehl='debugPC', numhl=''})


local function expand_config_variables(option)
  if type(option) == 'function' then
    option = option()
  end
  if type(option) == "table" and vim.tbl_islist(option) then
    return vim.tbl_map(expand_config_variables, option)
  end
  if type(option) ~= "string" then
    return option
  end
  local variables = {
    file = vim.fn.expand("%");
    workspaceFolder = vim.fn.getcwd();
  }
  local ret = option
  for key, val in pairs(variables) do
    ret = ret:gsub('${' .. key .. '}', val)
  end
  return ret
end


local function index_of(items, predicate)
  for i, item in ipairs(items) do
    if predicate(item) then
      return i
    end
  end
end

local function non_empty_sequence(object)
  return object and #object > 0
end


local function run_adapter(adapter, configuration, opts)
  if adapter.type == 'executable' then
    M.launch(adapter, configuration, opts)
  elseif adapter.type == 'server' then
    M.attach(adapter.host, adapter.port, configuration, opts)
  else
    print(string.format('Invalid adapter type %s, expected `executable` or `server`', adapter.type))
  end
end


local function maybe_enrich_config_and_run(adapter, configuration, opts)
  assert(type(adapter) == 'table', 'adapter must be a table, not' .. vim.inspect(adapter))
  assert(
    adapter.type,
    'Adapter for ' .. configuration.type .. ' must have the `type` property set to `executable` or `server`'
  )
  if adapter.enrich_config then
    assert(
      type(adapter.enrich_config) == 'function',
      '`enrich_config` property of adapter must be a function: ' .. vim.inspect(adapter)
    )
    adapter.enrich_config(configuration, function(config)
      run_adapter(adapter, config, opts)
    end)
  else
    run_adapter(adapter, configuration, opts)
  end
end


local function select_config_and_run()
  local filetype = api.nvim_buf_get_option(0, 'filetype')
  local configurations = M.configurations[filetype] or {}
  local configuration = ui.pick_one(configurations, "Configuration: ", function(i) return i.name end)
  if not configuration then
    print('No configuration found for ' .. filetype)
    return
  end
  M.run(configuration)
end


function M.run(config, opts)
  opts = opts or {}
  last_run = {
    config = config,
    opts = opts,
  }
  if opts.before then
    config = opts.before(config)
  end
  local adapter = M.adapters[config.type]
  if type(adapter) == 'table' then
    config = vim.tbl_map(expand_config_variables, config)
    maybe_enrich_config_and_run(adapter, config, opts)
  elseif type(adapter) == 'function' then
    adapter(function(resolved_adapter)
      config = vim.tbl_map(expand_config_variables, config)
      maybe_enrich_config_and_run(resolved_adapter, config, opts)
    end)
  else
    print(string.format('Invalid adapter: %q', adapter))
  end
end


function M.run_last()
  if last_run then
    M.run(last_run.config, last_run.opts)
  else
    print('No configuration available to re-run')
  end
end


function Session:run_in_terminal(request)
  local body = request.arguments
  -- env option is ignored without https://github.com/neovim/neovim/pull/11839
  local opts = {
    clear_env = false;
    env = body.env;
  }
  local _ = log.debug() and log.debug('run_in_terminal', body.args, opts)
  local win = api.nvim_get_current_win()
  api.nvim_command('belowright new')
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


local function msg_with_content_length(msg)
  return table.concat {
    'Content-Length: ';
    tostring(#msg);
    '\r\n\r\n';
    msg
  }
end


-- Copied from neovim rpc.lua
local function parse_headers(header)
  if type(header) ~= 'string' then
    return nil
  end
  local headers = {}
  for line in vim.gsplit(header, '\r\n', true) do
    if line == '' then
      break
    end
    local key, value = line:match('^%s*(%S+)%s*:%s*(.+)%s*$')
    if key then
      key = key:lower():gsub('%-', '_')
      headers[key] = value
    else
      error(string.format("Invalid header line %q", line))
    end
  end
  headers.content_length = tonumber(headers.content_length)
    or error(string.format("Content-Length not found in headers. %q", header))
  return headers
end


-- Mostly copied from neovim rpc.lua
local header_start_pattern = ("content"):gsub("%w", function(c) return "["..c..c:upper().."]" end)
local function parse_chunk_loop()
  local buffer = ''
  while true do
    local start, finish = buffer:find('\r\n\r\n', 1, true)
    if start then
      local buffer_start = buffer:find(header_start_pattern)
      local headers = parse_headers(buffer:sub(buffer_start, start - 1))
      buffer = buffer:sub(finish + 1)
      local content_length = headers.content_length
      while #buffer < content_length do
        buffer = buffer .. (coroutine.yield()
          or error("Expected more data for the body. The server may have died."))
      end
      local body = buffer:sub(1, content_length)
      buffer = buffer:sub(content_length + 1)
      buffer = buffer .. (coroutine.yield(headers, body)
        or error("Expected more data for the body. The server may have died."))
    else
      buffer = buffer .. (coroutine.yield()
        or error("Expected more data for the header. The server may have died."))
    end
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
      self:set_exception_breakpoints('default', nil, on_done)
    else
      on_done()
    end
  end)
end


local function jump_to_frame(frame, preserve_focus_hint)
  if not frame.source then
    return
  end
  if not frame.source.path then
    print('Source path not available, cannot jump to frame')
    return
  end
  local scheme = frame.source.path:match('^([a-z]+)://.*')
  local bufnr
  if scheme then
    bufnr = vim.uri_to_bufnr(frame.source.path)
  else
    bufnr = vim.uri_to_bufnr(vim.uri_from_fname(frame.source.path))
  end
  vim.fn.sign_unplace(ns_pos)
  if preserve_focus_hint or frame.line < 0 then
    return
  end
  vim.fn.bufload(bufnr)
  local ok, failure = pcall(vim.fn.sign_place, 0, ns_pos, 'DapStopped', bufnr, { lnum = frame.line; priority = 12 })
  if not ok then
    print(failure)
  end
  -- vscode-go sends columns with 0
  -- That would cause a "Column value outside range" error calling nvim_win_set_cursor
  -- nvim-dap says "columnsStartAt1 = true" on initialize :/
  if frame.column == 0 then
    frame.column = 1
  end
  for _, win in pairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(win) == bufnr then
      api.nvim_win_set_cursor(win, { frame.line, frame.column - 1 })
      api.nvim_command('normal zv')
      return
    end
  end
  -- Buffer isn't active in any window; use the first window that is not special
  -- (Don't want to move to code in the REPL...)
  for _, win in pairs(api.nvim_list_wins()) do
    local winbuf = api.nvim_win_get_buf(win)
    if api.nvim_buf_get_option(winbuf, 'buftype') == '' then
      local bufchanged, _ = pcall(api.nvim_win_set_buf, win, bufnr)
      if bufchanged then
        api.nvim_win_set_cursor(win, { frame.line, frame.column - 1 })
        api.nvim_command('normal zv')
        return
      end
    end
  end
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

function Session:event_stopped(stopped)
  if self.stopped_thread_id then
    log.debug('Thread stopped, but another thread is already stopped, telling thread to continue')
    session:request('continue', { threadId = stopped.threadId })
    return
  end
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
        if not current_frame then
          current_frame = frame
          self.current_frame = frame
        end
        table.insert(frames, frame)
      end
      if not current_frame then
        return
      end
      jump_to_frame(current_frame, stopped.preserveFocusHint)

      self:_request_scopes(current_frame)
    end)
  end)
end

function Session:event_terminated()
  self:close()
  if self.handlers.after then
    self.handlers.after()
  end
  session = nil
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

function Session.event_output(_, body)
  repl.append(body.output, '$')
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

          scope.variables = variables_resp.variables
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
    local params = {threadId = session.stopped_thread_id, targetId = response.targets[1].id }
    self:request('goto', params, function(err1, _)
      if err1 then
        print('Error executing goto: ' .. err1.message)
      end
    end)
  end)

end


function Session:_frame_set(frame)
  if not frame then
    return
  end
  self.current_frame = frame
  jump_to_frame(self.current_frame, false)
  self:_request_scopes(self.current_frame)
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

local function remove_breakpoint_signs(bufnr, lnum)
  local signs = vim.fn.sign_getplaced(bufnr, { group = ns_breakpoints; lnum = lnum; })[1].signs
  if signs and #signs > 0 then
    for _, sign in pairs(signs) do
      vim.fn.sign_unplace(ns_breakpoints, { buffer = bufnr; id = sign.id; })
      bp_info[sign.id] = nil
    end
    return true
  else
    return false
  end
end


local function get_breakpoint_signs(bufexpr)
  if bufexpr then
    return vim.fn.sign_getplaced(bufexpr, {group = ns_breakpoints})
  end
  local bufs_with_signs = vim.fn.sign_getplaced()
  local result = {}
  for _, buf_signs in ipairs(bufs_with_signs) do
    buf_signs = vim.fn.sign_getplaced(buf_signs.bufnr, {group = ns_breakpoints})[1]
    if #buf_signs.signs > 0 then
      table.insert(result, buf_signs)
    end
  end
  return result
end


function Session:set_breakpoints(bufexpr, on_done)
  local bp_signs = get_breakpoint_signs(bufexpr)
  local num_bufs = #bp_signs
  if num_bufs == 0 then
    on_done()
    return
  end
  for _, buf_bp_signs in pairs(bp_signs) do
    local breakpoints = {}
    local bufnr = buf_bp_signs.bufnr
    for _, bp in pairs(buf_bp_signs.signs) do
      local bp_entry = bp_info[bp.id] or {}
      table.insert(breakpoints, {
        line = bp.lnum;
        condition = bp_entry.condition;
        hitCondition = bp_entry.hitCondition;
        logMessage = bp_entry.logMessage;
      })
    end
    if non_empty_sequence(bp_info.condition) and not self.capabilities.supportsConditionalBreakpoints then
      print("Debug adapter doesn't support breakpoints with conditions")
    end
    if non_empty_sequence(bp_info.hitCondition) and not self.capabilities.supportsHitConditionalBreakpoints then
      print("Debug adapter doesn't support breakpoints with hit conditions")
    end
    if non_empty_sequence(bp_info.logMessage) and not self.capabilities.supportsLogPoints then
      print("Debug adapter doesn't support log points")
    end
    local path = api.nvim_buf_get_name(bufnr)
    local payload = {
      source = {
        path = path;
        name = vim.fn.fnamemodify(path, ':t')
      };
      breakpoints = breakpoints;
      lines = vim.tbl_map(function(x) return x.line end, breakpoints);
    }
    self:request('setBreakpoints', payload, function(err1, resp)
        if err1 then
          print("Error setting breakpoints: " .. err1.message)
        else
          for _, bp in pairs(resp.breakpoints) do
            if not bp.verified then
              log.info('Server rejected breakpoint', bp)
              remove_breakpoint_signs(bufnr, bp.line)
            end
          end
        end
        num_bufs = num_bufs - 1
        if num_bufs == 0 and on_done then
          on_done()
        end
      end
    )
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

function Session:handle_body(body)
  local decoded = vim.fn.json_decode(body)
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
        for _, c in pairs(M.custom_response_handlers[decoded.command]) do
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
        for _, c in pairs(M.custom_event_handlers['event_' .. decoded.event]) do
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


local function create_read_loop(handle_body)
  local parse_chunk = coroutine.wrap(parse_chunk_loop)
  parse_chunk()
  return function (err, chunk)
    if err then
      print(err)
      return
    end
    if not chunk then
      return
    end
    while true do
      local headers, body = parse_chunk(chunk)
      if headers then
        vim.schedule(function()
          handle_body(body)
        end)
        chunk = ''
      else
        break
      end
    end
  end
end


function Session:connect(host, port, opts)
  local o = session_defaults(opts or {})
  setmetatable(o, self)
  self.__index = self

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
  client:read_start(create_read_loop(function(body) session:handle_body(body) end))
  return o
end


function Session:spawn(adapter, opts)
  local o = session_defaults(opts or {})
  setmetatable(o, self)
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
  stdout:read_start(create_read_loop(function(body)
    if session then
      session:handle_body(body)
    end
  end))
  stderr:read_start(function(err, chunk)
    assert(not err, err)
    if chunk then
      local _ = log.error() and log.error("stderr", adapter, chunk)
    end
  end)
  return o
end


function Session:close()
  vim.fn.sign_unplace(ns_pos)
  self.threads = {}
  self.message_callbacks = {}
  self.message_requests = {}
  self.client.close()
  repl.set_session(nil)
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
    local msg = msg_with_content_length(vim.fn.json_encode(payload))
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
    local msg = msg_with_content_length(vim.fn.json_encode(payload))
    self.client.write(msg)
  end)
end


function Session:initialize(config)
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
    session.capabilities = result
    session:request(config.request, config, function(err)
      if err then
        print(string.format('Error on %s: %s', config.request, err.message))
        session:close()
        session = nil
        return
      end
      repl.set_session(session)
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


function Session:_step(step)
  if vim.tbl_contains({"stepBack", "reverseContinue"}, step) and not session.capabilities.supportsStepBack then
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
  session:request(step, { threadId = thread_id; }, function(err0, _)
    if err0 then
      print('Error on '.. step .. ': ' .. err0.message)
    end
  end)
end


function M.step_over()
  if not session then return end
  session:_step('next')
end

function M.step_into()
  if not session then return end
  session:_step('stepIn')
end

function M.step_out()
  if not session then return end
  session:_step('stepOut')
end

function M.reverse_continue()
  if not session then return end
  session:_step('reverseContinue')
end

function M.step_back()
  if not session then return end
  session:_step('stepBack')
end

function M.stop()
  if session then
    session:close()
    session = nil
  end
end

function M.up()
  if session then
    session:_frame_delta(1)
  end
end

function M.down()
  if session then
    session:_frame_delta(-1)
  end
end

function M.goto_(line)
  if session then
    local source, col
    if not line then
      line, col = unpack(api.nvim_win_get_cursor(0))
      col = col + 1
      source = { path = vim.uri_from_bufnr(0) }
    end
    session:_goto(line, source, col)
  end
end

function M.restart()
  if not session then return end
  if session.capabilities.supportsRestartRequest then
    session:request('restart', nil, function(err0, _)
      if err0 then
        print('Error restarting debug adapter: ' .. err0.message)
      else
        print('Restarted debug adapter')
      end
    end)
  else
    print('Restart not supported')
  end
end

function M.list_breakpoints(open_quickfix)
  local bp_signs = get_breakpoint_signs()
  local num_bufs = #bp_signs
  local qf_list = {}
  for _, buf_bp_signs in pairs(bp_signs) do
    local bufnr = buf_bp_signs.bufnr
    for _, bp in pairs(buf_bp_signs.signs) do
      local bp_entry = bp_info[bp.id] or {}
      local condition = bp_entry.condition;
      local hitCondition = bp_entry.hitCondition;
      local logMessage = bp_entry.logMessage;
      local text = table.concat(
        vim.tbl_filter(
          function(v) return v end,
          {
            unpack(api.nvim_buf_get_lines(bufnr, bp.lnum - 1, bp.lnum, false), 1),
            non_empty_sequence(logMessage) and "Log message: "..logMessage,
            non_empty_sequence(condition) and "Condition: "..condition,
            non_empty_sequence(hitCondition) and "Hit condition: "..hitCondition,
          }
        ),
        ', '
      )
      table.insert(qf_list, {
        bufnr = bufnr,
        lnum = bp.lnum,
        col = 0,
        text = text,
      })
    end
  end

  vim.fn.setqflist({}, 'r', {items = qf_list, context = DAP_QUICKFIX_CONTEXT, title = DAP_QUICKFIX_TITLE })
  if open_quickfix ~= false then
    if num_bufs == 0 then
      print('No breakpoints set!')
    else
      api.nvim_command('copen')
    end
  end
end

function M.set_breakpoint(condition, hit_condition, log_message)
  M.toggle_breakpoint(condition, hit_condition, log_message, true)
end

function M.toggle_breakpoint(condition, hit_condition, log_message, replace_old)
  local bufnr = api.nvim_get_current_buf()
  local lnum, _ = unpack(api.nvim_win_get_cursor(0))
  if not remove_breakpoint_signs(bufnr, lnum) or replace_old then
    local sign_id = vim.fn.sign_place(
      0,
      ns_breakpoints,
      non_empty_sequence(log_message) and 'DapLogPoint' or 'DapBreakpoint',
      bufnr,
      { lnum = lnum; priority = 11; }
    )
    if sign_id ~= -1 then
      bp_info[sign_id] = {
        condition = condition,
        logMessage = log_message,
        hitCondition = hit_condition
      }
    end
  end
  if session and session.initialized then
    session:set_breakpoints(bufnr)
  end
  if vim.fn.getqflist({context = DAP_QUICKFIX_CONTEXT}).context == DAP_QUICKFIX_CONTEXT then
    M.list_breakpoints(false)
  end
end


-- setExceptionBreakpoints (https://microsoft.github.io/debug-adapter-protocol/specification#Requests_SetExceptionBreakpoints)
--- filters: string[]
--- exceptionOptions: exceptionOptions?: ExceptionOptions[] (https://microsoft.github.io/debug-adapter-protocol/specification#Types_ExceptionOptions)
function M.set_exception_breakpoints(filters, exceptionOptions)
  if session then
    session:set_exception_breakpoints(filters, exceptionOptions)
  else
    print('Cannot set exception breakpoints: No active session!')
  end
end


function M.continue()
  if not session then
    select_config_and_run()
  else
    session:_step('continue')
  end
end


--- Disconnects an active session
function M.disconnect()
  if session then
    -- Should result in a `terminated` event which closes the session and sets it to nil
    session:disconnect()
  else
    print('No active session. Doing nothing.')
  end
end


local function completions_to_items(completions, prefix)
  local candidates = vim.tbl_filter(
    function(item) return vim.startswith(item.text or item.label, prefix) end,
    completions
  )
  if #candidates == 0 then
    return {}
  end

  if candidates[1].sortText then
    table.sort(candidates, function(a, b) return (a.sortText or 0) < (b.sortText or 0) end)
  end

  local items = {}
  for _, candidate in pairs(candidates) do
    table.insert(items, {
      word = candidate.text or candidate.label;
      abbr = candidate.label;
      dup = 0;
      icase = 1;
    })
  end
  return items
end


function dap.omnifunc(findstart, base) -- luacheck: ignore 112
  local supportsCompletionsRequest = ((session or {}).capabilities or {}).supportsCompletionsRequest;
  local _ = log.debug() and log.debug('omnifunc.findstart', {
    findstart = findstart;
    base = base;
    supportsCompletionsRequest = supportsCompletionsRequest;
  })
  if not supportsCompletionsRequest then
    if findstart == 1 then
      return -1
    else
      return {}
    end
  end
  local col = api.nvim_win_get_cursor(0)[2]
  local line = api.nvim_get_current_line()
  local offset = vim.startswith(line, 'dap> ') and 5 or 0
  local line_to_cursor = line:sub(offset + 1, col)
  local text_match = vim.fn.match(line_to_cursor, '\\k*$')
  local prefix = line_to_cursor:sub(text_match + 1)

  local _ = log.debug() and log.debug('omnifunc.line', {
    line = line;
    col = col - offset;
    line_to_cursor = line_to_cursor;
    text_match = text_match + offset;
    prefix = prefix;
  })

  session:request('completions', {
    frameId = (session.current_frame or {}).id;
    text = line_to_cursor;
    column = col - offset;
  }, function(err, response)
    if err then
      local _ = log.error() and log.error('completions.callback', err.message)
      return
    end

    local items = completions_to_items(response.targets, prefix)
    vim.fn.complete(offset + text_match + 1, items)
  end)

  -- cancel but stay in completion mode for completion via `completions` callback
  return -2
end


--- Attach to an existing debug-adapter running on host, port
--  and then initialize it with config
--
-- Configuration:         -- Specifies how the debug adapter should conenct/launch the debugee
--    request: string     -- attach or launch
--    ...                 -- debug adapter specific options
--
function M.attach(host, port, config, opts)
  if session then
    session:close()
  end
  if not config.request then
    print('config needs the `request` property which must be one of `attach` or `launch`')
    return
  end
  session = Session:connect(host, port, opts)
  session:initialize(config)
  return session
end


--- Launch a new debug adapter and then initialize it with config
--
-- Adapter:
--    command: string     -- command to invoke
--    args:    string[]   -- arguments for the command
--    options?: {
--      env?: {}          -- Set the environment variables for the command
--      cwd?: string      -- Set the working directory for the command
--    }
--
--
-- Configuration:         -- Specifies how the debug adapter should conenct/launch the debugee
--    request: string     -- attach or launch
--    ...                 -- debug adapter specific options
--
function M.launch(adapter, config, opts)
  if session then
    session:close()
  end
  session = Session:spawn(adapter, opts)
  session:initialize(config)
  return session
end


function M.set_log_level(level)
  log.set_level(level)
end


return M
