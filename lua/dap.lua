local api = vim.api
local utils = require('dap.utils')
local M = {}

---@type Session|nil
local session = nil
local last_run = nil

-- lazy import other modules to have a lower startup footprint
local lazy = setmetatable({}, {
  __index = function(_, key)
    return require('dap.' .. key)
  end
})


local function log()
  return require('dap.log').create_logger('dap.log')
end


M.status = function(...)
  return lazy.progress.status(...)
end
M.repl = setmetatable({}, {
  __index = function(_, key)
    return require('dap.repl')[key]
  end
})
M.listeners = {
  before = setmetatable({}, {
    __index = function(tbl, key)
      rawset(tbl, key, {})
      return rawget(tbl, key)
    end
  });
  after = setmetatable({}, {
    __index = function(tbl, key)
      rawset(tbl, key, {})
      return rawget(tbl, key)
    end
  });
}


local function from_fallback(_, key)
  return M.defaults.fallback[key]
end
M.defaults = setmetatable(
  {
    fallback = {
      exception_breakpoints = 'default';
      ---@type "statement"|"line"|"instruction"
      stepping_granularity = 'statement';

      ---@type string|fun(): number bufnr, number|nil win
      terminal_win_cmd = 'belowright new';
      focus_terminal = false;
      auto_continue_if_many_stopped = true;
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

---@class Adapter
---@field type string
---@field id string|nil
---@field options nil|AdapterOptions
---@field enrich_config fun(config: Configuration, on_config: fun(config: Configuration))

---@class AdapterOptions
---@field initialize_timeout_sec nil|number
---@field disconnect_timeout_sec nil|number
---@field source_filetype nil|string

---@class ExecutableAdapter : Adapter
---@field type "executable"
---@field command string
---@field args string[]
---@field options nil|ExecutableOptions

---@class ExecutableOptions : AdapterOptions
---@field env nil|table<string, string>
---@field cwd nil|string
---@field detached nil|boolean

---@class ServerOptions : AdapterOptions
---@field max_retries nil|number

---@class ServerAdapter : Adapter
---@field type "server"
---@field host string|nil
---@field port number
---@field executable nil|ServerAdapterExecutable
---@field options nil|ServerOptions

---@class ServerAdapterExecutable
---@field command string
---@field args nil|string[]
---@field cwd nil|string
---@field detached nil|boolean


--- Adapter definitions. See `:help dap-adapter` for more help
---
--- An example:
---
--- ```
--- require('dap').adapter.debugpy = {
---   {
---       type = "executable"
---       command = "/usr/bin/python",
---       args = {"-m", "debugpy.adapter"},
---   },
--- }
--- ```
---@type table<string, Adapter|fun(callback: fun(adapter: Adapter), config: Configuration)>
M.adapters = {}


---@class Configuration
---@field type string
---@field request "launch"|"attach"
---@field name string

--- Configurations per adapter. See `:help dap-configuration` for more help.
---
--- An example:
---
--- ```
--- require('dap').configurations.python = {
---   {
---       name = "My configuration",
---       type = "debugpy", -- references an entry in dap.adapters
---       request = "launch",
---       -- + Other debug adapter specific configuration options
---   },
--- }
--- ```
---@type table<string, Configuration[]>
M.configurations = {}

local signs = {
  DapBreakpoint = { text = "B", texthl = "", linehl = "", numhl = "" },
  DapBreakpointCondition = { text = "C", texthl = "", linehl = "", numhl = "" },
  DapBreakpointRejected = { text = 'R', texthl = '', linehl = '', numhl = '' },
  DapLogPoint = { text = 'L', texthl = '', linehl = '', numhl = '' },
  DapStopped = { text = '→', texthl = '', linehl = 'debugPC', numhl = '' },
}

local function sign_try_define(name)
  local s = vim.fn.sign_getdefined(name)
  if vim.tbl_isempty(s) then
    local opts = signs[name]
    vim.fn.sign_define(name, opts)
  end
end

for name in pairs(signs) do
  sign_try_define(name)
end

local function convert_to_bazel_binary_name(workspaceFolder, filename)
  local test = false
  local i, _ = string.find(filename, "/main.go")
  if i == nil then
    i, _ = string.find(filename, "/main_test.go")
    if i == nil then
      return filename
    end
    test = true
  end

  local file_without_extension = string.sub(filename, 0, i-1)
  local index_of_last_line_sep = file_without_extension:match'^.*()/'
  local binary = string.sub(file_without_extension, index_of_last_line_sep, string.len(file_without_extension))
  if test then
    return (workspaceFolder .. "/bazel-bin/" .. file_without_extension .. binary .. "_test_" .. binary .. "_test")
  else
    return (workspaceFolder .. "/bazel-bin/" .. file_without_extension .. binary .. "_" .. binary)
  end
end

local function expand_config_variables(option)
  if type(option) == 'function' then
    option = option()
  end
  if type(option) == "thread" then
    assert(coroutine.status(option) == "suspended", "If option is a thread it must be suspended")
    local co = coroutine.running()
    -- Schedule ensures `coroutine.resume` happens _after_ coroutine.yield
    -- This is necessary in case the option coroutine is synchronous and
    -- gives back control immediately
    vim.schedule(function()
      coroutine.resume(option, co)
    end)
    option = coroutine.yield()
  end
  if type(option) == "table" then
    local mt = getmetatable(option)
    local result = {}
    for k, v in pairs(option) do
      result[expand_config_variables(k)] = expand_config_variables(v)
    end
    return setmetatable(result, mt)
  end
  if type(option) ~= "string" then
    return option
  end
  local variables = {
    file = vim.fn.expand("%:p");
    fileBasename = vim.fn.expand("%:t");
    fileBasenameNoExtension = vim.fn.fnamemodify(vim.fn.expand("%:t"), ":r");
    fileDirname = vim.fn.expand("%:p:h");
    fileExtname = vim.fn.expand("%:e");
    relativeFile = vim.fn.expand("%:.");
    relativeFileDirname = vim.fn.fnamemodify(vim.fn.expand("%:.:h"), ":r");
    workspaceFolder = vim.fn.getcwd();
    workspaceFolderBasename = vim.fn.fnamemodify(vim.fn.getcwd(), ":t");
    bazelBinary = convert_to_bazel_binary_name(vim.fn.getcwd(), vim.fn.expand("%:."));
  }
  local ret = option
  for key, val in pairs(variables) do
    ret = ret:gsub('${' .. key .. '}', val)
  end
  return ret
end


local function run_adapter(adapter, configuration, opts)
  local name = configuration.name or '[no name]'
  local options = adapter.options or {}
  opts = vim.tbl_extend('keep', opts, {
    cwd = options.cwd,
    env = options.env
  })
  if adapter.type == 'executable' then
    lazy.progress.report('Running: ' .. name)
    M.launch(adapter, configuration, opts)
  elseif adapter.type == 'server' then
    lazy.progress.report('Running: ' .. name)
    M.attach(adapter, configuration, opts)
  else
    utils.notify(string.format('Invalid adapter type %s, expected `executable` or `server`', adapter.type), vim.log.levels.ERROR)
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
  if #configurations == 0 then
    utils.notify(string.format('No configuration found for `%s`. You need to add configs to `dap.configurations.%s` (See `:h dap-configuration`)', filetype, filetype), vim.log.levels.INFO)
    return
  end
  lazy.ui.pick_if_many(
    configurations,
    "Configuration: ",
    function(i) return i.name end,
    function(configuration)
      if configuration then
        M.run(configuration)
      else
        utils.notify('No configuration selected', vim.log.levels.INFO)
      end
    end
  )
end


--- Start a debug session
---@param config Configuration
---@param opts table|nil
function M.run(config, opts)
  assert(
    type(config) == 'table',
    'dap.run() must be called with a valid configuration, got ' .. vim.inspect(config))
  if session then
    M.terminate(nil, nil, vim.schedule_wrap(function()
      M.run(config, opts)
    end))
    return
  end
  opts = opts or {}
  last_run = {
    config = config,
    opts = opts,
  }
  if opts.before then
    config = opts.before(config)
  end
  local trigger_run = coroutine.wrap(function()
    config = vim.tbl_map(expand_config_variables, config)
    local adapter = M.adapters[config.type]
    if type(adapter) == 'table' then
      lazy.progress.report('Launching debug adapter')
      maybe_enrich_config_and_run(adapter, config, opts)
    elseif type(adapter) == 'function' then
      lazy.progress.report('Launching debug adapter')
      adapter(
        function(resolved_adapter)
          maybe_enrich_config_and_run(resolved_adapter, config, opts)
        end,
        config
      )
    elseif adapter == nil then
      utils.notify(string.format(
        'The selected configuration references adapter `%s`, but dap.adapters.%s is undefined',
        config.type,
        config.type
      ), vim.log.levels.ERROR)
    else
      utils.notify(string.format(
          'Invalid adapter `%s` for config `%s`. Expected a table or function. '
            .. 'Read :help dap-adapter and define a valid adapter.',
          vim.inspect(adapter),
          config.type
        ),
        vim.log.levels.ERROR
      )
    end
  end)
  trigger_run()
end


--- Run the last debug session again
function M.run_last()
  if last_run then
    M.run(last_run.config, last_run.opts)
  else
    utils.notify('No configuration available to re-run', vim.log.levels.INFO)
  end
end

--- Step over the current line
---@param opts table|nil
function M.step_over(opts)
  if not session then return end
  session:_step('next', opts)
end

function M.step_into(opts)
  if not session then return end
  opts = opts or {}
  local askForTargets = opts.askForTargets
  opts.askForTargets = nil
  if not (askForTargets and session.capabilities.supportsStepInTargetsRequest) then
    session:_step('stepIn', opts)
    return
  end

  session:request('stepInTargets', { frameId = session.current_frame.id }, function(err, response)
    if err then
      utils.notify(
        'Error on step_into: ' .. utils.fmt_error(err) .. ' (while requesting stepInTargets)',
        vim.log.levels.ERROR
      )
      return
    end

    lazy.ui.pick_if_many(
      response.targets,
      "Step into which function?",
      function(target) return target.label end,
      function(target)
        if not target or not target.id then
          utils.notify('No target selected. No stepping.', vim.log.levels.INFO)
        else
          opts.targetId = target.id
          session:_step('stepIn', opts)
        end
      end)
  end)
end

function M.step_out(opts)
  if not session then return end
  session:_step('stepOut', opts)
end

function M.step_back(opts)
  if not session then return end

  if session.capabilities.supportsStepBack then
    session:_step('stepBack', opts)
  else
    utils.notify('Debug Adapter does not support stepping backwards.', vim.log.levels.ERROR)
  end
end

function M.reverse_continue(opts)
  if not session then return end
  if session.capabilities.supportsStepBack then
    session:_step('reverseContinue', opts)
  else
    utils.notify('Debug Adapter does not support stepping backwards.', vim.log.levels.ERROR)
  end
end


function M.pause(thread_id)
  if session then
    session:_pause(thread_id)
  end
end


function M.stop()
  utils.notify('dap.stop() is deprecated. Call dap.close() instead', vim.log.levels.WARN)
  M.close()
end


function M.terminate(terminate_opts, disconnect_opts, cb)
  if session then
    local capabilities = session.capabilities or {}
    if capabilities.supportsTerminateRequest then
      capabilities.supportsTerminateRequest = false
      local opts = terminate_opts or vim.empty_dict()
      session:request('terminate', opts, function(err)
        assert(not err, vim.inspect(err))
        vim.notify('Session terminated')
        if cb then
          cb()
        end
      end)
    else
      local opts = disconnect_opts or { terminateDebuggee = true }
      M.disconnect(opts, cb)
    end
  else
    vim.notify('No active session')
    if cb then
      cb()
    end
  end
end


function M.close()
  if session then
    session:close()
    M.set_session(nil)
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
        utils.notify('Error restarting debug adapter: ' .. utils.fmt_error(err0), vim.log.levels.ERROR)
      else
        utils.notify('Restarted debug adapter', vim.log.levels.INFO)
      end
    end)
  else
    utils.notify('Restart not supported', vim.log.levels.ERROR)
  end
end


function M.list_breakpoints(open_quickfix)
  local qf_list = lazy.breakpoints.to_qf_list(lazy.breakpoints.get())
  local current_qflist_title = vim.fn.getqflist({ title = 1 }).title
  local action = ' '
  if current_qflist_title == DAP_QUICKFIX_TITLE then
    action = 'r'
  end
  vim.fn.setqflist({}, action, {
    items = qf_list,
    context = DAP_QUICKFIX_CONTEXT,
    title = DAP_QUICKFIX_TITLE
  })
  if open_quickfix then
    if #qf_list == 0 then
      utils.notify('No breakpoints set!', vim.log.levels.INFO)
    else
      api.nvim_command('copen')
    end
  end
end

function M.set_breakpoint(condition, hit_condition, log_message)
  M.toggle_breakpoint(condition, hit_condition, log_message, true)
end

function M.toggle_breakpoint(condition, hit_condition, log_message, replace_old)
  lazy.breakpoints.toggle({
    condition = condition,
    hit_condition = hit_condition,
    log_message = log_message,
    replace = replace_old
  })
  if session and session.initialized then
    local bufnr = api.nvim_get_current_buf()
    local bps = lazy.breakpoints.get(bufnr)
    session:set_breakpoints(bps)
  end
  if vim.fn.getqflist({context = DAP_QUICKFIX_CONTEXT}).context == DAP_QUICKFIX_CONTEXT then
    M.list_breakpoints(false)
  end
end


function M.clear_breakpoints()
  if session then
    local bps = lazy.breakpoints.get()
    for bufnr, _ in pairs(bps) do
      bps[bufnr] = {}
    end
    lazy.breakpoints.clear()
    session:set_breakpoints(bps)
  else
    lazy.breakpoints.clear()
  end
end


-- setExceptionBreakpoints (https://microsoft.github.io/debug-adapter-protocol/specification#Requests_SetExceptionBreakpoints)
--- filters: string[]
--- exceptionOptions: exceptionOptions?: ExceptionOptions[] (https://microsoft.github.io/debug-adapter-protocol/specification#Types_ExceptionOptions)
function M.set_exception_breakpoints(filters, exceptionOptions)
  if session then
    session:set_exception_breakpoints(filters, exceptionOptions)
  else
    utils.notify('Cannot set exception breakpoints: No active session!', vim.log.levels.INFO)
  end
end


function M.run_to_cursor()
  if not session then
    utils.notify('Cannot use run_to_cursor without active session', vim.log.levels.INFO)
    return
  end
  if not session.stopped_thread_id then
    utils.notify('run_to_cursor can only be used if stopped at a breakpoint', vim.log.levels.INFO)
    return
  end

  local bps_before = lazy.breakpoints.get()
  lazy.breakpoints.clear()
  local cur_bufnr = api.nvim_get_current_buf()
  local lnum = api.nvim_win_get_cursor(0)[1]
  lazy.breakpoints.set({}, cur_bufnr, lnum)

  local temp_bps = lazy.breakpoints.get(cur_bufnr)
  for bufnr, _ in pairs(bps_before) do
    if bufnr ~= cur_bufnr then
      temp_bps[bufnr] = {}
    end
  end

  if bps_before[cur_bufnr] == nil then
    bps_before[cur_bufnr] = {}
  end

  local function restore_breakpoints()
    M.listeners.before.event_stopped['dap.run_to_cursor'] = nil
    M.listeners.before.event_terminated['dap.run_to_cursor'] = nil
    lazy.breakpoints.clear()
    for buf, buf_bps in pairs(bps_before) do
      for _, bp in pairs(buf_bps) do
        local line = bp.line
        local opts = {
          condition = bp.condition,
          log_message = bp.logMessage,
          hit_condition = bp.hitCondition
        }
        lazy.breakpoints.set(opts, buf, line)
      end
    end
    session:set_breakpoints(bps_before, nil)
  end

  M.listeners.before.event_stopped['dap.run_to_cursor'] = restore_breakpoints
  M.listeners.before.event_terminated['dap.run_to_cursor'] = restore_breakpoints
  session:set_breakpoints(temp_bps, function()
    session:_step('continue')
  end)
end


function M.continue()
  if not session then
    select_config_and_run()
  elseif session.stopped_thread_id then
    session:_step('continue')
  else
    local stopped_threads = vim.tbl_filter(function(t) return t.stopped end, session.threads)
    local prompt
    if not session.initialized then
      prompt = "Session still initializing> "
    elseif next(stopped_threads) then
      prompt = "Not focused on any stopped Thread> "
    else
      prompt = "Session active, but not stopped at breakpoint> "
    end
    local choices = {
      {
        label = "Terminate session",
        action = M.terminate
      },
      {
        label = "Pause a thread",
        action = M.pause
      },
      {
        label = "Restart session",
        action = M.restart,
      },
      {
        label = "Disconnect (terminate = true)",
        action = function()
          M.disconnect({ terminateDebuggee = true })
        end
      },
      {
        label = "Disconnect (terminate = false)",
        action = function()
          M.disconnect({ terminateDebuggee = false })
        end,
      },
      {
        label = "Do nothing",
        action = function() end,
      },
    }
    if next(stopped_threads) then
      table.insert(choices, 1, {
        label = "Resume stopped thread",
        action = vim.schedule_wrap(function()
          lazy.ui.pick_if_many(
            stopped_threads,
            'Thread to resume> ',
            function(t) return t.name or t.id end,
            function(choice)
              if choice then
                session.stopped_thread_id = choice.id
                session:_step('continue')
              end
            end
          )
        end),
      })
    end
    lazy.ui.pick_one(choices, prompt, function(x) return x.label end, function(choice)
      if choice then
        choice.action()
      end
    end)
  end
end


--- Disconnects an active session
function M.disconnect(opts, cb)
  if session then
    session:disconnect(opts, cb)
  else
    utils.notify('No active session. Doing nothing.', vim.log.levels.INFO)
    if cb then
      cb()
    end
  end
end


function M.omnifunc(findstart, base)
  vim.notify("dap.omnifunc is deprecated. Use require('dap.repl').omnifunc instead.", vim.log.levels.WARN)
  return lazy.repl.omnifunc(findstart, base)
end


--- Connect to a debug adapter via TCP
---@param adapter ServerAdapter
---@param config Configuration
---@param opts table
---@param bwc_dummy any
function M.attach(adapter, config, opts, bwc_dummy)
  if type(adapter) == 'string' then
    utils.notify(
      'dap.launch signature changed from (host, port, config) to (adapter, config), please adjust',
      vim.log.levels.WARN
    )
    local host = adapter
    local port = config
    config = opts
    opts = bwc_dummy
    adapter = { type = 'server', host = host, port = port, }
  end
  if not config.request then
    utils.notify('Config needs the `request` property which must be one of `attach` or `launch`', vim.log.levels.ERROR)
    return
  end
  assert(adapter.port, 'Adapter used with attach must have a port property')
  session = require('dap.session'):connect(adapter, opts, function(err)
    if err then
      vim.schedule(function()
        utils.notify(
          string.format("Couldn't connect to %s:%s: %s", adapter.host or '127.0.0.1', adapter.port, err),
          vim.log.levels.ERROR
        )
        if session then
          session:close()
          M.set_session(nil)
        end
      end)
    else
      if session then
        session:initialize(config)
      end
    end
  end)
  return session
end


--- Launch an executable debug adapter and initialize a session
---
---@param adapter ExecutableAdapter
---@param config Configuration
---@param opts table
function M.launch(adapter, config, opts)
  local s = require('dap.session'):spawn(adapter, opts)
  session = s
  s:initialize(config)
  return s
end


function M.set_log_level(level)
  log().set_level(level)
end


function M._vim_exit_handler()
  if session then
    M.terminate()
    vim.wait(500, function() return session == nil end)
  end
  M.repl.close()
end


---@return Session|nil
function M.session()
  return session
end


---@param s Session|nil
function M.set_session(s)
  if not s then
    pcall(vim.fn.sign_unplace, 'dap_pos')
  end
  session = s
end


api.nvim_command("autocmd ExitPre * lua require('dap')._vim_exit_handler()")
return M
