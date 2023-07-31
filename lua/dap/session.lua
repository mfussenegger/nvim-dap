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


local ns_pool = {}
do
  local next_id = 1
  local pool = {}

  ---@return number
  function ns_pool.acquire()
    local ns = next(pool)
    if ns then
      pool[ns] = nil
      return ns
    end
    ns = api.nvim_create_namespace('dap-' .. tostring(next_id))
    next_id = next_id + 1
    return ns
  end

  ---@param ns number
  function ns_pool.release(ns)
    pool[ns] = true
  end
end


---@class Session
---@field capabilities dap.Capabilities
---@field adapter Adapter
---@field private dirty table<string, boolean>
---@field private handlers table<string, fun(self: Session, payload: table)|fun()>
---@field private message_callbacks table<number, fun(err: nil|dap.ErrorResponse, body: nil|table, seq: number)>
---@field private message_requests table<number, any>
---@field private client Client
---@field private handle uv_stream_t
---@field current_frame dap.StackFrame|nil
---@field initialized boolean
---@field stopped_thread_id number|nil
---@field id number
---@field threads table<number, dap.Thread>
---@field filetype string filetype of the buffer where the session was started
---@field ns number Namespace id. Valid during lifecycle of a session
---@field sign_group string
---@field closed boolean
---@field on_close table<string, fun(session: Session)> Handler per plugin-id. Invoked when a session closes (due to terminated event, disconnect or error cases like initialize errors, debug adapter process exit, ...). Session is assumed non-functional at this point and handler can be invoked within luv event loop (not API safe, may require vim.schedule)
---@field children table<number, Session>
---@field parent Session|nil


---@class Client
---@field close fun(cb: function)
---@field write fun(line: string)

---@class Session
local Session = {}


local function json_decode(payload)
  return vim.json.decode(payload, { luanil = { object = true }})
end
local json_encode = vim.json.encode
local function send_payload(client, payload)
  local msg = rpc.msg_with_content_length(json_encode(payload))
  client.write(msg)
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

local function co_resume_schedule(co)
  return function(...)
    local args = {...}
    vim.schedule(function()
      coroutine.resume(co, unpack(args))
    end)
  end
end


local function co_resume(co)
  return function(...)
    coroutine.resume(co, ...)
  end
end


local function signal_err(err, cb)
  if err then
    if cb then
      cb(err)
    else
      error(utils.fmt_error(err))
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
    if handle then
      handle:close()
    end
    if code ~= 0 then
      utils.notify(string.format('Terminal exited %d running %s %s', code, terminal.command, table.concat(full_args, ' ')), vim.log.levels.ERROR)
    end
  end)
  return handle, pid_or_err
end


---@param terminal_win_cmd string|fun():integer, integer?
---@return integer bufnr, integer? winnr
local function create_terminal_buf(terminal_win_cmd)
  local cur_win = api.nvim_get_current_win()
  if type(terminal_win_cmd) == "string" then
    api.nvim_command(terminal_win_cmd)
    local bufnr = api.nvim_get_current_buf()
    local win = api.nvim_get_current_win()
    api.nvim_set_current_win(cur_win)
    return bufnr, win
  else
    assert(type(terminal_win_cmd) == "function", "terminal_win_cmd must be a string or a function")
    return terminal_win_cmd()
  end
end


local terminals = {}
do
  ---@type table<integer, boolean>
  local pool = {}

  ---@return integer, integer|nil
  function terminals.acquire(win_cmd, config)
    local buf = next(pool)
    if buf then
      pool[buf] = nil
      if api.nvim_buf_is_valid(buf) then
        vim.bo[buf].modified = false
        return buf
      end
    end
    local terminal_win
    buf, terminal_win = create_terminal_buf(win_cmd)
    if terminal_win then
      if vim.fn.has('nvim-0.8') == 1 then
        -- older versions don't support the `win` key
        api.nvim_set_option_value('number', false, { scope = 'local', win = terminal_win })
        api.nvim_set_option_value('relativenumber', false, { scope = 'local', win = terminal_win })
        api.nvim_set_option_value('signcolumn', 'no', { scope = 'local', win = terminal_win })
      else
        -- this is like `:set` so new windows will inherit the values :/
        vim.wo[terminal_win].number = false
        vim.wo[terminal_win].relativenumber = false
        vim.wo[terminal_win].signcolumn = "no"
      end
    end
    vim.b[buf]['dap-type'] = config.type
    return buf, terminal_win
  end

  ---@param b number
  function terminals.release(b)
    pool[b] = true
  end
end


