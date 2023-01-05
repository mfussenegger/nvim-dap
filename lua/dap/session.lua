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
local ns = api.nvim_create_namespace('dap')


---@class Session
---@field capabilities Capabilities
---@field adapter Adapter
---@field dirty table<string, boolean>
---@field handlers table<string, fun(self: Session, payload: table)|fun()>
---@field message_callbacks table<number, fun(err: nil|ErrorResponse, body: nil|table, seq: number)>
---@field message_requests table<number, any>
---@field client Client
---@field current_frame dap.StackFrame|nil
---@field initialized boolean
---@field stopped_thread_id number|nil
---@field id number
---@field threads table<number, dap.Thread>
---@field filetype string filetype of the buffer where the session was started

---@class dap.Thread
---@field id number
---@field name string
---@field frames nil|dap.StackFrame[] not part of the spec; added by nvim-dap
---@field stopped nil|boolean not part of the spec; added by nvim-dap

---@class ErrorResponse
---@field message string
---@field body ErrorBody

---@class ErrorBody
---@field error nil|Message

---@class Message
---@field id number
---@field format string
---@field variables nil|table
---@field showUser nil|boolean

---@class dap.StackFrame
---@field id number
---@field name string
---@field source dap.Source|nil
---@field line number
---@field column number
---@field endLine nil|number
---@field endColumn nil|number
---@field canRestart boolean|nil
---@field presentationHint nil|"normal"|"label"|"subtle";

---@class dap.Source
---@field name nil|string
---@field path nil|string
---@field sourceReference nil|number
---@field presentationHint nil|"normal"|"emphasize"|"deemphasize"
---@field origin nil|string
---@field sources nil|dap.Source[]
---@field adapterData nil|any

---@class Client
---@field close function
---@field write function

---@class Capabilities
---@field supportsConfigurationDoneRequest boolean|nil
---@field supportsFunctionBreakpoints boolean|nil
---@field supportsConditionalBreakpoints boolean|nil
---@field supportsHitConditionalBreakpoints boolean|nil
---@field supportsEvaluateForHovers boolean|nil
---@field exceptionBreakpointFilters ExceptionBreakpointsFilter[]|nil
---@field supportsStepBack boolean|nil
---@field supportsSetVariable boolean|nil
---@field supportsRestartFrame boolean|nil
---@field supportsGotoTargetsRequest boolean|nil
---@field supportsStepInTargetsRequest boolean|nil
---@field supportsCompletionsRequest boolean|nil
---@field completionTriggerCharacters string[]|nil
---@field supportsModulesRequest boolean|nil
---@field additionalModuleColumns ColumnDescriptor[]|nil
---@field supportedChecksumAlgorithms ChecksumAlgorithm[]|nil
---@field supportsRestartRequest boolean|nil
---@field supportsExceptionOptions boolean|nil
---@field supportsValueFormattingOptions boolean|nil
---@field supportsExceptionInfoRequest boolean|nil
---@field supportTerminateDebuggee boolean|nil
---@field supportSuspendDebuggee boolean|nil
---@field supportsDelayedStackTraceLoading boolean|nil
---@field supportsLoadedSourcesRequest boolean|nil
---@field supportsLogPoints boolean|nil
---@field supportsTerminateThreadsRequest boolean|nil
---@field supportsSetExpression boolean|nil
---@field supportsTerminateRequest boolean|nil
---@field supportsDataBreakpoints boolean|nil
---@field supportsReadMemoryRequest boolean|nil
---@field supportsWriteMemoryRequest boolean|nil
---@field supportsDisassembleRequest boolean|nil
---@field supportsCancelRequest boolean|nil
---@field supportsBreakpointLocationsRequest boolean|nil
---@field supportsClipboardContext boolean|nil
---@field supportsSteppingGranularity boolean|nil
---@field supportsInstructionBreakpoints boolean|nil
---@field supportsExceptionFilterOptions boolean|nil
---@field supportsSingleThreadExecutionRequests boolean|nil


---@class ExceptionBreakpointsFilter
---@field filter string
---@field label string
---@field description string|nil
---@field default boolean|nil
---@field supportsCondition boolean|nil
---@field conditionDescription string|nil

---@class ColumnDescriptor
---@field attributeName string
---@field label string
---@field format string|nil
---@field type nil|"string"|"number"|"number"|"unixTimestampUTC"
---@field width number|nil


---@class ChecksumAlgorithm
---@field algorithm "MD5"|"SHA1"|"SHA256"|"timestamp"
---@field checksum string

---@class dap.StoppedEvent
---@field reason "step"|"breakpoint"|"exception"|"pause"|"entry"|"goto"|"function breakpoint"|"data breakpoint"|"instruction breakpoint"|string;
---@field description nil|string
---@field threadId nil|number
---@field preserveFocusHint nil|boolean
---@field text nil|string
---@field allThreadsStopped nil|boolean
---@field hitBreakpointIds nil|number[]

