local api = vim.api
local M = {}

---@diagnostic disable-next-line: deprecated
local islist = vim.islist or vim.tbl_islist

---@type table<number, dap.Session>
local sessions = {}

---@type dap.Session|nil
local session = nil
local last_run = nil

---@type dap.log.Log?
local _log = nil


-- lazy import other modules to have a lower startup footprint
local lazy = setmetatable({
  async = nil, --- @module "dap.async"
  utils = nil, --- @module "dap.utils"
  progress = nil, --- @module "dap.progress"
  ui = nil, --- @module "dap.ui"
  breakpoints = nil, --- @module "dap.breakpoints"
  }, {
  __index = function(_, key)
    return require('dap.' .. key)
  end
})


---@return dap.log.Log
local function log()
  if not _log then
    _log = require('dap.log').create_logger('dap.log')
  end
  return _log
end

local function notify(...)
  lazy.utils.notify(...)
end

--- Sentinel value; signals an operation should be aborted.
---@class dap.Abort
M.ABORT = {}

M.status = function()
  return lazy.progress.status()
end

--- @module "dap.repl"
M.repl = setmetatable({}, {
  __index = function(_, key)
    return require('dap.repl')[key]
  end
})

---@alias dap.RequestListener<T, U> fun(session: dap.Session, err: dap.ErrorResponse?, response: T, args: U, seq: number):boolean?

---@alias dap.EventListener<T> fun(session: dap.Session, body: T):boolean?

---@class dap.listeners
---@field event_breakpoint table<string, dap.EventListener<dap.BreakpointEvent>>
---@field event_capabilities table<string, dap.EventListener<any>>
---@field event_continued table<string, dap.EventListener<dap.ContinuedEvent>>
---@field event_exited table<string, dap.EventListener<any>>
---@field event_initialized table<string, dap.EventListener<dap.InitializedEvent>>
---@field event_invalidated table<string, dap.EventListener<any>>
---@field event_loadedSource table<string, dap.EventListener<any>>
---@field event_memory table<string, dap.EventListener<any>>
---@field event_module table<string, dap.EventListener<any>>
---@field event_output table<string, dap.EventListener<dap.OutputEvent>>
---@field event_process table<string, dap.EventListener<any>>
---@field event_progressEnd table<string, dap.EventListener<dap.ProgressEndEvent>>
---@field event_progressStart table<string, dap.EventListener<dap.ProgressStartEvent>>
---@field event_progressUpdate table<string, dap.EventListener<dap.ProgressUpdateEvent>>
---@field event_stopped table<string, dap.EventListener<dap.StoppedEvent>>
---@field event_terminated table<string, dap.EventListener<dap.TerminatedEvent>>
---@field event_thread table<string, dap.EventListener<dap.ThreadEvent>>
---@field attach table<string, dap.RequestListener>
---@field breakpointLocations table<string, dap.RequestListener>
---@field completions table<string, dap.RequestListener<dap.CompletionsResponse, dap.CompletionsArguments>>
---@field configurationDone table<string, dap.RequestListener>
---@field continue table<string, dap.RequestListener>
---@field dataBreakpointInfo table<string, dap.RequestListener>
---@field disassemble table<string, dap.RequestListener>
---@field disconnect table<string, dap.RequestListener<any, dap.DisconnectArguments>>
---@field evaluate table<string, dap.RequestListener<dap.EvaluateResponse, dap.EvaluateArguments>>
---@field exceptionInfo table<string, dap.RequestListener>
---@field goto table<string, dap.RequestListener>
---@field gotoTargets table<string, dap.RequestListener>
---@field initialize table<string, dap.RequestListener<dap.Capabilities?, dap.InitializeRequestArguments>>
---@field launch table<string, dap.RequestListener>
---@field loadedSources table<string, dap.RequestListener>
---@field modules table<string, dap.RequestListener>
---@field next table<string, dap.RequestListener>
---@field pause table<string, dap.RequestListener>
---@field readMemory table<string, dap.RequestListener>
---@field restart table<string, dap.RequestListener>
---@field restartFrame table<string, dap.RequestListener>
---@field reverseContinue table<string, dap.RequestListener>
---@field scopes table<string, dap.RequestListener>
---@field setBreakpoints table<string, dap.RequestListener>
---@field setDataBreakpoints table<string, dap.RequestListener>
---@field setExceptionBreakpoints table<string, dap.RequestListener>
---@field setExpression table<string, dap.RequestListener>
---@field setFunctionBreakpoints table<string, dap.RequestListener>
---@field setInstructionBreakpoints table<string, dap.RequestListener>
---@field setVariable table<string, dap.RequestListener>
---@field source table<string, dap.RequestListener>
---@field stackTrace table<string, dap.RequestListener>
---@field stepBack table<string, dap.RequestListener>
---@field stepIn table<string, dap.RequestListener>
---@field stepInTargets table<string, dap.RequestListener>
---@field stepOut table<string, dap.RequestListener>
---@field terminate table<string, dap.RequestListener>
---@field terminateThreads table<string, dap.RequestListener>
---@field threads table<string, dap.RequestListener>
---@field variables table<string, dap.RequestListener<dap.VariableResponse, dap.VariablesArguments>>
---@field writeMemory table<string, dap.RequestListener>