---@param lsession Session
local function run_in_terminal(lsession, request)
  local body = request.arguments
  log.debug('run_in_terminal', body)
  local settings = dap().defaults[lsession.config.type]
  if body.kind == 'external' or (settings.force_external_terminal and settings.external_terminal) then
    local terminal = settings.external_terminal
    if not terminal then
      utils.notify('Requested external terminal, but none configured. Fallback to integratedTerminal', vim.log.levels.WARN)
    else
      local handle, pid = launch_external_terminal(terminal, body.args)
      if not handle then
        utils.notify('Could not launch terminal ' .. terminal.command, vim.log.levels.ERROR)
      end
      lsession:response(request, {
        success = handle ~= nil;
        body = { processId = pid; };
      })
      return
    end
  end
  local cur_buf = api.nvim_get_current_buf()
  local terminal_buf, terminal_win = terminals.acquire(settings.terminal_win_cmd, lsession.config)
  local terminal_buf_name = '[dap-terminal] ' .. (lsession.config.name or body.args[1])
  local terminal_name_ok = pcall(api.nvim_buf_set_name, terminal_buf, terminal_buf_name)
  if not terminal_name_ok then
    log.warn(terminal_buf_name ..  ' is not a valid buffer name')
    api.nvim_buf_set_name(terminal_buf, '[dap-terminal] dap-' .. tostring(lsession.id))
  end
  pcall(api.nvim_buf_del_keymap, terminal_buf, "t", "<CR>")
  local path = vim.bo[cur_buf].path
  if path and path ~= "" then
    vim.bo[terminal_buf].path = path
  end
  local jobid

  local chan = api.nvim_open_term(terminal_buf, {
    on_input = function(_, _, _, data)
      pcall(api.nvim_chan_send, jobid, data)
    end,
  })
  local opts = {
    env = next(body.env or {}) and body.env or vim.empty_dict(),
    cwd = (body.cwd and body.cwd ~= '') and body.cwd or nil,
    height = terminal_win and api.nvim_win_get_height(terminal_win) or 40,
    width = terminal_win and api.nvim_win_get_width(terminal_win) or 80,
    pty = true,
    on_stdout = function(_, data)
      local count = #data
      for idx, line in pairs(data) do
        if idx == count then
          local send_ok = pcall(api.nvim_chan_send, chan, line)
          if not send_ok then
            return
          end
        else
          local send_ok = pcall(api.nvim_chan_send, chan, line .. '\n')
          if not send_ok then
            return
          end
        end
      end
    end,
    on_exit = function(_, exit_code)
      pcall(api.nvim_chan_send, chan, '\r\n[Process exited ' .. tostring(exit_code) .. ']')
      pcall(api.nvim_buf_set_keymap, terminal_buf, "t", "<CR>", "<cmd>bd!<CR>", { noremap = true, silent = true})
      terminals.release(terminal_buf)
    end,
  }
  jobid = vim.fn.jobstart(body.args, opts)
  if settings.focus_terminal then
    for _, win in pairs(api.nvim_tabpage_list_wins(0)) do
      if api.nvim_win_get_buf(win) == terminal_buf then
        api.nvim_set_current_win(win)
        break
      end
    end
  end
  if jobid == 0 or jobid == -1 then
    log.error('Could not spawn terminal', jobid, request)
    lsession:response(request, {
      success = false;
      message = 'Could not spawn terminal';
    })
  else
    lsession:response(request, {
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
          utils.notify(utils.fmt_error(err1), vim.log.levels.ERROR)
        end
        self.initialized = true
      end)
    else
      self.initialized = true
    end
  end

  local bps = breakpoints.get()
  self:set_breakpoints(bps, function()
    if self.capabilities.exceptionBreakpointFilters then
      self:set_exception_breakpoints(dap().defaults[self.config.type].exception_breakpoints, nil, on_done)
    else
      on_done()
    end
  end)
end


---@param thread_id number
---@param bufnr integer
---@param frame dap.StackFrame
function Session:_show_exception_info(thread_id, bufnr, frame)
  if not self.capabilities.supportsExceptionInfoRequest then
    return
  end
  local err, response = self:request('exceptionInfo', {threadId = thread_id})
  if err then
    utils.notify('Error getting exception info: ' .. utils.fmt_error(err), vim.log.levels.ERROR)
  end
  if not response then
    return
  end
  local msg_parts = {}
  local exception_type = response.details and response.details.typeName
  local of_type = exception_type and ' of type '..exception_type or ''
  table.insert(msg_parts, ('Thread stopped due to exception'..of_type..' ('..response.breakMode..')'))
  if response.description then
    table.insert(msg_parts, ('Description: '..response.description))
  end
  local details = response.details or {}
  if details.stackTrace then
    table.insert(msg_parts, "Stack trace:")
    table.insert(msg_parts, details.stackTrace)
  end
  if details.innerException then
    table.insert(msg_parts, "Inner Exceptions:")
    for _, e in pairs(details.innerException) do
      table.insert(msg_parts, vim.inspect(e))
    end
  end
  vim.diagnostic.set(self.ns, bufnr, {
    {
      bufnr = bufnr,
      lnum = frame.line - 1,
      end_lnum = frame.endLine and (frame.endLine - 1) or nil,
      col = frame.column and (frame.column - 1) or 0,
      end_col = frame.endColumn,
      severity = vim.diagnostic.severity.ERROR,
      message = table.concat(msg_parts, '\n'),
      source = 'nvim-dap',
    }
  })
end



---@param win integer
---@param line integer
---@param column integer
local function set_cursor(win, line, column)
  local ok, err = pcall(api.nvim_win_set_cursor, win, { line, column - 1 })
  if ok then
    local curbuf = api.nvim_get_current_buf()
    if vim.bo[curbuf].filetype ~= "dap-repl" then
      api.nvim_set_current_win(win)
    end
    api.nvim_win_call(win, function()
      api.nvim_command('normal! zv')
    end)
  else
    local msg = string.format(
      "Debug adapter reported a frame at line %s column %s, but: %s. "
      .. "Ensure executable is up2date and if using a source mapping ensure it is correct",
      line,
      column,
      err
    )
    utils.notify(msg, vim.log.levels.WARN)
  end
end


---@param bufnr number
---@param line number
---@param column number
---@param switchbuf string
---@param filetype string
local function jump_to_location(bufnr, line, column, switchbuf, filetype)
  progress.report('Stopped at line ' .. line)
  -- vscode-go sends columns with 0
  -- That would cause a "Column value outside range" error calling nvim_win_set_cursor
  -- nvim-dap says "columnsStartAt1 = true" on initialize :/
  if column == 0 then
    column = 1
  end
  local cur_buf = api.nvim_get_current_buf()
  if cur_buf == bufnr and api.nvim_win_get_cursor(0)[1] == line and column == 1 then
    -- A user might have positioned the cursor over a variable in anticipation of hitting a breakpoint
    -- Don't move the cursor to the beginning of the line if it's in the right place
    return
  end

  local cur_win = api.nvim_get_current_win()
  local switchbuf_fn = {}

  function switchbuf_fn.uselast()
    if vim.bo[cur_buf].buftype == '' or vim.bo[cur_buf].filetype == filetype then
      api.nvim_win_set_buf(cur_win, bufnr)
      set_cursor(cur_win, line, column)
    else
      local win = vim.fn.win_getid(vim.fn.winnr('#'))
      if win then
        api.nvim_win_set_buf(win, bufnr)
        set_cursor(win, line, column)
      end
    end
    return true
  end

  function switchbuf_fn.useopen()
    if api.nvim_win_get_buf(cur_win) == bufnr then
      set_cursor(cur_win, line, column)
      return true
    end
    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
      if api.nvim_win_get_buf(win) == bufnr then
        set_cursor(win, line, column)
        return true
      end
    end
    return false
  end

  function switchbuf_fn.usetab()
    if api.nvim_win_get_buf(cur_win) == bufnr then
      set_cursor(cur_win, line, column)
      return true
    end
    local tabs = {0,}
    vim.list_extend(tabs, api.nvim_list_tabpages())
    for _, tabpage in ipairs(tabs) do
      for _, win in ipairs(api.nvim_tabpage_list_wins(tabpage)) do
        if api.nvim_win_get_buf(win) == bufnr then
          api.nvim_set_current_tabpage(tabpage)
          set_cursor(win, line, column)
          return true
        end
      end
    end
    return false
  end

  function switchbuf_fn.split()
    vim.cmd('split ' .. api.nvim_buf_get_name(bufnr))
    set_cursor(0, line, column)
    return true
  end

  function switchbuf_fn.vsplit()
    vim.cmd('vsplit ' .. api.nvim_buf_get_name(bufnr))
    set_cursor(0, line, column)
    return true
  end

  function switchbuf_fn.newtab()
    vim.cmd('tabnew ' .. api.nvim_buf_get_name(bufnr))
    set_cursor(0, line, column)
    return true
  end

  if switchbuf:find('usetab') then
    switchbuf_fn.useopen = switchbuf_fn.usetab
  end

  if switchbuf:find('newtab') then
    switchbuf_fn.vsplit = switchbuf_fn.newtab
    switchbuf_fn.split = switchbuf_fn.newtab
  end

  local opts = vim.split(switchbuf, ',', { plain = true })
  for _, opt in pairs(opts) do
    local fn = switchbuf_fn[opt]
    if fn and fn() then
      return
    end
  end
  utils.notify(
    'Stopped at line ' .. line .. ' but `switchbuf` setting prevented jump to location. Target buffer ' .. bufnr .. ' not open in any window?',
    vim.log.levels.WARN
  )
end


--- Get the bufnr for a frame.
--- Might load source as a side effect if frame.source has sourceReference ~= 0
--- Must be called in a coroutine
---
---@param session Session
---@param frame dap.StackFrame
---@return number|nil
local function frame_to_bufnr(session, frame)
  local source = frame.source
  if not source then
    return nil
  end
  if not source.sourceReference or source.sourceReference == 0 then
    if not source.path then
      return nil
    end
    local scheme = source.path:match('^([a-z]+)://.*')
    if scheme then
      return vim.uri_to_bufnr(source.path)
    else
      return vim.uri_to_bufnr(vim.uri_from_fname(source.path))
    end
  end
  local co = coroutine.running()
  assert(co, 'Must run in coroutine')
  session:source(source, co_resume(co))
  local _, bufnr = coroutine.yield()
  return bufnr
end


---@param session Session
---@param frame dap.StackFrame
---@param preserve_focus_hint boolean
---@param stopped nil|dap.StoppedEvent
local function jump_to_frame(session, frame, preserve_focus_hint, stopped)
  local source = frame.source
  if not source then
    utils.notify('Source not available, cannot jump to frame', vim.log.levels.INFO)
    return
  end
  vim.fn.sign_unplace(session.sign_group)
  if preserve_focus_hint or frame.line < 0 then
    return
  end
  local bufnr = frame_to_bufnr(session, frame)
  if not bufnr then
    utils.notify('Source not available, cannot jump to frame', vim.log.levels.INFO)
    return
  end
  vim.fn.bufload(bufnr)
  local ok, failure = pcall(vim.fn.sign_place, 0, session.sign_group, 'DapStopped', bufnr, { lnum = frame.line; priority = 12 })
  if not ok then
    utils.notify(failure, vim.log.levels.ERROR)
  end
  local switchbuf = defaults(session).switchbuf or vim.o.switchbuf or 'uselast'
  jump_to_location(bufnr, frame.line, frame.column, switchbuf, session.filetype)
  if stopped and stopped.reason == 'exception' then
    session:_show_exception_info(stopped.threadId, bufnr, frame)
  end
end


--- Request a source
---@param source dap.Source
---@param cb fun(err, buf) the buffer will have the contents of the source
function Session:source(source, cb)
  assert(source, 'source is required')
  assert(source.sourceReference, 'sourceReference is required')
  assert(source.sourceReference ~= 0, 'sourceReference must not be 0')
  local params = {
    source = source,
    sourceReference = source.sourceReference
  }
  self:request('source', params, function(err, response)
    if signal_err(err, cb) then
      return
    end
    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_var(buf, 'dap_source_buf', true)
    local adapter_options = self.adapter.options or {}
    local ft = mime_to_filetype[response.mimeType] or adapter_options.source_filetype
    if ft then
      vim.bo[buf].filetype = ft
    end
    api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(response.content, '\n'))
    if not ft and source.path and vim.filetype then
      pcall(api.nvim_buf_set_name, buf, source.path)
      local ok, filetype = pcall(vim.filetype.match, source.path, buf)
      if not ok then
        -- API changed
        ok, filetype = pcall(vim.filetype.match, { buf = buf })
      end
      if ok and filetype then
        vim.bo[buf].filetype = filetype
      end
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
      local old_thread = self.threads[thread.id]
      if old_thread and old_thread.stopped then
        thread.stopped = true
      end
    end
    self.threads = threads
    self.dirty.threads = false
    if cb then
      cb(nil, threads)
    end
  end)