---@class Session
local Session = {}

local ns_pos = 'dap_pos'
local terminal_buf, terminal_width, terminal_height

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
    return assert(convert_nil(vim.fn.json_decode(payload)), "json_decode must return a value")
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
    handle:close()
    if code ~= 0 then
      utils.notify(string.format('Terminal exited %d running %s %s', code, terminal.command, table.concat(full_args, ' ')), vim.log.levels.ERROR)
    end
  end)
  return handle, pid_or_err
end


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
  local cur_buf = api.nvim_get_current_buf()
  if terminal_buf and api.nvim_buf_is_valid(terminal_buf) then
    api.nvim_buf_set_option(terminal_buf, 'modified', false)
  else
    local terminal_win
    terminal_buf, terminal_win = create_terminal_buf(settings.terminal_win_cmd)
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
    vim.b[terminal_buf]['dap-type'] = self.config.type
    terminal_width = terminal_win and api.nvim_win_get_width(terminal_win) or 80
    terminal_height = terminal_win and api.nvim_win_get_height(terminal_win) or 40
  end
  local terminal_buf_name = '[dap-terminal] ' .. (self.config.name or body.args[1])
  local terminal_name_ok = pcall(api.nvim_buf_set_name, terminal_buf, terminal_buf_name)
  if not terminal_name_ok then
    log.warn(terminal_buf_name ..  ' is not a valid buffer name')
    api.nvim_buf_set_name(terminal_buf, '[dap-terminal] <?>')
  end
  pcall(api.nvim_buf_del_keymap, terminal_buf, "t", "<CR>")
  local ok, path = pcall(api.nvim_buf_get_option, cur_buf, 'path')
  if ok then
    api.nvim_buf_set_option(terminal_buf, 'path', path)
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
    height = terminal_height,
    width = terminal_width,
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
  vim.diagnostic.set(ns, bufnr, {
    {
      bufnr = bufnr,
      lnum = frame.line - 1,
      end_lnum = frame.endLine and (frame.endLine - 1) or nil,
      col = frame.col or 0,
      end_col = frame.endColumn,
      severity = vim.diagnostic.severity.ERROR,
      message = table.concat(msg_parts, '\n'),
      source = 'nvim-dap',
    }
  })
end



local function set_cursor(win, line, column)
  local ok, err = pcall(api.nvim_win_set_cursor, win, { line, column - 1 })
  if ok then
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
      api.nvim_win_set_buf(win, bufnr)
      set_cursor(win, line, column)
    end
    return true
  end

  function switchbuf_fn.useopen()
    for _, win in pairs(api.nvim_tabpage_list_wins(0)) do
      if api.nvim_win_get_buf(win) == bufnr then
        set_cursor(win, line, column)
        return true
      end
    end
    return false
  end

  function switchbuf_fn.usetab()
    local tabs = {0,}
    vim.list_extend(tabs, api.nvim_list_tabpages())
    for _, tabpage in pairs(tabs) do
      for _, win in pairs(api.nvim_tabpage_list_wins(tabpage)) do
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
  session:source(source, function(err, bufnr)
    coroutine.resume(co, err, bufnr)
  end)
  return coroutine.yield()
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
  vim.fn.sign_unplace(ns_pos)
  if preserve_focus_hint or frame.line < 0 then
    return
  end
  local bufnr = frame_to_bufnr(session, frame)
  if not bufnr then
    utils.notify('Source not available, cannot jump to frame', vim.log.levels.INFO)
    return
  end
  vim.fn.bufload(bufnr)
  local switchbuf = defaults(session).switchbuf or vim.g.switchbuf or 'uselast'
  jump_to_location(bufnr, frame.line, frame.column, switchbuf, session.filetype)
  if stopped and stopped.reason == 'exception' then
    session:_show_exception_info(stopped.threadId, bufnr, frame)
  end
end


--- Request a source
-- @param source dap.Source
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
    if signal_err(err, cb) then
      return
    end
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


local function get_top_frame(frames)
  for _, frame in pairs(frames) do
    if frame.source and frame.source.path then
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
  if self.stopped_thread_id and should_jump then
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
    local frames = response.stackFrames
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
      self:_show_exception_info(stopped.threadId, bufnr, current_frame)
    end
  end)()
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
        utils.notify('Error setting exception breakpoints: ' .. utils.fmt_error(err), vim.log.levels.ERROR)
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


local default_reverse_request_handlers = {
  runInTerminal = run_in_terminal
}

local next_session_id = 1

---@return Session
local function new_session(adapter, opts)
  local handlers = {}
  handlers.after = opts.after
  handlers.reverse_requests = vim.tbl_extend(
    'error',
    default_reverse_request_handlers,
    adapter.reverse_request_handlers or {}
  )
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
    filetype = opts.filetype or vim.bo.filetype
  }
  next_session_id = next_session_id + 1
  return setmetatable(state, { __index = Session })