M.listeners = {
  ---@type dap.listeners
  before = setmetatable({}, {
    __index = function(tbl, key)
      rawset(tbl, key, {})
      return rawget(tbl, key)
    end
  }),
  ---@type dap.listeners
  after = setmetatable({}, {
    __index = function(tbl, key)
      rawset(tbl, key, {})
      return rawget(tbl, key)
    end
  }),

  ---@type table<string, fun(config: dap.Configuration):dap.Configuration>
  on_config = {}
}


M.listeners.after.event_stopped['dap.sessions'] = function(s)
  local lsession = session
  if not lsession or not lsession.stopped_thread_id then
    M.set_session(s)
  end
end


local function from_fallback(_, key)
  return M.defaults.fallback[key]
end
M.defaults = setmetatable(
  {
    fallback = {
      exception_breakpoints = 'default',
      ---@type "statement"|"line"|"instruction"
      stepping_granularity = 'statement',

      ---@type string|fun(config: dap.Configuration):(integer, integer?)
      terminal_win_cmd = 'belowright new',
      focus_terminal = false,
      auto_continue_if_many_stopped = true,

      ---@type string|nil
      switchbuf = nil,

      ---@type nil|fun(session: dap.Session, output: dap.OutputEvent)
      on_output = nil,
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

---@class dap.Adapter
---@field type string
---@field id string|nil
---@field options nil|dap.Adapter.options
---@field enrich_config? fun(config: dap.Configuration, on_config: fun(config: dap.Configuration))
---@field reverse_request_handlers? table<string, fun(session: dap.Session, request: dap.Request)>

---@class dap.Adapter.options
---@field initialize_timeout_sec nil|number
---@field disconnect_timeout_sec nil|number
---@field source_filetype nil|string

---@class dap.ExecutableAdapter : dap.Adapter
---@field type "executable"
---@field command string
---@field args string[]
---@field options nil|dap.ExecutableAdapter.options

---@class dap.ExecutableAdapter.options : dap.Adapter.options
---@field env nil|table<string, string>
---@field cwd nil|string
---@field detached nil|boolean

---@class ServerOptions : dap.Adapter.options
---@field max_retries nil|number

---@class dap.ServerAdapter : dap.Adapter
---@field type "server"
---@field host string|nil
---@field port integer
---@field executable nil|dap.ServerAdapterExecutable
---@field options nil|ServerOptions


---@class dap.PipeAdapter.options
---@field timeout? integer max amount of time in ms to wait between spawning the executable and connecting. This gives the executable time to create the pipe. Defaults to 5000

---@class dap.PipeAdapter : dap.Adapter
---@field type "pipe"
---@field pipe string absolute path to the pipe or ${pipe} to use random tmp path
---@field executable? dap.ServerAdapterExecutable
---@field options? dap.PipeAdapter.options

---@class dap.ServerAdapterExecutable
---@field command string
---@field args nil|string[]
---@field cwd nil|string
---@field detached nil|boolean


---@alias dap.AdapterFactory fun(callback: fun(adapter: dap.Adapter), config: dap.Configuration, parent?: dap.Session)

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
---@type table<string, dap.Adapter|dap.AdapterFactory>
M.adapters = {}


---@class dap.Configuration
---@field type string
---@field request "launch"|"attach"
---@field name string
---@field [string] any


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
---@type table<string, dap.Configuration[]>
M.configurations = {}

local providers = {
  ---@type table<string, fun(bufnr: integer): dap.Configuration[]>
  configs = {},
}
do
  local providers_mt = {
    __newindex = function()
      error("Cannot add item to dap.providers")
    end,
  }
  M.providers = setmetatable(providers, providers_mt)
end


providers.configs["dap.global"] = function(bufnr)
  local filetype = vim.b["dap-srcft"] or vim.bo[bufnr].filetype
  local configurations = M.configurations[filetype] or {}
  assert(
    islist(configurations),
    string.format(
      '`dap.configurations.%s` must be a list of configurations, got %s',
      filetype,
      vim.inspect(configurations)
    )
  )
  return configurations
end

providers.configs["dap.launch.json"] = function()
  local ok, configs = pcall(require("dap.ext.vscode").getconfigs)
  if not ok then
    local msg = "Can't get configurations from launch.json:\n%s" .. configs
    vim.notify_once(msg, vim.log.levels.WARN, {title = "DAP"})
    return {}
  end
  return configs
end

do
  local function eval_option(option)
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
    return option
  end

  local var_placeholders_once = {
    ['${command:pickProcess}'] = lazy.utils.pick_process,
    ['${command:pickFile}'] = lazy.utils.pick_file,
  }

  local var_placeholders = {
    ['${file}'] = function(_)
      return vim.fn.expand("%:p")
    end,
    ['${fileBasename}'] = function(_)
      return vim.fn.expand("%:t")
    end,
    ['${fileBasenameNoExtension}'] = function(_)
      return vim.fn.fnamemodify(vim.fn.expand("%:t"), ":r")
    end,
    ['${fileDirname}'] = function(_)
      return vim.fn.expand("%:p:h")
    end,
    ['${fileExtname}'] = function(_)
      return vim.fn.expand("%:e")
    end,
    ['${relativeFile}'] = function(_)
      return vim.fn.expand("%:.")
    end,
    ['${relativeFileDirname}'] = function(_)
      return vim.fn.fnamemodify(vim.fn.expand("%:.:h"), ":r")
    end,
    ['${workspaceFolder}'] = function(_)
      return vim.fn.getcwd()
    end,
    ['${workspaceFolderBasename}'] = function(_)
      return vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
    end,
    ['${env:([%w_]+)}'] = function(match)
      return os.getenv(match) or ''
    end,
  }


  local function expand_config_variables(option)
    option = eval_option(option)
    if option == M.ABORT then
      return option
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
    local ret = option
    for key, fn in pairs(var_placeholders) do
      ret = ret:gsub(key, fn)
    end
    for key, fn in pairs(var_placeholders_once) do
      if ret:find(key) then
        local val = eval_option(fn)
        ret = ret:gsub(key, val)
      end
    end
    return ret
  end

  M.listeners.on_config["dap.expand_variable"] = function(config)
    return vim.tbl_map(expand_config_variables, config)
  end
end


local signs = {
  DapBreakpoint = { text = "B", texthl = "SignColumn", linehl = "", numhl = "" },
  DapBreakpointCondition = { text = "C", texthl = "SignColumn", linehl = "", numhl = "" },
  DapBreakpointRejected = { text = 'R', texthl = "SignColumn", linehl = '', numhl = '' },
  DapLogPoint = { text = 'L', texthl = "SignColumn", linehl = '', numhl = '' },
  DapStopped = { text = '→', texthl = "SignColumn", linehl = 'debugPC', numhl = '' },
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


---@param lsession dap.Session
local function add_reset_session_hook(lsession)
  lsession.on_close['dap.session'] = function(s)
    assert(s.id == lsession.id, "on_close must not be called with a foreign session")
    lazy.progress.report('Closed session: ' .. tostring(s.id))
    sessions[s.id] = nil
    M.set_session(nil)
  end
end

local adapter_types = {
  executable = true,
  server = true,
  pipe = true
}

---@param adapter dap.Adapter
---@param config dap.Configuration
---@param opts table
local function run_adapter(adapter, config, opts)
  local name = config.name or '[no name]'
  local valid_type = adapter_types[adapter.type]
  if not valid_type then
    local msg = string.format('Invalid adapter type %s, expected `executable`, `server` or `pipe`', adapter.type)
    notify(msg, vim.log.levels.ERROR)
    return
  end
  lazy.progress.report('Running: ' .. name)
  local lsession
  if adapter.type == 'executable' then
    ---@cast adapter dap.ExecutableAdapter
    local options = adapter.options or {}
    opts = vim.tbl_extend('keep', opts, {
      cwd = options.cwd,
      env = options.env
    })
    lsession = M.launch(adapter, config, opts)
  elseif adapter.type == 'server' then
    ---@cast adapter dap.ServerAdapter
    lsession = M.attach(adapter, config, opts)
  elseif adapter.type == "pipe" then
    ---@cast adapter dap.PipeAdapter
    lsession = require("dap.session").pipe(adapter, config, opts, function(err)
      if not err then
        lsession:initialize(config)
      end
    end)
  end
  if lsession then
    add_reset_session_hook(lsession)
    M.set_session(lsession)
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


local function select_config_and_run(opts)
  local bufnr = api.nvim_get_current_buf()
  local filetype = vim.bo[bufnr].filetype
  lazy.async.run(function()
    local all_configs = {}
    local provider_keys = vim.tbl_keys(providers.configs)
    table.sort(provider_keys)
    for _, provider in ipairs(provider_keys) do
      local config_provider = providers.configs[provider]
      local configs = config_provider(bufnr)
      if islist(configs) then
        vim.list_extend(all_configs, configs)
      else
        local msg = "Configuration provider %s must return a list of configurations. Got: %s"
        notify(msg:format(provider, vim.inspect(configs)), vim.log.levels.WARN)
      end
    end

    if #all_configs == 0 then
      local msg = 'No configuration found for `%s`. You need to add configs to `dap.configurations.%s` (See `:h dap-configuration`)'
      notify(string.format(msg, filetype, filetype), vim.log.levels.INFO)
      return
    end

    opts = opts or {}
    opts.filetype = opts.filetype or filetype
    lazy.ui.pick_if_many(
      all_configs,
      "Configuration: ",
      function(i) return i.name end,
      function(configuration)
        if configuration then
          M.run(configuration, opts)
        else
          notify('No configuration selected', vim.log.levels.INFO)
        end
      end
    )
  end)
end


--- Get the first stopped session.
--- If no session is stopped, it returns the active session or next in sessions.
---@return dap.Session|nil
local function first_stopped_session()
  if session and session.stopped_thread_id then
    return session
  end
  for _, s in pairs(sessions) do
    if s.stopped_thread_id then
      return s
    end
  end
  if session then
    return session
  end
  local _, s = next(sessions)
  return s
end


---@param config dap.Configuration
---@result dap.Configuration
local function prepare_config(config)
  local co, is_main = coroutine.running()
  assert(co and not is_main, "prepare_config must be running in coroutine")
  local mt = getmetatable(config)
  if mt and type(mt.__call) == "function" then
    config = config()
    assert(config and type(config) == "table", "config metatable __call must return a config table")
  end
  for _, on_config in pairs(M.listeners.on_config) do
    config = on_config(config)
  end
  return config
end


---@class dap.run.opts
---@field new? boolean force new session
---@field before? fun(config: dap.Configuration): dap.Configuration pre-process config


--- Start a debug session
---@param config dap.Configuration
---@param opts dap.run.opts?
function M.run(config, opts)
  assert(
    type(config) == 'table',
    'dap.run() must be called with a valid configuration, got ' .. vim.inspect(config))

  opts = opts or {}
  if session and (opts.new == false or (opts.new == nil and session.config.name == config.name)) then
    M.restart(config, opts)
    return
  end
  opts.filetype = opts.filetype or vim.bo.filetype
  opts.new = nil
  last_run = {
    config = config,
    opts = opts,
  }
  if opts.before then
    config = opts.before(config)
  end
  local trigger_run = function()
    config = prepare_config(config)
    for _, val in pairs(config) do
      if val == M.ABORT then
        notify("Run aborted", vim.log.levels.INFO)
        return
      end
    end
    local adapter = M.adapters[config.type]
    if type(adapter) == 'table' then
      lazy.progress.report('Starting adapter ' .. config.type)
      maybe_enrich_config_and_run(adapter, config, opts)
    elseif type(adapter) == 'function' then
      lazy.progress.report('Starting adapter ' .. config.type)
      adapter(
        function(resolved_adapter)
          maybe_enrich_config_and_run(resolved_adapter, config, opts)
        end,
        config
      )
    elseif adapter == nil then
      notify(string.format(
        'Config references missing adapter `%s`. Available are: %s',
        config.type,
        table.concat(vim.tbl_keys(M.adapters), ", ")
      ), vim.log.levels.ERROR)
    else
      notify(string.format(
          'Invalid adapter `%s` for config `%s`. Expected a table or function. '
            .. 'Read :help dap-adapter and define a valid adapter.',
          vim.inspect(adapter),
          config.type
        ),
        vim.log.levels.ERROR
      )
    end
  end
  lazy.async.run(trigger_run)
end


--- Run the last debug session again
function M.run_last()
  if last_run then
    M.run(last_run.config, last_run.opts)
  else
    notify('No configuration available to re-run', vim.log.levels.INFO)
  end
end

--- Step over the current line
---@param opts table|nil
function M.step_over(opts)
  session = first_stopped_session()
  if not session then
    return
  end
  session:_step('next', opts)
end


function M.focus_frame()
  if session then
    if session.current_frame then
      session:_frame_set(session.current_frame)
    else
      local w = require('dap.ui.widgets')
      w.centered_float(w.threads).open()
    end
  else
    notify('No active session', vim.log.levels.INFO)
  end
end


function M.restart_frame()
  if session then
    session:restart_frame()
  else
    notify('No active session', vim.log.levels.INFO)
  end
end


---@param opts? {askForTargets?: boolean, steppingGranularity?: dap.SteppingGranularity}
function M.step_into(opts)
  session = first_stopped_session()
  if not session then
    return
  end
  ---@type {[any]: any}
  opts = opts or {}
  local askForTargets = opts.askForTargets
  opts.askForTargets = nil
  if not (askForTargets and session.capabilities.supportsStepInTargetsRequest) then
    session:_step('stepIn', opts)
    return
  end

  session:request('stepInTargets', { frameId = session.current_frame.id }, function(err, response)
    if err then
      notify(
        'Error on step_into: ' .. tostring(err) .. ' (while requesting stepInTargets)',
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
          notify('No target selected. No stepping.', vim.log.levels.INFO)
        else
          opts.targetId = target.id
          session:_step('stepIn', opts)
        end
      end)
  end)
end

function M.step_out(opts)
  session = first_stopped_session()
  if not session then
    return
  end
  session:_step('stepOut', opts)
end

function M.step_back(opts)
  session = first_stopped_session()
  if not session then
    return
  end
  if session.capabilities.supportsStepBack then
    session:_step('stepBack', opts)
  else
    notify('Debug Adapter does not support stepping backwards.', vim.log.levels.ERROR)
  end
end

function M.reverse_continue(opts)
  if not session then return end
  if session.capabilities.supportsStepBack then
    session:_step('reverseContinue', opts)
  else
    notify('Debug Adapter does not support stepping backwards.', vim.log.levels.ERROR)
  end
end


function M.pause(thread_id)
  if session then
    session:_pause(thread_id)
  end
end


function M.stop()
  notify('dap.stop() is deprecated. Call dap.close() instead', vim.log.levels.WARN)
  M.close()
end


---@param lsession dap.Session?
---@param opts dap.terminate.Opts?
local function terminate(lsession, opts)
  opts = opts or {}
  local on_done = opts.on_done or function() end
  if not lsession then
    notify('No active session')
    on_done()
    return
  end

  if lsession.closed then
    log():warn('User called terminate on already closed session that is still in use')
    sessions[lsession.id] = nil
    M.set_session(nil)
    on_done()
    return
  end
  local capabilities = lsession.capabilities or {}
  if capabilities.supportsTerminateRequest then
    capabilities.supportsTerminateRequest = false
    local args = opts.terminate_args or vim.empty_dict()
    local timeout_sec = (lsession.adapter.options or {}).disconnect_timeout_sec or 3
    local timeout_ms = timeout_sec * 1000
    lsession:request_with_timeout('terminate', args, timeout_ms, function(err)
      if err then
        log():warn(tostring(err))
      end
      if not lsession.closed then
        lsession:close()
      end
      notify('Session terminated')
      on_done()
    end)
  else
    local args = opts.disconnect_args or { terminateDebuggee = true }
    lsession:disconnect(args, on_done)
  end
end

---@class dap.terminate.Opts
---@field terminate_args dap.TerminateArguments?
---@field disconnect_args dap.DisconnectArguments?
---@field on_done function?
---@field hierarchy boolean? terminate full hierarchy. Defaults to false
---@field all boolean? terminate all root sessions. Can be combined with hierarchy. Defaults to false


---@param opts dap.terminate.Opts?
function M.terminate(opts, disconnect_opts, cb)
  opts = opts or {}
  -- old signature was:
  --- - terminate_opts dap.TerminateArguments?
  --- - disconnect_opts dap.DisconnectArguments?
  --- - cb fun()?
  ---@diagnostic disable-next-line: undefined-field
  if opts.restart ~= nil or disconnect_opts ~= nil or cb ~= nil then
    opts = {
      ---@diagnostic disable-next-line: assign-type-mismatch
      terminate_args = opts,
      disconnect_args = disconnect_opts,
      on_done = cb,
      hierarchy = false,
      all = false,
    }
  end

  local hierarchy = lazy.utils.if_nil(opts.hierarchy, false)
  local all = lazy.utils.if_nil(opts.all, false)

  ---@param s dap.Session
  local function rec_terminate(s)
    terminate(s, opts)
    if hierarchy then
      for _, child in pairs(s.children) do
        rec_terminate(child)
      end
    end
  end

  if all then
    for _, s in pairs(sessions) do
      rec_terminate(s)
    end
  else
    local lsession = session
    if not lsession then
      local _, s = next(sessions)
      if s then
        log():info("Terminate called without active session, switched to", s.id)
      end
      lsession = s
    end
    if not lsession then
      return
    end
    if hierarchy then
      while lsession.parent ~= nil do
        lsession = lsession.parent
        assert(lsession)
      end
    end
    rec_terminate(lsession)
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


---@param config dap.Configuration?
---@param opts? dap.run.opts
function M.restart(config, opts)
  local lsession = session
  if not lsession then
    notify('No active session', vim.log.levels.INFO)
    return
  end
  config = config or lsession.config
  if lsession.capabilities.supportsRestartRequest then
    lazy.async.run(function()
      config = prepare_config(config)
      lsession:request('restart', config, function(err0, _)
        if err0 then
          notify('Error restarting debug adapter: ' .. tostring(err0), vim.log.levels.ERROR)
        else
          notify('Restarted debug adapter', vim.log.levels.INFO)
        end
      end)
    end)
  else
    local terminate_opts = {
      on_done = vim.schedule_wrap(function()
        local nopts = opts and vim.deepcopy(opts) or {}
        nopts.new = true
        M.run(config, nopts)
      end)
    }
    terminate(lsession, terminate_opts)
  end
end


---@param openqf boolean?
function M.list_breakpoints(openqf)
  local qf_list = lazy.breakpoints.to_qf_list(lazy.breakpoints.get())
  local current_qflist_title = vim.fn.getqflist({ title = 1 }).title
  local action = ' '
  if current_qflist_title == DAP_QUICKFIX_TITLE then
    action = 'r'
  end
  vim.fn.setqflist({}, action, {
    items = qf_list,
    context = { DAP_QUICKFIX_CONTEXT },
    title = DAP_QUICKFIX_TITLE
  })
  if openqf then
    if #qf_list == 0 then
      notify('No breakpoints set!', vim.log.levels.INFO)
    else
      api.nvim_command('copen')
    end
  end
end

---@param condition string?
---@param hit_condition string?
---@param log_message string?
function M.set_breakpoint(condition, hit_condition, log_message)
  M.toggle_breakpoint(condition, hit_condition, log_message, true)
end


---@param lsessions table<integer, dap.Session>
---@param fn fun(lsession: dap.Session)
local function broadcast(lsessions, fn)
  for _, lsession in pairs(lsessions) do
    fn(lsession)
    broadcast(lsession.children, fn)
  end
end


---@param condition string?
---@param hit_condition string?
---@param log_message string?
---@param replace_old boolean?
function M.toggle_breakpoint(condition, hit_condition, log_message, replace_old)
  assert(
    not condition or type(condition) == "string",
    "breakpoint condition must be a string. Got: " .. vim.inspect(condition)
  )
  assert(
    not hit_condition or type(hit_condition) == "string",
    "breakpoint hit-condition must be a string. Got: " .. vim.inspect(hit_condition)
  )
  assert(
    not log_message or type(log_message) == "string",
    "breakpoint log-message must be a string. Got: " .. vim.inspect(log_message)
  )
  lazy.breakpoints.toggle({
    condition = condition,
    hit_condition = hit_condition,
    log_message = log_message,
    replace = replace_old
  })
  local bufnr = api.nvim_get_current_buf()
  local bps = lazy.breakpoints.get(bufnr)
  broadcast(sessions, function(s)
    s:set_breakpoints(bps)
  end)
  if vim.fn.getqflist({context = DAP_QUICKFIX_CONTEXT}).context == DAP_QUICKFIX_CONTEXT then
    M.list_breakpoints(false)
  end
end


function M.clear_breakpoints()
  local bps = lazy.breakpoints.get()
  for bufnr, _ in pairs(bps) do
    bps[bufnr] = {}
  end
  lazy.breakpoints.clear()
  broadcast(sessions, function(lsession)
    lsession:set_breakpoints(bps)
  end)
end


-- setExceptionBreakpoints (https://microsoft.github.io/debug-adapter-protocol/specification#Requests_SetExceptionBreakpoints)
--- filters: string[]
--- exceptionOptions: exceptionOptions?: ExceptionOptions[] (https://microsoft.github.io/debug-adapter-protocol/specification#Types_ExceptionOptions)
function M.set_exception_breakpoints(filters, exceptionOptions)
  if session then
    session:set_exception_breakpoints(filters, exceptionOptions)
  else
    notify('Cannot set exception breakpoints: No active session!', vim.log.levels.INFO)
  end
end


function M.run_to_cursor()
  local lsession = session
  if not lsession then
    notify('Cannot use run_to_cursor without active session', vim.log.levels.INFO)
    return
  end
  if not lsession.stopped_thread_id then
    notify('run_to_cursor can only be used if stopped at a breakpoint', vim.log.levels.INFO)
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
    lsession:set_breakpoints(bps_before, nil)
  end

  M.listeners.before.event_stopped['dap.run_to_cursor'] = restore_breakpoints
  M.listeners.before.event_terminated['dap.run_to_cursor'] = restore_breakpoints
  lsession:set_breakpoints(temp_bps, function()
    lsession:_step('continue')
  end)
end


---@param opts? {new?: boolean}
function M.continue(opts)
  if not session then
    session = first_stopped_session()
  end

  opts = opts or {}
  if not session or opts.new then
    select_config_and_run(opts)
  elseif session.stopped_thread_id then
    session:_step('continue')
  else
    local other_stopped_session = first_stopped_session()
    if other_stopped_session and other_stopped_session.stopped_thread_id then
      other_stopped_session:_step('continue')
      return
    end
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
        label = "Start additional session",
        action = function()
          M.continue({ new = true })
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
    notify('No active session. Doing nothing.', vim.log.levels.INFO)
    if cb then
      cb()
    end
  end
end


---@private
--- Connect to a debug adapter via TCP
---@param adapter dap.ServerAdapter
---@param config dap.Configuration
---@param opts table
function M.attach(adapter, config, opts)
  if not config.request then
    notify('Config needs the `request` property which must be one of `attach` or `launch`', vim.log.levels.ERROR)
    return
  end
  assert(adapter.port, 'Adapter used with attach must have a port property')
  local s
  s = require('dap.session').connect(adapter, config, opts, function(err)
    if err then
      notify(
        string.format("Couldn't connect to %s:%s: %s", adapter.host or '127.0.0.1', adapter.port, err),
        vim.log.levels.ERROR
      )
    else
      if s then
        s:initialize(config)
      end
    end
  end)
  return s
end


---@private
--- Launch an executable debug adapter and initialize a session
---
---@param adapter dap.ExecutableAdapter
---@param config dap.Configuration
---@param opts table
function M.launch(adapter, config, opts)
  local s = require('dap.session').spawn(adapter, config, opts)
  if not s then
    return
  end
  s:initialize(config)
  return s
end


function M.set_log_level(level)
  log():set_level(level)
end


--- Currently focused session
---@return dap.Session|nil
function M.session()
  return session
end


---@return table<number, dap.Session>
function M.sessions()
  return sessions
end


---@param new_session dap.Session|nil
function M.set_session(new_session)
  if new_session then
    if new_session.parent == nil then
      sessions[new_session.id] = new_session
    end
    session = new_session
  else
    local _, lsession = next(sessions)
    local msg = lsession and ("Running: " .. lsession.config.name) or ""
    lazy.progress.report(msg)
    session = lsession
  end
end


function M._tagfunc(_, flags, _)
  local lsession = session
  if not lsession then
    return vim.NIL
  end
  if not flags:match("c") then
    return vim.NIL
  end
  local ui = require("dap.ui")
  local buf = api.nvim_get_current_buf()
  local layer = ui.get_layer(buf)
  if not layer then
    return vim.NIL
  end
  local cursor = api.nvim_win_get_cursor(0)
  local lnum = cursor[1] - 1
  local lineinfo = layer.get(lnum)
  if not lineinfo or not lineinfo.item then
    return vim.NIL
  end
  ---@type dap.Variable|dap.EvaluateResponse
  local item = lineinfo.item
  local loc = item.valueLocationReference or item.declarationLocationReference
  if not loc then
    return vim.NIL
  end

  ---@type dap.ErrorResponse?
  local err
  ---@type dap.LocationsResponse?
  local result

  ---@type dap.LocationsArguments
  local args = {
    locationReference = loc
  }
  lsession:request("locations", args, function(e, r)
    err = e
    result = r
  end)
  vim.wait(2000, function() return err ~= nil or result ~= nil end)
  if result and result.source.path then
    local match = {
      name = item.name or item.result,
      filename = result.source.path,
      cmd = string.format([[/\%%%dl\%%%dc/]], result.line, result.column or 0)
    }
    return { match }
  end
  return {}
end


api.nvim_create_autocmd("ExitPre", {
  pattern = "*",
  group = api.nvim_create_augroup("dap.exit", { clear = true }),
  callback = function()
    ---@param s dap.Session
    local function close_session(s)
      s.adapter.options = {
        disconnect_timeout_sec = 0.1
      }
      if s.config.request == "attach" then
        s:disconnect({ terminateDebuggee = false })
      else
        terminate(s)
      end
    end
    for _, s in pairs(sessions) do
      close_session(s)
    end
    vim.wait(5000, function()
      ---@diagnostic disable-next-line: redundant-return-value
      return session == nil and next(sessions) == nil
    end)
    M.repl.close()
    if _log then
      _log:close()
    end
  end
})


return M