end


---@param frames dap.StackFrame[]
---@return dap.StackFrame|nil
local function get_top_frame(frames)
  for _, frame in pairs(frames) do
    if frame.source then
      return frame
    end
  end
  local _, first = next(frames)
  return first
end


---@param stopped dap.StoppedEvent
function Session:event_stopped(stopped)
  if self.dirty.threads or (stopped.threadId and self.threads[stopped.threadId] == nil) then
    self:update_threads(function(err)
      if err then
        utils.notify('Error retrieving threads: ' .. utils.fmt_error(err), vim.log.levels.ERROR)
        return
      end
      self:event_stopped(stopped)
    end)
    return
  end

  local should_jump = stopped.reason ~= 'pause' or stopped.allThreadsStopped

  -- Some debug adapters allow to continue/step via custom REPL commands (via evaluate)
  -- That by-passes `clear_running`, resulting in self.stopped_thread_id still being set
  -- Dont auto-continue if`threadId == self.stopped_thread_id`, but stop & jump
  if self.stopped_thread_id and self.stopped_thread_id ~= stopped.threadId and should_jump then
    if defaults(self).auto_continue_if_many_stopped then
      local thread = self.threads[self.stopped_thread_id]
      local thread_name = thread and thread.name or self.stopped_thread_id
      log.debug(
        'Received stopped event, but ' .. thread_name .. ' is already stopped. ' ..
        'Resuming newly stopped thread. ' ..
        'To disable this set the `auto_continue_if_many_stopped` option to false.')
      self:request('continue', { threadId = stopped.threadId })
      return
    else
      -- Allow thread to stop, but don't jump to it because stepping
      -- interleaved between threads is confusing
      should_jump = false
    end
  end
  if should_jump then
    self.stopped_thread_id = stopped.threadId
  end

  if stopped.allThreadsStopped then
    progress.report('All threads stopped')
    for _, thread in pairs(self.threads) do
      thread.stopped = true
    end
  elseif stopped.threadId then
    progress.report('Thread stopped: ' .. stopped.threadId)
    self.threads[stopped.threadId].stopped = true
  else
    utils.notify('Stopped event received, but no threadId or allThreadsStopped', vim.log.levels.WARN)
  end

  if not stopped.threadId then
    return
  end
  local thread = self.threads[stopped.threadId]
  assert(thread, 'Thread not found: ' .. stopped.threadId)

  coroutine.wrap(function()
    local err, response = self:request('stackTrace', { threadId = stopped.threadId; })
    if err then
      utils.notify('Error retrieving stack traces: ' .. utils.fmt_error(err), vim.log.levels.ERROR)
      return
    end
    local frames = response.stackFrames --[=[@as dap.StackFrame[]]=]
    thread.frames = frames
    local current_frame = get_top_frame(frames)
    if not current_frame then
      utils.notify('Debug adapter stopped at unavailable location', vim.log.levels.WARN)
      return
    end
    if should_jump then
      self.current_frame = current_frame
      jump_to_frame(self, current_frame, stopped.preserveFocusHint, stopped)
      self:_request_scopes(current_frame)
    elseif stopped.reason == "exception" then
      local bufnr = frame_to_bufnr(self, current_frame)
      if bufnr then
        self:_show_exception_info(stopped.threadId, bufnr, current_frame)
      end
    end
  end)()
