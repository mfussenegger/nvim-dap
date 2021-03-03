dap = {} -- luacheck: ignore 111 - to support v:lua.dap... uses


local api = vim.api

local dap_signs = require('dap.signs')
local log = require('dap.log').create_logger('dap.log')
local reloadable = require('dap.reloadable')
local repl = require('dap.repl')
local ui = require('dap.ui')
local utils = require('dap.utils')
local Session = require('dap.session')

local non_empty = utils.non_empty
local ns_breakpoints = require('dap.constants').ns_breakpoints

local set_current_session, get_current_session = reloadable.create_value('CurrentSession')
local set_last_run, get_last_run = reloadable.create_value('LastRun')

local bp_info = reloadable.table('BpInfo')

local M = {}

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
  set_last_run {
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
  local last_run = get_last_run()
  if last_run then
    M.run(last_run.config, last_run.opts)
  else
    print('No configuration available to re-run')
  end
end


function M.step_over()
  local session = get_current_session()
  if not session then return end
  session:_step('next')
end

function M.step_into()
  local session = get_current_session()
  if not session then return end
  session:_step('stepIn')
end

function M.step_out()
  local session = get_current_session()
  if not session then return end
  session:_step('stepOut')
end

function M.reverse_continue()
  local session = get_current_session()
  if not session then return end
  session:_step('reverseContinue')
end

function M.step_back()
  local session = get_current_session()
  if not session then return end
  session:_step('stepBack')
end

function M.pause(thread_id)
  local session = get_current_session()
  if not session then return end
  session:_pause(thread_id)
end

function M.stop()
  local session = get_current_session()
  if not session then return end
  session:close()
  set_current_session(nil)
end

function M.up()
  local session = get_current_session()
  if not session then return end
  session:_frame_delta(1)
end

function M.down()
  local session = get_current_session()
  if not session then return end
  session:_frame_delta(-1)
end

function M.goto_(line)
  local session = get_current_session()
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
  local session = get_current_session()
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
  local bp_signs = dap_signs.get_breakpoint_signs()
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
  local session = get_current_session()

  local bufnr = api.nvim_get_current_buf()
  local lnum, _ = unpack(api.nvim_win_get_cursor(0))
  if not dap_signs.remove_breakpoints(bufnr, lnum) or replace_old then
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
  local session = get_current_session()

  if session then
    session:set_exception_breakpoints(filters, exceptionOptions)
  else
    print('Cannot set exception breakpoints: No active session!')
  end
end


function M.continue()
  local session = get_current_session()

  if not session then
    select_config_and_run()
  else
    session:_step('continue')
  end
end


--- Disconnects an active session
function M.disconnect()
  local session = get_current_session()

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
  local session = get_current_session()

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
  local session = get_current_session()

  if session then
    session:close()
  end
  if not config.request then
    print('config needs the `request` property which must be one of `attach` or `launch`')
    return
  end
  session = set_current_session(Session:connect(host, port, opts))
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
  local session = get_current_session()

  if session then
    session:close()
  end
  session = set_current_session(Session:spawn(adapter, opts))
  session:initialize(config)
  return session
end


function M.set_log_level(level)
  log.set_level(level)
end


function M._vim_exit_handler()
  local session = get_current_session()
  if session then
    session:close()
  end
end
dap._vim_exit_handler = M._vim_exit_handler  -- luacheck: ignore 112


--- Return the current session or nil
function M.session()
  return get_current_session()
end

M._set_current_session = set_current_session


api.nvim_command("autocmd VimLeavePre * lua dap._vim_exit_handler()")
return M
