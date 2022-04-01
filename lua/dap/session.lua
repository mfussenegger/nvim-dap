local uv = vim.loop
local api = vim.api
local rpc = require('dap.rpc')

local utils = require('dap.utils')
local breakpoints = require('dap.breakpoints')
local progress = require('dap.progress')
local log = require('dap.log').create_logger('dap.log')
local repl = require('dap.repl')
local sec_to_ms = 1000
local non_empty = utils.non_empty
local index_of = utils.index_of
local mime_to_filetype = {
  ['text/javascript'] = 'javascript'
}

local Session = {}
local ns_pos = 'dap_pos'
local terminal_buf

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
local json_decode
local json_encode = vim.fn.json_encode
local send_payload
if vim.json then
  json_decode = function(payload)
    return vim.json.decode(payload, { luanil = { object = true }})
  end
  json_encode = vim.json.encode
  send_payload = function(client, payload)
    local msg = rpc.msg_with_content_length(json_encode(payload))
    client.write(msg)
  end
else
  json_decode = function(payload)
    return convert_nil(vim.fn.json_decode(payload))
  end
  send_payload = function(client, payload)
    vim.schedule(function()
      local msg = rpc.msg_with_content_length(json_encode(payload))
      client.write(msg)
    end)
  end
end


local function dap()
  return require('dap')
end

local function ui()
  return require('dap.ui')
end

local function defaults(session)
  return dap().defaults[session.config.type]
end

local function signal_err(err, cb)
  if err then
    if cb then
      cb(err)
    else
      error(vim.inspect(err))
    end
    return true
  end
  return false
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
      utils.notify(string.format('Terminal exited %d running %s %s', code, terminal.command, table.concat(full_args, ' ')), vim.log.levels.ERROR)
    end
  end)
  return handle, pid_or_err
end


local function run_in_terminal(self, request)
  local body = request.arguments
  log.debug('run_in_terminal', body)
  local settings = dap().defaults[self.config.type]
  if body.kind == 'external' or (settings.force_external_terminal and settings.external_terminal) then
    local terminal = settings.external_terminal
    if not terminal then
      utils.notify('Requested external terminal, but none configured. Fallback to integratedTerminal', vim.log.levels.WARN)
    else
      local handle, pid = launch_external_terminal(terminal, body.args)
      if not handle then
        utils.notify('Could not launch terminal ' .. terminal.command, vim.log.levels.ERROR)
      end
      self:response(request, {
        success = handle ~= nil;
        body = { processId = pid; };
      })
      return
    end
  end
  local cur_win = api.nvim_get_current_win()
  local cur_buf = api.nvim_get_current_buf()
  if terminal_buf and api.nvim_buf_is_valid(terminal_buf) then
    local terminal_buf_win = false
    api.nvim_buf_set_option(terminal_buf, 'modified', false)
    for _, win in pairs(api.nvim_tabpage_list_wins(0)) do
      if api.nvim_win_get_buf(win) == terminal_buf then
        terminal_buf_win = true
        api.nvim_set_current_win(win)
      end
    end
    if not terminal_buf_win then
      api.nvim_buf_delete(terminal_buf, {force=true})
      api.nvim_command(dap().defaults[self.config.type].terminal_win_cmd)
      terminal_buf = api.nvim_get_current_buf()
    end
  else
    api.nvim_command(dap().defaults[self.config.type].terminal_win_cmd)
    terminal_buf = api.nvim_get_current_buf()
  end
  local ok, path = pcall(api.nvim_buf_get_option, cur_buf, 'path')
  if ok then
    api.nvim_buf_set_option(terminal_buf, 'path', path)
  end
  local opts = {
    clear_env = false;
    env = next(body.env or {}) and body.env or vim.empty_dict(),
    cwd = (body.cwd and body.cwd ~= '') and body.cwd or nil
  }
  local jobid = vim.fn.termopen(body.args, opts)
  if not dap().defaults[self.config.type].focus_terminal then
      api.nvim_set_current_win(cur_win)
  end
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
          utils.notify(err1.message, vim.log.levels.ERROR)
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