end


---@param body dap.TerminatedEvent
function Session:event_terminated(body)
  self:close()
  if body and body.restart ~= nil and body.restart ~= false then
    local config = vim.deepcopy(self.config)
    config.__restart = body.restart
    -- This will set global session, is this still okay once startDebugging is implemented?
    dap().run(config, { filetype = self.filetype, new = true })
  end
end


function Session.event_output(_, body)
  if body.category == 'telemetry' then
    log.info('Telemetry', body.output)
  else
    repl.append(body.output, '$', { newline = false })
  end
end


---@param current_frame dap.StackFrame
function Session:_request_scopes(current_frame)
  self:request('scopes', { frameId = current_frame.id }, function(_, scopes_resp)
    if not scopes_resp or not scopes_resp.scopes then
      return
    end
    current_frame.scopes = {}
    for _, scope in pairs(scopes_resp.scopes) do
      table.insert(current_frame.scopes, scope)
      if not scope.expensive then
        local params = { variablesReference = scope.variablesReference }
        self:request('variables', params, function(_, variables_resp)
          if not variables_resp then
            return
          end
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
    utils.notify("No current frame available, cannot use goto", vim.log.levels.INFO)
    return
  end
  if not self.capabilities.supportsGotoTargetsRequest then
    utils.notify("Debug Adapter doesn't support GotoTargetRequest", vim.log.levels.INFO)
    return
  end
  coroutine.wrap(function()
    local err, response = self:request('gotoTargets',  {source = source or frame.source, line = line, col = col})
    if err then
      utils.notify('Error getting gotoTargets: ' .. utils.fmt_error(err), vim.log.levels.ERROR)
      return
    end
    if not response or not response.targets then
      utils.notify("No goto targets available. Can't execute goto", vim.log.levels.INFO)
      return
    end
    local target = ui().pick_if_many(
      response.targets,
      'goto target> ',
      function(target) return target.label end
    )
    if not target then
      return
    end
    local params = {threadId = self.stopped_thread_id, targetId = target.id }
    local thread = self.threads[self.stopped_thread_id]
    if thread then
      thread.stopped = false
    end
    self.stopped_thread_id = nil
    local goto_err = self:request('goto', params)
    if goto_err then
      utils.notify('Error executing goto: ' .. utils.fmt_error(goto_err), vim.log.levels.ERROR)
    end
  end)()
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

  local detach_handlers = {}

  local function remove_breakpoints(_, buf)
    local session = dap().session()
    if session then
      session:set_breakpoints({[buf] = {}})
    end
    detach_handlers[buf] = nil
  end

  function Session:set_breakpoints(bps, on_done)
    local num_requests = vim.tbl_count(bps)
    if num_requests == 0 then
      if on_done then
        on_done()
      end
      return
    end
    for bufnr, buf_bps in pairs(bps) do
      notify_if_missing_capability(buf_bps, self.capabilities)
      if non_empty(buf_bps) and not detach_handlers[bufnr] then
        detach_handlers[bufnr] = true
        api.nvim_buf_attach(bufnr, false, { on_detach = remove_breakpoints })
      end
      local path = api.nvim_buf_get_name(bufnr)
      local payload = {
        source = {
          path = path;
          name = vim.fn.fnamemodify(path, ':t')
        };
        sourceModified = false;
        breakpoints = vim.tbl_map(
          function(bp)
            -- trim extra information like the state
            return {
              line = bp.line,
              column = bp.column,
              condition = bp.condition,
              hitCondition = bp.hitCondition,
              logMessage = bp.logMessage,
            }
          end,
          buf_bps
        ),
        lines = vim.tbl_map(function(x) return x.line end, buf_bps);
      }
      self:request('setBreakpoints', payload, function(err1, resp)
        if err1 then
          utils.notify('Error setting breakpoints: ' .. utils.fmt_error(err1), vim.log.levels.ERROR)
        elseif resp then
          for _, bp in pairs(resp.breakpoints) do
            breakpoints.set_state(bufnr, bp.line, bp)
            if not bp.verified then
              log.info('Server rejected breakpoint', bp)
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
    ---@diagnostic disable-next-line: redundant-parameter, param-type-mismatch
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
        utils.notify('Error setting exception breakpoints: ' .. utils.fmt_error(err), vim.log.levels.ERROR)
      end
      if on_done then
        on_done()
      end
  end)
end


function Session:handle_body(body)
  local decoded = assert(json_decode(body), "Debug adapter must send JSON objects")
  log.debug(self.id, decoded)
  local listeners = dap().listeners
  if decoded.request_seq then
    local callback = self.message_callbacks[decoded.request_seq]
    local request = self.message_requests[decoded.request_seq]
    self.message_requests[decoded.request_seq] = nil
    self.message_callbacks[decoded.request_seq] = nil
    if not callback then
      log.error('No callback found. Did the debug adapter send duplicate responses?', decoded)
      return
    end
    if decoded.success then
      vim.schedule(function()
        for _, c in pairs(listeners.before[decoded.command]) do
          c(self, nil, decoded.body, request, decoded.request_seq)
        end
        callback(nil, decoded.body, decoded.request_seq)
        for _, c in pairs(listeners.after[decoded.command]) do
          c(self, nil, decoded.body, request, decoded.request_seq)
        end
      end)
    else
      vim.schedule(function()
        local err = { message = decoded.message; body = decoded.body; }
        for _, c in pairs(listeners.before[decoded.command]) do
          c(self, err, nil, request, decoded.request_seq)
        end
        callback(err, nil, decoded.request_seq)
        for _, c in pairs(listeners.after[decoded.command]) do
          c(self, err, nil, request, decoded.request_seq)
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


---@param self Session
local function start_debugging(self, request)
  local body = request.arguments --[[@as dap.StartDebuggingRequestArguments]]
  coroutine.wrap(function()
    local co = coroutine.running()
    local opts = {
      filetype = self.filetype
    }
    local config = body.configuration
    local adapter = dap().adapters[config.type or self.config.type]
    config.request = body.request

    if type(adapter) == "function" then
      adapter(co_resume_schedule(co), config, self)
      adapter = coroutine.yield()
    end

    -- Prefer connecting to root server again if it is of type server and
    -- the new adapter would have an executable.
    -- Spawning a new executable is likely the wrong thing to do
    if self.adapter.type == "server" and adapter.executable then
      adapter = vim.deepcopy(self.adapter)
      adapter.executable = nil
    end

    local expected_types = {"executable", "server"}
    if type(adapter) ~= "table" or not vim.tbl_contains(expected_types, adapter.type) then
      local msg = "Invalid adapter definition. Expected a table with type `executable` or `server`: "
      utils.notify(msg .. vim.inspect(adapter), vim.log.levels.ERROR)
      return
    end

    ---@param session Session
    local function on_child_session(session)
      session.parent = self
      self.children[session.id] = session
      session.on_close['dap.session.child'] = function(s)
        if s.parent then
          s.parent.children[s.id] = nil
          s.parent = nil
        end
      end
      session:initialize(config)
      self:response(request, {success = true})
    end

    if adapter.type == "executable" then
      local session = Session:spawn(adapter, opts)
      on_child_session(session)
    elseif adapter.type == "server" then
      local session
      session = Session:connect(adapter, opts, function(err)
        if err then
          utils.notify(string.format(
            "Could not connect startDebugging child session %s:%s: %s",
            adapter.host or '127.0.0.1',
            adapter.port,
            err
          ), vim.log.levels.WARN)
        elseif session then
          on_child_session(session)
        end
      end)
    end
  end)()
end


local default_reverse_request_handlers = {
  runInTerminal = run_in_terminal,
  startDebugging = start_debugging,
}

local next_session_id = 1

---@param adapter Adapter
---@param handle uv_stream_t
---@return Session
local function new_session(adapter, opts, handle)
  local handlers = {}
  handlers.after = opts.after
  handlers.reverse_requests = vim.tbl_extend(
    'error',
    default_reverse_request_handlers,
    adapter.reverse_request_handlers or {}
  )
  local ns = ns_pool.acquire()
  local state = {
    id = next_session_id,
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
    capabilities = {};
    filetype = opts.filetype or vim.bo.filetype,
    ns = ns,
    sign_group = 'dap-' .. tostring(ns),
    closed = false,
    on_close = {},
    children = {},
    handle = handle,
    client = {}
  }
  function state.client.write(line)
    state.handle:write(line)
  end

  function state.client.close(cb)
    cb = cb or function() end
    if state.handle:is_closing() then
      cb()
      return
    end
    state.handle:shutdown(function()
      state.handle:close()
      state.closed = true
      cb()
    end)
  end
  next_session_id = next_session_id + 1
  return setmetatable(state, { __index = Session })
end


local function get_free_port()
  local tcp = assert(uv.new_tcp(), "Must be able to create tcp client")
  tcp:bind('127.0.0.1', 0)
  local port = tcp:getsockname().port
  tcp:shutdown()
  tcp:close()
  return port
end


--- Spawn the executable or raise an error if the command doesn't start.
---
--- Adds a on_close hook on the session to terminate the executable once the
--- session closes.
---
---@param executable ServerAdapterExecutable
---@param session Session
local function spawn_server_executable(executable, session)
  local cmd = assert(executable.command, "executable of server adapter must have a `command` property")
  log.debug("Starting debug adapter server executable", executable)
  local stdout = assert(uv.new_pipe(false), "Must be able to create pipe")
  local stderr = assert(uv.new_pipe(false), "Must be able to create pipe")
  local opts = {
    stdio = {nil, stdout, stderr},
    args = executable.args or {},
    detached = utils.if_nil(executable.detached, true),
    cwd = executable.cwd,
  }
  local handle, pid_or_err
  handle, pid_or_err = uv.spawn(cmd, opts, function(code)
    if handle then
      handle:close()
    end
    if code ~= 0 then
      utils.notify(cmd .. " exited with code " .. code, vim.log.levels.WARN)
    end
  end)
  if not handle then
    stdout:close()
    stderr:close()
    error(pid_or_err)
  end

  local read_output = function(stream, pipe)
    return function(err, chunk)
      assert(not err, err)
      if chunk then
        vim.schedule(function()
          repl.append('[debug-adapter ' .. stream .. '] ' .. chunk)
        end)
      else
        pipe:close()
      end
    end
  end
  stderr:read_start(read_output('stderr', stderr))
  stdout:read_start(read_output('stdout', stdout))

  session.on_close["dap.server_executable"] = function()
    if not handle:is_closing() then
      handle:kill("sigterm")
    end
  end
end


---@param adapter PipeAdapter
---@param opts? table
---@param on_connect fun(err?: string)
---@return Session
function Session.pipe(adapter, opts, on_connect)
  local pipe = assert(uv.new_pipe(), "Must be able to create pipe")
  local session = new_session(adapter, opts or {}, pipe)

  if adapter.executable then
    if adapter.pipe == "${pipe}" then
      -- don't mutate original adapter definition
      adapter = vim.deepcopy(adapter)
      session.adapter = adapter

      local filepath = os.tmpname()
      os.remove(filepath)
      session.on_close["dap.server_executable_pipe"] = function()
        pcall(os.remove, filepath)
      end
      adapter.pipe = filepath
      if adapter.executable.args then
        local args = assert(adapter.executable.args)
        for idx, arg in pairs(args) do
          args[idx] = arg:gsub('${pipe}', filepath)
        end
      end
    end
    spawn_server_executable(adapter.executable, session)
    log.debug(
      "Debug adapter server executable started with pipe " .. adapter.pipe)
    -- The adapter should create the pipe
    vim.wait(5000, function()
      return uv.fs_stat(adapter.pipe) ~= nil
    end)
  end

  pipe:connect(adapter.pipe, function(err)
    if err then
      local msg = string.format("Couldn't connect to pipe %s: %s", adapter.pipe, err)
      utils.notify(msg, vim.log.levels.ERROR)
      session:close()
    else
      progress.report("Connected to " .. adapter.pipe)
      local handle_body = vim.schedule_wrap(function(body)
        session:handle_body(body)
      end)
      pipe:read_start(rpc.create_read_loop(handle_body, function()
        if not session.closed then
          session:close()
          utils.notify("Debug adapter disconnected", vim.log.levels.INFO)
        end
      end))
    end
    on_connect(err)
  end)
  return session
end


function Session.connect(_, adapter, opts, on_connect)
  local client = assert(uv.new_tcp(), "Must be able to create TCP client")
  local session = new_session(adapter, opts or {}, client)

  if adapter.executable then
    if adapter.port == "${port}" then
      local port = get_free_port()
      -- don't mutate original adapter definition
      adapter = vim.deepcopy(adapter)
      session.adapter = adapter
      adapter.port = port
      if adapter.executable.args then
        local args = assert(adapter.executable.args)
        for idx, arg in pairs(args) do
          args[idx] = arg:gsub('${port}', tostring(port))
        end
      end
    end
    spawn_server_executable(adapter.executable, session)
    log.debug(
      "Debug adapter server executable started, listening on " .. adapter.port)
  end

  log.debug('Connecting to debug adapter', adapter)
  local max_retries = (adapter.options or {}).max_retries or 14

  local host = adapter.host or '127.0.0.1'
  local on_addresses
  on_addresses = function(err, addresses, retry_count)
    if err or #addresses == 0 then
      err = err or ('Could not resolve ' .. host)
      session:close()
      on_connect(err)
      return
    end
    local address = addresses[1]
    local port = assert(tonumber(adapter.port), "adapter.port is required for server adapter")
    client:connect(address.addr, port, function(conn_err)
      if conn_err then
        retry_count = retry_count or 1
        if retry_count < max_retries then
          -- Possible luv bug? A second client:connect gets stuck
          -- Create new handle as workaround
          client:close()
          client = assert(uv.new_tcp(), "Must be able to create TCP client")
          ---@diagnostic disable-next-line: invisible
          session.handle = client
          local timer = assert(uv.new_timer(), "Must be able to create timer")
          timer:start(250, 0, function()
            timer:stop()
            timer:close()
            on_addresses(nil, addresses, retry_count + 1)
          end)
        else
          session:close()
          on_connect(conn_err)
        end
        return
      end
      local handle_body = vim.schedule_wrap(function(body)
        session:handle_body(body)
      end)
      client:read_start(rpc.create_read_loop(handle_body, function()
        if not session.closed then
          session:close()
          utils.notify('Debug adapter disconnected', vim.log.levels.INFO)
        end
      end))
      on_connect(nil)
    end)
  end
  -- getaddrinfo fails for some users with `bad argument #3 to 'getaddrinfo' (Invalid protocol hint)`
  -- It should generally work with luv 1.42.0 but some still get errors
  if uv.version() >= 76288 then
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


---@param adapter ExecutableAdapter
---@param opts table|nil
---@return Session
function Session.spawn(_, adapter, opts)
  log.debug('Spawning debug adapter', adapter)

  local stdin = assert(uv.new_pipe(false), "Must be able to create pipe")
  local stdout = assert(uv.new_pipe(false), "Must be able to create pipe")
  local stderr = assert(uv.new_pipe(false), "Must be able to create pipe")
  local handle
  local pid_or_err
  local closed = false
  local function onexit(cb)
    if closed then
      return
    end
    cb = cb or function() end
    closed = true
    stdin:shutdown(function()
      stdin:close()
      stdout:shutdown(function()
        stdout:close()
        stderr:close()
        if handle and not handle:is_closing() then
          handle:close(function()
            log.info('Process closed', pid_or_err, handle:is_active())
            handle = nil
            cb()
          end)
        else
          cb()
        end
      end)
    end)
  end
  local options = adapter.options or {}
  local spawn_opts = {
    args = adapter.args;
    stdio = {stdin, stdout, stderr};
    cwd = options.cwd;
    env = options.env;
    detached = utils.if_nil(options.detached, true);
  }
  local session
  handle, pid_or_err = uv.spawn(adapter.command, spawn_opts, function(code)
    onexit()
    if code ~= 0 then
      utils.notify(adapter.command .. " exited with code: " .. tostring(code), vim.log.levels.WARN)
    end
    if session and not session.closed then
      session:close()
    end
  end)
  if not handle then
    onexit()
    if adapter.command == "" then
      error("adapter.command must not be empty. Got: " .. vim.inspect(adapter))
    else
      error('Error running ' .. adapter.command .. ': ' .. pid_or_err)
    end
  end
  session = new_session(adapter, opts or {}, stdin)
  session.client.close = onexit
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
      utils.notify('Error pausing: ' .. utils.fmt_error(err), vim.log.levels.ERROR)
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
        utils.notify('Error requesting threads: ' .. utils.fmt_error(err), vim.log.levels.ERROR)
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


---@param session Session
local function clear_running(session, thread_id)
  vim.fn.sign_unplace(session.sign_group)
  thread_id = thread_id or session.stopped_thread_id
  session.stopped_thread_id = nil
  local thread = session.threads[thread_id]
  if thread then
    thread.stopped = false
  end
end


function Session:restart_frame()
  if not self.capabilities.supportsRestartFrame then
    utils.notify('Debug Adapter does not support restart frame', vim.log.levels.INFO)
    return
  end
  local frame = self.current_frame
  if not frame then
    local msg = 'Current frame not set. Debug adapter needs to be stopped at breakpoint to use restart frame'
    utils.notify(msg, vim.log.levels.INFO)
    return
  end
  coroutine.wrap(function()
    if frame.canRestart == false then
      local thread = self.threads[self.stopped_thread_id] or {}
      local frames = vim.tbl_filter(
        function(f) return f.canRestart == nil or f.canRestart == true end,
        thread.frames or {}
      )
      if not next(frames) then
        utils.notify("No frame available that can be restarted", vim.log.levels.WARN)
        return
      end
      frame = ui().pick_one(
        frames,
        "Can't restart current frame, pick another frame to restart: ",
        require('dap.entity').frames.render_item
      )
      if not frame then
        return
      end
    end
    clear_running(self)
    local err = self:request('restartFrame', { frameId = frame.id })
    if err then
      utils.notify('Error on restart_frame: ' .. utils.fmt_error(err), vim.log.levels.ERROR)
    end
  end)()
end


---@param step "next"|"stepIn"|"stepOut"|"stepBack"|"continue"|"reverseContinue"
---@param params table|nil
function Session:_step(step, params)
  local count = vim.v.count1 - 1
  local function step_thread(thread_id)
    if count > 0 then
      local listeners = dap().listeners
      local clear_listeners = function()
        listeners.after.event_stopped['dap.step'] = nil
        listeners.after.event_terminated['dap.step'] = nil
        listeners.after.disconnect['dap.step'] = nil
      end
      listeners.after.event_stopped['dap.step'] = function()
        if count > 0 then
          count = count - 1
          step_thread(thread_id)
        else
          clear_listeners()
        end
      end
      listeners.after.event_terminated['dap.step'] = clear_listeners
      listeners.after.disconnect['dap.step'] = clear_listeners
    end
    params = params or {}
    params.threadId = thread_id
    if not params.granularity then
      params.granularity = dap().defaults[self.config.type].stepping_granularity
    end
    clear_running(self, thread_id)
    self:request(step, params, function(err)
      if err then
        utils.notify('Error on '.. step .. ': ' .. utils.fmt_error(err), vim.log.levels.ERROR)
      end
      progress.report('Running')
    end)
  end

  if self.stopped_thread_id then
    step_thread(self.stopped_thread_id)
  else
    local paused_threads = vim.tbl_filter(
      function(t) return t.stopped end,
      vim.tbl_values(self.threads)
    )
    if not next(paused_threads) then
      utils.notify('No stopped threads. Cannot move', vim.log.levels.ERROR)
      return
    end
    ui().pick_if_many(
      paused_threads,
      "Select thread to step in> ",
      function(t) return t.name end,
      function(thread)
        if thread then
          step_thread(thread.id)
        end
      end
    )
  end
end


function Session:close()
  self.closed = true
  for _, on_close in pairs(self.on_close) do
    local ok, err = pcall(on_close, self)
    if not ok then
      log.warn(err)
    end
  end
  self.on_close = {}
  if self.handlers.after then
    local ok, err = pcall(self.handlers.after)
    if not ok then
      log.warn(err)
    end
    self.handlers.after = nil
  end
  vim.schedule(function()
    pcall(vim.fn.sign_unplace, self.sign_group)
    vim.diagnostic.reset(self.ns)
    ns_pool.release(self.ns)
  end)
  self.client.close(function()
    self.threads = {}
    self.message_callbacks = {}
    self.message_requests = {}
  end)
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
  local timer = assert(uv.new_timer(), "Must be able to create timer")
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
        utils.notify(err.message, vim.log.levels.INFO)
      end
    end
  end)
end


--- Send a request to the debug adapter
---@param command string command to execute
---@param arguments any|nil object containing arguments for the command
---@param callback fun(err: table, result: any)|nil
--  callback called with the response result.
--- If nil and running within a coroutine the function will yield the result
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
  local co
  if not callback then
    co = coroutine.running()
    if co then
      callback = co_resume(co)
    else
      -- Assume missing callback is intentional.
      -- Prevent error logging in Session:handle_body
      callback = function(_, _)
      end
    end
  end
  self.message_callbacks[current_seq] = callback
  self.message_requests[current_seq] = arguments
  send_payload(self.client, payload)
  if co then
    return coroutine.yield()
  end
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


--- Initialize the debug session
---@param config Configuration
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
    supportsProgressReporting = true,
    supportsStartDebuggingRequest = true,
    locale = os.getenv('LANG') or 'en_US';
  }, function(err0, result)
    if err0 then
      utils.notify('Could not initialize debug adapter: ' .. utils.fmt_error(err0), vim.log.levels.ERROR)
      adapter_responded = true
      return
    end
    self.capabilities = vim.tbl_extend('force', self.capabilities, result or {})
    self:request(config.request, config, function(err)
      adapter_responded = true
      if err then
        utils.notify(string.format('Error on %s: %s', config.request, utils.fmt_error(err)), vim.log.levels.ERROR)
        self:close()
      end
    end)
  end)
  local adapter = self.adapter
  local sec_to_wait = (adapter.options or {}).initialize_timeout_sec or 4
  local timer = assert(uv.new_timer(), "Must be able to create timer")
  timer:start(sec_to_wait * sec_to_ms, 0, function()
    timer:stop()
    timer:close()
    if not adapter_responded and not self.closed then
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
    self:close()
    log.info('Session closed due to disconnect')
    if cb then
      cb(err, resp)
    end
  end)
