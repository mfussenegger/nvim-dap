dap = {} -- luacheck: ignore 111 - to support v:lua.dap... uses


local api = vim.api
local log = require('dap.log').create_logger('dap.log')
local ui = require('dap.ui')
local repl = require('dap.repl')
local utils = require('dap.utils')
local non_empty = utils.non_empty
local index_of = utils.index_of
local M = {}
local ns_breakpoints = 'dap_breakpoints'
local session = nil
local bp_info = {}
local last_run = nil

local Session = require('dap.session')

local ns_pos = require('dap.constants').ns_pos

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


local function from_fallback(_, key)
  return M.defaults.fallback[key]
end
M.defaults = setmetatable(
  {
    fallback = {
      exception_breakpoints = 'default';
    },
  },
  {
    __index = function(tbl, key)
      tbl[key] = {} -- call __newindex to add metatable to child
      return rawget(tbl, key)
    end,
    __newindex = function(tbl, key)
      rawset(tbl, key, setmetatable({}, {
        __index = from_fallback
      }))
    end
  }
)


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
  assert(
    vim.tbl_islist(configurations),
    string.format(
      '`dap.configurations.%s` must be a list of configurations, got %s',
      filetype,
      vim.inspect(configurations)
    )
  )
  if #configurations == 1 then
    M.run(configurations[1])
    return
  end
  if #configurations == 0 then
    print('No configuration found for ' .. filetype)
    return
  end
  ui.pick_one(
    configurations,
    "Configuration: ",
    function(i) return i.name end,
    function(configuration)
      if configuration then
        M.run(configuration)
      else
        print('No configuration selected')
      end
    end
  )
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
  config = vim.tbl_map(expand_config_variables, config)
  local adapter = M.adapters[config.type]
  if type(adapter) == 'table' then
    maybe_enrich_config_and_run(adapter, config, opts)
  elseif type(adapter) == 'function' then
    adapter(
      function(resolved_adapter)
        maybe_enrich_config_and_run(resolved_adapter, config, opts)
      end,
      config
    )
  else
    print('Invalid adapter: ', vim.inspect(adapter))
  end
end


function M.run_last()
  if last_run then
    M.run(last_run.config, last_run.opts)
  else
    print('No configuration available to re-run')
  end
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
    if non_empty(bp_info.condition) and not self.capabilities.supportsConditionalBreakpoints then
      print("Debug adapter doesn't support breakpoints with conditions")
    end
    if non_empty(bp_info.hitCondition) and not self.capabilities.supportsHitConditionalBreakpoints then
      print("Debug adapter doesn't support breakpoints with hit conditions")
    end
    if non_empty(bp_info.logMessage) and not self.capabilities.supportsLogPoints then
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

function M.pause(thread_id)
  if not session then return end
  session:_pause(thread_id)
end

function M.stop()
  if not session then return end
  session:close()
  session = nil
end

function M.up()
  if not session then return end
  session:_frame_delta(1)
end

function M.down()
  if not session then return end
  session:_frame_delta(-1)
end

function M.goto_(line)
  if not session then return end
  local source, col
  if not line then
    line, col = unpack(api.nvim_win_get_cursor(0))
    col = col + 1
    source = { path = vim.uri_from_bufnr(0) }
  end
  session:_goto(line, source, col)
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
            non_empty(logMessage) and "Log message: "..logMessage,
            non_empty(condition) and "Condition: "..condition,
            non_empty(hitCondition) and "Hit condition: "..hitCondition,
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
      non_empty(log_message) and 'DapLogPoint' or 'DapBreakpoint',
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

  table.sort(candidates, function(a, b) return (a.sortText or a.label) < (b.sortText or b.label) end)
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


function M.omnifunc(findstart, base)
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
    col = col + 1 - offset;
    line_to_cursor = line_to_cursor;
    text_match = text_match + offset;
    prefix = prefix;
  })

  session:request('completions', {
    frameId = (session.current_frame or {}).id;
    text = line_to_cursor;
    column = col + 1 - offset;
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
dap.omnifunc = M.omnifunc  -- luacheck: ignore 112


--- Attach to an existing debug-adapter running on host, port
---  and then initialize it with config
---
---@param host string: Hostname
---@param port number: The port number to connect to
---@param config table: How the debug adapter should connect / launch the debuggee
---    - request: string     -- attach or launch
---    ...                 -- debug adapter specific options
---@param opts table: ?
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


function M._vim_exit_handler()
  if session then
    session:close()
  end
end
dap._vim_exit_handler = M._vim_exit_handler  -- luacheck: ignore 112


--- Return the current session or nil
function M.session()
  return session
end


api.nvim_command("autocmd VimLeavePre * lua dap._vim_exit_handler()")
return M