function Session:_show_exception_info(thread_id)
  if not self.capabilities.supportsExceptionInfoRequest then return end

  self:request('exceptionInfo', {threadId = thread_id}, function(err, response)
    if err then
      utils.notify('Error getting exception info: ' .. err.message, vim.log.levels.ERROR)
    end
    if not response then return end

    local exception_type = response.details and response.details.typeName
    local of_type = exception_type and ' of type '..exception_type or ''
    repl.append('Thread stopped due to exception'..of_type..' ('..response.breakMode..')')
    if response.description then
      repl.append('Description: '..response.description)
    end
    local details = response.details or {}
    if details.stackTrace then
      repl.append("Stack trace:")
      repl.append(details.stackTrace)
    end
    if details.innerException then
      repl.append("Inner Exceptions:")
      for _, e in pairs(details.innerException) do
        repl.append(vim.inspect(e))
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
    utils.notify(failure, vim.log.levels.ERROR)
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
    local buftype = api.nvim_buf_get_option(winbuf, 'buftype')
    if buftype == '' or vim.b[winbuf].dap_source_buf == true then
      local bufchanged, _ = pcall(api.nvim_win_set_buf, win, bufnr)
      if bufchanged then
        api.nvim_win_set_cursor(win, { line, column - 1 })
        with_win(win, api.nvim_command, 'normal zv')
        return
      end
    end
  end
  utils.notify('Stopped at line ' .. line .. ' but could not jump to location', vim.log.levels.WARN)
end


local function jump_to_frame(cur_session, frame, preserve_focus_hint)
  local source = frame.source
  if not source then
    utils.notify('Source not available, cannot jump to frame', vim.log.levels.INFO)
    return
  end
  vim.fn.sign_unplace(ns_pos)
  if preserve_focus_hint or frame.line < 0 then
    return
  end
  if not source.sourceReference or source.sourceReference == 0 then
    if not source.path then
      utils.notify('Source path not available, cannot jump to frame', vim.log.levels.INFO)
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
    cur_session:source(source, function(err, buf)
      assert(not err, vim.inspect(err))
      jump_to_location(buf, frame.line, frame.column)
    end)
  end
end


--- Request a source
-- @param source Source (https://microsoft.github.io/debug-adapter-protocol/specification#Types_Source)
-- @param cb (function(err, buf)) - the buffer will have the contents of the source
function Session:source(source, cb)
  assert(source, 'source is required')
  assert(source.sourceReference, 'sourceReference is required')
  assert(source.sourceReference ~= 0, 'sourceReference must not be 0')
  local params = {
    source = source,
    sourceReference = source.sourceReference
  }
  self:request('source', params, function(err, response)
    if signal_err(err, cb) then return end

    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_var(buf, 'dap_source_buf', true)
    local adapter_options = self.adapter.options or {}
    local ft = mime_to_filetype[response.mimeType] or adapter_options.source_filetype
    if ft then
      api.nvim_buf_set_option(buf, 'filetype', ft)
    end
    api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(response.content, '\n'))
    if not ft and source.path and vim.filetype then
      pcall(api.nvim_buf_set_name, buf, source.path)
      pcall(vim.filetype.match, source.path, buf)
    end
    if cb then
      cb(nil, buf)
    end
  end)
end


function Session:update_threads(cb)
  self:request('threads', nil, function(err, response)
    if signal_err(err, cb) then return end
    local threads = {}
    for _, thread in pairs(response.threads) do
      threads[thread.id] = thread
    end
    self.threads = threads
    self.dirty.threads = false
    if cb then
      cb(nil, threads)
    end
  end)
end


local function get_top_frame(frames)
  for _, frame in pairs(frames) do
    if frame.source and frame.source.path then
      return frame
    end
  end
  return next(frames)
end


function Session:event_stopped(stopped)
  if self.dirty.threads or (stopped.threadId and self.threads[stopped.threadId] == nil) then
    self:update_threads(function(err)
      if err then
        utils.notify('Error retrieving threads: ' .. err.message, vim.log.levels.ERROR)
        return
      end
      self:event_stopped(stopped)
    end)
    return
  end

  local should_jump = stopped.reason ~= 'pause'
  if self.stopped_thread_id and should_jump then
    local thread = self.threads[self.stopped_thread_id]
    if defaults(self).auto_continue_if_many_stopped then
      log.debug(
        'Received stopped event, but ' .. thread.name .. ' is already stopped. ' ..
        'Resuming newly stopped thread. ' ..
        'To disable this set the `auto_continue_if_many_stopped` option to false.')
      self:request('continue', { threadId = stopped.threadId })
    else
      -- Allow thread to stop, but don't jump to it because stepping
      -- interleaved between threads is confusing
      should_jump = false
    end
  end
  if should_jump then
    self.stopped_thread_id = stopped.threadId
  end

  if stopped.threadId then
    progress.report('Thread stopped: ' .. stopped.threadId)
    self.threads[stopped.threadId].stopped = true
  elseif stopped.allThreadsStopped then
    progress.report('All threads stopped')
    utils.notify(
      'All threads stopped. ' .. stopped.reason and 'Reason: ' .. stopped.reason or '',
      vim.log.levels.INFO
    )
    for _, thread in pairs(self.threads) do
      thread.stopped = true
    end
  else
    utils.notify('Stopped event received, but no threadId or allThreadsStopped', vim.log.levels.WARN)
  end

  if stopped.reason == 'exception' then
    self:_show_exception_info(stopped.threadId)
  end
  if not stopped.threadId then
    return
  end

  local thread = self.threads[stopped.threadId]
  assert(thread, 'Thread not found: ' .. stopped.threadId)
  self:request('stackTrace', { threadId = stopped.threadId; }, function(err, response)
    if err then
      utils.notify('Error retrieving stack traces: ' .. err.message, vim.log.levels.ERROR)
      return
    end
    local frames = response.stackFrames
    thread.frames = frames
    local current_frame = get_top_frame(frames)
    if not current_frame then
      utils.notify('Debug adapter stopped at unavailable location', vim.log.levels.WARN)
      return
    end
    if should_jump then
      self.current_frame = current_frame
      jump_to_frame(self, current_frame, stopped.preserveFocusHint)
      self:_request_scopes(current_frame)
    end
  end)
end


function Session:event_terminated()
  self:close()
  dap().set_session(nil)
end


function Session.event_output(_, body)
  if body.category == 'telemetry' then
    log.info('Telemetry', body.output)
  else
    repl.append(body.output, '$')
  end
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
    utils.notify("Debug Adapter doesn't support GotoTargetRequest", vim.log.levels.INFO)
    return
  end
  self:request('gotoTargets',  {source = source or frame.source, line = line, col = col}, function(err, response)
    if err then
      utils.notify('Error getting gotoTargets: ' .. err.message, vim.log.levels.ERROR)
      return
    end
    if not response or not response.targets then
      utils.notify("No goto targets available. Can't execute goto", vim.log.levels.INFO)
      return
    end
    local params = {threadId = self.stopped_thread_id, targetId = response.targets[1].id }
    self:request('goto', params, function(err1, _)
      if err1 then
        utils.notify('Error executing goto: ' .. err1.message, vim.log.levels.ERROR)
      end
    end)
  end)
end


do
  local function notify_if_missing_capability(bps, capabilities)
    for _, bp in pairs(bps) do
      if non_empty(bp.condition) and not capabilities.supportsConditionalBreakpoints then
        utils.notify("Debug adapter doesn't support breakpoints with conditions", vim.log.levels.WARN)
      end
      if non_empty(bp.hitCondition) and not capabilities.supportsHitConditionalBreakpoints then
        utils.notify("Debug adapter doesn't support breakpoints with hit conditions", vim.log.levels.WARN)
      end
      if non_empty(bp.logMessage) and not capabilities.supportsLogPoints then
        utils.notify("Debug adapter doesn't support log points", vim.log.levels.WARN)
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
      notify_if_missing_capability(buf_bps, self.capabilities)
      local path = api.nvim_buf_get_name(bufnr)
      local payload = {
        source = {
          path = path;
          name = vim.fn.fnamemodify(path, ':t')
        };
        sourceModified = false;
        breakpoints = buf_bps;
        lines = vim.tbl_map(function(x) return x.line end, buf_bps);
      }
      self:request('setBreakpoints', payload, function(err1, resp)
        if err1 then
          utils.notify('Error setting breakpoints: ' .. err1.message, vim.log.levels.ERROR)
        else
          for _, bp in pairs(resp.breakpoints) do
            breakpoints.set_state(bufnr, bp.line, bp)
            if not bp.verified then
              log.info('Server rejected breakpoint', bp)
              if bp.message then
                utils.notify(bp.message, vim.log.levels.ERROR)
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
    utils.notify("Debug adapter doesn't support exception breakpoints", vim.log.levels.INFO)
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
    utils.notify('Debug adapter does not support ExceptionOptions', vim.log.levels.INFO)
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
        utils.notify('Error setting exception breakpoints: ' .. err.message, vim.log.levels.ERROR)
      end
      if on_done then
        on_done()
      end
  end)
end


function Session:handle_body(body)
  local decoded = json_decode(body)
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
  elseif decoded.type == 'request' then
    local handler = self.handlers.reverse_requests[decoded.command]
    if handler then
      handler(self, decoded)
    else
      log.warn('No handler for reverse request', decoded)
    end
  else
    log.warn('Received unexpected message', decoded)
  end
end


local default_reverse_request_handlers = {
  runInTerminal = run_in_terminal
}


local function session_defaults(adapter, opts)
  local handlers = {}
  handlers.after = opts.after
  handlers.reverse_requests = vim.tbl_extend(
    'error',
    default_reverse_request_handlers,
    adapter.reverse_request_handlers or {}
  )
  return {
    handlers = handlers;
    message_callbacks = {};
    message_requests = {};
    initialized = false;
    seq = 0;
    stopped_thread_id = nil;
    current_frame = nil;
    threads = {};
    adapter = adapter;
    dirty = {};
  }
end


function Session:connect(adapter, opts, on_connect)
  log.debug('Connecting to debug adapter', adapter)
  local session = session_defaults(adapter, opts or {})
  setmetatable(session, self)
  self.__index = self

  local closed = false
  local client = uv.new_tcp()
  session.client = {
    write = function(line)
      client:write(line)
    end;
    close = function()
      if closed then
        return
      end
      closed = true
      client:shutdown()
      client:close()
    end;
  }
  local host = adapter.host or '127.0.0.1'
  local on_addresses = function(err, addresses)
    if err or #addresses == 0 then
      err = err or ('Could not resolve ' .. host)
      on_connect(err)
      return
    end
    local address = addresses[1]
    client:connect(address.addr, tonumber(adapter.port), function(conn_err)
      if not conn_err then
        local handle_body = vim.schedule_wrap(function(body)
          session:handle_body(body)
        end)
        client:read_start(rpc.create_read_loop(handle_body, function()
          if not closed then
            closed = true
            client:shutdown()
            client:close()
          end
          local s = dap().session()
          if s == session then
            vim.schedule(function()
              utils.notify('Debug adapter disconnected', vim.log.levels.INFO)
            end)
            dap().set_session(nil)
          end
        end))
      end
      on_connect(conn_err)
    end)
  end
  -- getaddrinfo fails for some users with `bad argument #3 to 'getaddrinfo' (Invalid protocol hint)`
  -- It should generally work with luv 1.42.0 but some still get errors
  if vim.loop.version() >= 76288 then
    local ok, err = pcall(uv.getaddrinfo, host, nil, { protocol = 'tcp' }, on_addresses)
    if not ok then
      log.warn(err)
      on_addresses(nil, { { addr = host }, })
    end
  else
    on_addresses(nil, { { addr = host }, })
  end
  return session
end


function Session:spawn(adapter, opts)
  log.debug('Spawning debug adapter', adapter)
  local session = session_defaults(adapter, opts or {})
  setmetatable(session, self)
  self.__index = self

  local stdin = uv.new_pipe(false)
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)
  local handle
  local pid_or_err
  local closed = false
  local function onexit()
    if closed then
      return
    end
    closed = true
    stdin:shutdown(function()
      stdout:close()
      stderr:close()
      log.info('Closed all handles')
      if handle and not handle:is_closing() then
        handle:close(function()
          log.info('Process closed', pid_or_err, handle:is_active())
          handle = nil
        end)
      end
    end)
  end
  local options = adapter.options or {}
  local spawn_opts = {
    args = adapter.args;
    stdio = {stdin, stdout, stderr};
    cwd = options.cwd;
    env = options.env;
    detached = true;
  }
  handle, pid_or_err = uv.spawn(adapter.command, spawn_opts, onexit)
  if not handle then
    onexit()
    error('Error running ' .. adapter.command .. ': ' .. pid_or_err)
  end
  session.client = {
    write = function(line) stdin:write(line) end;
    close = onexit,
  }
  stdout:read_start(rpc.create_read_loop(vim.schedule_wrap(function(body)
    session:handle_body(body)
  end)))
  stderr:read_start(function(err, chunk)
    assert(not err, err)
    if chunk then
      log.error("stderr", adapter, chunk)
    end
  end)
  return session