end


---@param frame? dap.StackFrame
function Session:_frame_set(frame)
  if not frame then
    return
  end
  self.current_frame = frame
  coroutine.wrap(function()
    jump_to_frame(self, frame, false)
    self:_request_scopes(frame)
  end)()
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
    current_frame_index = 1
    utils.notify("Can't move past first frame", vim.log.levels.INFO)
  elseif current_frame_index > #frames then
    current_frame_index = #frames
    utils.notify("Can't move past last frame", vim.log.levels.INFO)
  end
  self:_frame_set(frames[current_frame_index])
end


function Session.event_exited()
end

function Session.event_module()
end

function Session.event_process()
end


function Session.event_loadedSource()
end


---@param event dap.ThreadEvent
function Session:event_thread(event)
  if event.reason == 'exited' then
    self.threads[event.threadId] = nil
  else
    local thread = self.threads[event.threadId]
    if thread then
      thread.stopped = false
      if self.stopped_thread_id == thread.id then
        self.stopped_thread_id = nil
      end
    else
      self.dirty.threads = true
      self.threads[event.threadId] = {
        id = event.threadId,
        name = 'Unknown'
      }
    end
  end
end


---@param event dap.ContinuedEvent
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


---@param event dap.BreakpointEvent
function Session.event_breakpoint(_, event)
  if event.reason == 'changed' then
    local bp = event.breakpoint
    if bp.id then
      breakpoints.update(bp)
    end
  end
end


function Session:event_capabilities(body)
  self.capabilities = vim.tbl_extend('force', self.capabilities, body.capabilities)
end


---@param body dap.ProgressStartEvent
function Session.event_progressStart(_, body)
  if body.message then
    progress.report(body.title .. ': ' .. body.message)
  else
    progress.report(body.title)
  end
end

---@param body dap.ProgressUpdateEvent
function Session.event_progressUpdate(_, body)
  if body.message then
    progress.report(body.message)
  end
end

---@param body dap.ProgressEndEvent
function Session:event_progressEnd(body)
  if body.message then
    progress.report(body.message)
  else
    progress.report('Running: ' .. (self.config.name or '[No Name]'))
  end
end


return Session