end


local function get_free_port()
  local tcp = uv.new_tcp()
  tcp:bind('127.0.0.1', 0)
  local port = tcp:getsockname().port
  tcp:shutdown()
  tcp:close()
  return port
end


---@param adapter ServerAdapter
local function spawn_server_executable(adapter)
  local cmd = assert(adapter.executable.command, "executable of server adapter must have a `command` property")
  log.debug("Starting debug adapter server executable", adapter.executable)
  if adapter.port == "${port}" then
    local port = get_free_port()
    -- don't mutate original adapter definition
    adapter = vim.deepcopy(adapter)
    adapter.port = port
    if adapter.executable.args then
      local args = assert(adapter.executable.args)
      for idx, arg in pairs(args) do
        args[idx] = arg:gsub('${port}', tostring(port))
      end
    end
  end
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)
  local opts = {
    stdio = {nil, stdout, stderr},
    args = adapter.executable.args or {},
    detached = utils.if_nil(adapter.executable.detached, true),
    cwd = adapter.executable.cwd,
  }
  local handle, pid_or_err = uv.spawn(cmd, opts, function(code)
    stdout:close()
    stderr:close()
    if code ~= 0 then
      utils.notify(cmd .. " exited with code " .. code, vim.log.levels.WARN)
    end
  end)
  if not handle then
    stdout:close()
    stderr:close()
    error(pid_or_err)
  end
  log.debug(
    "Debug adapter server executable started (" .. pid_or_err .. "), listening on " .. adapter.port)

  local read_output = function(stream)
    return function(err, chunk)
      assert(not err, err)
      if chunk then
        vim.schedule(function()
          repl.append('[debug-adapter ' .. stream .. '] ' .. chunk)
        end)
      end
    end
  end
  stderr:read_start(read_output('stderr'))
  stdout:read_start(read_output('stdout'))
  return handle, adapter
end


function Session.connect(_, adapter, opts, on_connect)
  local session = new_session(adapter, opts or {})
  local closed = false
  local client = uv.new_tcp()

  local function close()
    if closed then
      return
    end
    closed = true
    client:shutdown()
    client:close()
    session.threads = {}
    session.message_callbacks = {}
    session.message_requests = {}
  end

  session.client = {
    write = function(line)
      client:write(line)
    end;
    close = close
  }

  if adapter.executable then
    local handle
    handle, adapter = spawn_server_executable(adapter)
    session.client.close = function()
      if handle and not handle:is_closing() then
        handle:close()
        handle = nil
      end
      close()
    end
  end
  log.debug('Connecting to debug adapter', adapter)
  local max_retries = (adapter.options or {}).max_retries or 14

  local host = adapter.host or '127.0.0.1'
  local on_addresses
  on_addresses = function(err, addresses, retry_count)
    if err or #addresses == 0 then
      err = err or ('Could not resolve ' .. host)
      on_connect(err)
      return
    end
    local address = addresses[1]
    client:connect(address.addr, tonumber(adapter.port), function(conn_err)
      if conn_err then
        retry_count = retry_count or 1
        if retry_count < max_retries then
          -- Possible luv bug? A second client:connect gets stuck
          -- Create new handle as workaround
          client:close()
          client = uv.new_tcp()
          local timer = uv.new_timer()
          timer:start(250, 0, function()
            timer:stop()
            timer:close()
            on_addresses(nil, addresses, retry_count + 1)
          end)
        else
          on_connect(conn_err)
        end
        return
      end
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
      on_connect(nil)
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


---@param adapter ExecutableAdapter
---@param opts table|nil
---@return Session
function Session.spawn(_, adapter, opts)
  log.debug('Spawning debug adapter', adapter)
  local session = new_session(adapter, opts or {})

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
      session.threads = {}
      session.message_callbacks = {}
      session.message_requests = {}
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
    detached = utils.if_nil(options.detached, true);
  }
  handle, pid_or_err = uv.spawn(adapter.command, spawn_opts, onexit)
  if not handle then
    onexit()
    if adapter.command == "" then
      error("adapter.command must not be empty. Got: " .. vim.inspect(adapter))
    else
      error('Error running ' .. adapter.command .. ': ' .. pid_or_err)
    end
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


local function clear_running(session, thread_id)
  vim.fn.sign_unplace(ns_pos)
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
  if self.handlers.after then
    self.handlers.after()
    self.handlers.after = nil
  end
  vim.diagnostic.reset(ns)
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
      callback = function(err, result)
        coroutine.resume(co, err, result)
      end
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
  local session = dap().session()
  self:request_with_timeout('disconnect', opts, disconnect_timeout_sec * sec_to_ms, function(err, resp)
    -- If user already started a new session, don't clear it.
    -- If user triggers disconnect multiple times, subsequent calls will timeout and still call the callback
    if session == dap().session() then
      dap().set_session(nil)
    end
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


function Session.event_loadedSource()
end


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

return Session