end


local function pause_thread(session, thread_id, cb)
  assert(session, 'Cannot pause thread without active session')
  assert(thread_id, 'thread_id is required to pause thread')

  session:request('pause', { threadId = thread_id; }, function(err)
    if err then
      utils.notify('Error pausing: ' .. err.message, vim.log.levels.ERROR)
    else
      utils.notify('Thread paused ' .. thread_id, vim.log.levels.INFO)
      local thread = session.threads[thread_id]
      if thread then
        thread.stopped = true
      end
    end
    if cb then
      cb(err)
    end
  end)
end


function Session:_pause(thread_id, cb)
  if thread_id then
    pause_thread(self, thread_id, cb)
    return
  end
  if self.dirty.threads then
    self:update_threads(function(err)
      if err then
        utils.notify('Error requesting threads: ' .. err.message, vim.log.levels.ERROR)
        return
      end
      self:_pause(nil, cb)
    end)
    return
  end
  ui().pick_if_many(
    vim.tbl_values(self.threads),
    "Which thread?: ",
    function(t) return t.name end,
    function(thread)
      if not thread or not thread.id then
        utils.notify('No thread to stop. Not pausing...', vim.log.levels.INFO)
      else
        pause_thread(self, thread.id, cb)
      end
    end
  )
end


function Session:_step(step, params)
  if not self.stopped_thread_id then
    utils.notify('No stopped thread. Cannot move', vim.log.levels.ERROR)
    return
  end
  vim.fn.sign_unplace(ns_pos)
  params = params or {}
  params.threadId = self.stopped_thread_id
  if not params.granularity then
    params.granularity = dap().defaults[self.config.type].stepping_granularity
  end
  local thread = self.threads[self.stopped_thread_id]
  if thread then
    thread.stopped = false
  end
  self.stopped_thread_id = nil
  self:request(step, params, function(err)
    if err then
      utils.notify('Error on '.. step .. ': ' .. err.message, vim.log.levels.ERROR)
    end
    progress.report('Running')
  end)
end



function Session:close()
  vim.fn.sign_unplace(ns_pos)
  self.threads = {}
  self.message_callbacks = {}
  self.message_requests = {}
  if self.handlers.after then
    self.handlers.after()
    self.handlers.after = nil
  end
  self.client.close()
end


function Session:request_with_timeout(command, arguments, timeout_ms, callback)
  local cb_triggered = false
  local timed_out = false
  local function cb(err, response)
    if timed_out then
      return
    end
    cb_triggered = true
    if callback then
      callback(err, response)
    end
  end
  self:request(command, arguments, cb)
  local timer = uv.new_timer()
  timer:start(timeout_ms, 0, function()
    timer:stop()
    timer:close()
    timed_out = true
    if not cb_triggered then
      local err = { message = 'Request `' .. command .. '` timed out after ' .. timeout_ms .. 'ms' }
      if callback then
        vim.schedule(function()
          callback(err, nil)
        end)
      else
        vim.schedule(function()
          utils.notify(err.message, vim.log.levels.INFO)
        end)
      end
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
  log.debug('request', payload)
  local current_seq = self.seq
  self.seq = self.seq + 1
  if callback then
    self.message_callbacks[current_seq] = callback
    self.message_requests[current_seq] = arguments
  end
  send_payload(self.client, payload)
end


function Session:response(request, payload)
  payload.seq = self.seq
  self.seq = self.seq + 1
  payload.type = 'response'
  payload.request_seq = request.seq;
  payload.command = request.command;
  log.debug('response', payload)
  send_payload(self.client, payload)
end


function Session:initialize(config)
  vim.schedule(repl.clear)
  local adapter_responded = false
  self.config = config
  self:request('initialize', {
    clientId = 'neovim';
    clientname = 'neovim';
    adapterID = self.adapter.id or 'nvim-dap';
    pathFormat = 'path';
    columnsStartAt1 = true;
    linesStartAt1 = true;
    supportsRunInTerminalRequest = true;
    supportsVariableType = true;
    locale = os.getenv('LANG') or 'en_US';
  }, function(err0, result)
    if err0 then
      utils.notify('Could not initialize debug adapter: ' .. err0.message, vim.log.levels.ERROR)
      adapter_responded = true
      return
    end
    local capabilities = self.capabilities or {}
    self.capabilities = vim.tbl_extend('force', capabilities, result or {})
    self:request(config.request, config, function(err)
      adapter_responded = true
      if err then
        utils.notify(string.format('Error on %s: %s', config.request, err.message), vim.log.levels.ERROR)
        self:close()
        dap().set_session(nil)
      end
    end)
  end)
  local adapter = self.adapter
  local sec_to_wait = (adapter.options or {}).initialize_timeout_sec or 4
  local timer = vim.loop.new_timer()
  timer:start(sec_to_wait * sec_to_ms, 0, function()
    timer:stop()
    timer:close()
    if not adapter_responded then
      vim.schedule(function()
        utils.notify(
          string.format(
            ("Debug adapter didn't respond. "
              .. "Either the adapter is slow (then wait and ignore this) "
              .. "or there is a problem with your adapter or `%s` configuration. Check the logs for errors (:help dap.set_log_level)"),
            config.type),
            vim.log.levels.WARN
          )
      end)
    end
  end)
end


function Session:evaluate(expression, fn)
  self:request('evaluate', {
    expression = expression;
    context = 'repl';
    frameId = (self.current_frame or {}).id;
  }, fn)
end


function Session:disconnect(opts, cb)
  opts = vim.tbl_extend('force', {
    restart = false,
    terminateDebuggee = nil;
  }, opts or {})
  local disconnect_timeout_sec = (self.adapter.options or {}).disconnect_timeout_sec or 3
  self:request_with_timeout('disconnect', opts, disconnect_timeout_sec * sec_to_ms, function(err, resp)
    dap().set_session(nil)
    self:close()
    log.info('Session closed due to disconnect')
    if cb then
      cb(err, resp)
    end
  end)
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
    utils.notify('Cannot move frame if not stopped', vim.log.levels.ERROR)
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


function Session:event_thread(event)
  if event.reason == 'exited' then
    self.threads[event.threadId] = nil
  else
    self.dirty.threads = true
    self.threads[event.threadId] = {
      id = event.threadId,
      name = 'Unknown'
    }
  end
end


function Session:event_continued(event)
  if event.allThreadsContinued then
    for _, t in pairs(self.threads) do
      t.stopped = false
    end
  else
    local thread = self.threads[event.threadId]
    if thread and thread.stopped then
      thread.stopped = false
    end
  end
end


function Session.event_breakpoint()
end

function Session:event_capabilities(body)
  local capabilities = self.capabilities or {}
  self.capabilities = vim.tbl_extend('force', capabilities, body.capabilities)
end

return Session
