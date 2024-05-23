local api = vim.api
local M = {}

---@diagnostic disable-next-line: deprecated
local islist = vim.islist or vim.tbl_islist

---@type table<number, Session>
local sessions = {}

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

local function notify(...)
  lazy.utils.notify(...)
end

--- Sentinel value; signals an operation should be aborted.
---@class dap.Abort
M.ABORT = {}

M.status = function(...)
  return lazy.progress.status(...)
end
M.repl = setmetatable({}, {
  __index = function(_, key)
    return require('dap.repl')[key]
  end
})


---@class DapListeners
---@field event_breakpoint table<string, fun(session: Session, body: any)>
---@field event_capabilities table<string, fun(session: Session, body: any)>
---@field event_continued table<string, fun(session: Session, body: any)>
---@field event_exited table<string, fun(session: Session, body: any)>
---@field event_initialized table<string, fun(session: Session, body: any)>
---@field event_invalidated table<string, fun(session: Session, body: any)>
---@field event_loadedSource table<string, fun(session: Session, body: any)>
---@field event_memory table<string, fun(session: Session, body: any)>
---@field event_module table<string, fun(session: Session, body: any)>
---@field event_output table<string, fun(session: Session, body: any)>
---@field event_process table<string, fun(session: Session, body: any)>
---@field event_progressEnd table<string, fun(session: Session, body: dap.ProgressEndEvent)>
---@field event_progressStart table<string, fun(session: Session, body: dap.ProgressStartEvent)>
---@field event_progressUpdate table<string, fun(session: Session, body: dap.ProgressUpdateEvent)>
---@field event_stopped table<string, fun(session: Session, body: dap.StoppedEvent)>
---@field event_terminated table<string, fun(session: Session, body: dap.TerminatedEvent)>
---@field event_thread table<string, fun(session: Session, body: any)>
---@field attach table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field breakpointLocations table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field completions table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field configurationDone table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field continue table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field dataBreakpointInfo table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field disassemble table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field disconnect table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field evaluate table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field exceptionInfo table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field goto table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field gotoTargets table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field initialize table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field launch table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field loadedSources table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field modules table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field next table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field pause table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field readMemory table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field restart table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field restartFrame table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field reverseContinue table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field scopes table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field setBreakpoints table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field setDataBreakpoints table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field setExceptionBreakpoints table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field setExpression table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field setFunctionBreakpoints table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field setInstructionBreakpoints table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field setVariable table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field source table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field stackTrace table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field stepBack table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field stepIn table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field stepInTargets table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field stepOut table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field terminate table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field terminateThreads table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field threads table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field variables table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>
---@field writeMemory table<string, fun(session: Session, err: any, body: any, request: any, seq: number)>


M.listeners = {
  ---@type DapListeners
  before = setmetatable({}, {
    __index = function(tbl, key)
      rawset(tbl, key, {})
      return rawget(tbl, key)
    end
  });
  ---@type DapListeners
  after = setmetatable({}, {
    __index = function(tbl, key)
      rawset(tbl, key, {})
      return rawget(tbl, key)
    end
  });
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
      exception_breakpoints = 'default';
      ---@type "statement"|"line"|"instruction"
      stepping_granularity = 'statement';

      ---@type string|fun(): number bufnr, number|nil win
      terminal_win_cmd = 'belowright new';
      focus_terminal = false;
      auto_continue_if_many_stopped = true;

      ---@type string|nil
      switchbuf = nil
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
---@field enrich_config? fun(config: Configuration, on_config: fun(config: Configuration))
---@field reverse_request_handlers? table<string, fun(session: Session, request: dap.Request)>

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
---@field port integer
---@field executable nil|ServerAdapterExecutable
---@field options nil|ServerOptions


---@class DapPipeOptions
---@field timeout? integer max amount of time in ms to wait between spawning the executable and connecting. This gives the executable time to create the pipe. Defaults to 5000

---@class PipeAdapter : Adapter
---@field type "pipe"
---@field pipe string absolute path to the pipe or ${pipe} to use random tmp path
---@field executable? ServerAdapterExecutable
---@field options? DapPipeOptions

---@class ServerAdapterExecutable
---@field command string
---@field args nil|string[]
---@field cwd nil|string
---@field detached nil|boolean


---@alias Dap.AdapterFactory fun(callback: fun(adapter: Adapter), config: Configuration, parent?: Session)

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
---@type table<string, Adapter|Dap.AdapterFactory>
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
  ['${command:pickProcess}'] = lazy.utils.pick_process
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

---@param lsession Session
local function add_reset_session_hook(lsession)
  lsession.on_close['dap.session'] = function(s)
    assert(s.id == lsession.id, "on_close must not be called with a foreign session")
    lazy.progress.report('Closed session: ' .. tostring(s.id))
    sessions[s.id] = nil
    M.set_session(nil)
  end
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
  elseif adapter.type == "pipe" then
    lazy.progress.report("Running: " .. name)
    local lsession
    lsession = require("dap.session").pipe(adapter, opts, function(err)
      if not err then
        lsession:initialize(configuration)
      end
    end)
    add_reset_session_hook(lsession)
    M.set_session(lsession)
  else
    notify(string.format('Invalid adapter type %s, expected `executable` or `server`', adapter.type), vim.log.levels.ERROR)
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
  local filetype = vim.bo.filetype
  local configurations = M.configurations[filetype] or {}
  assert(
    islist(configurations),
    string.format(
      '`dap.configurations.%s` must be a list of configurations, got %s',
      filetype,
      vim.inspect(configurations)
    )
  )
  if #configurations == 0 then
    local msg = 'No configuration found for `%s`. You need to add configs to `dap.configurations.%s` (See `:h dap-configuration`)'
    notify(string.format(msg, filetype, filetype), vim.log.levels.INFO)
    return
  end
  opts = opts or {}
  opts.filetype = opts.filetype or filetype
  lazy.ui.pick_if_many(
    configurations,
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
end


--- Get the first stopped session.
--- If no session is stopped, it returns the active session or next in sessions.
---@return Session|nil
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


--- Start a debug session
---@param config Configuration
---@param opts table|nil
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
    local mt = getmetatable(config)
    if mt and type(mt.__call) == "function" then
      config = config()
      assert(config and type(config) == "table", "config metatable __call must return a config table")
    end
    config = vim.tbl_map(expand_config_variables, config)
    for _, val in pairs(config) do
      if val == M.ABORT then
        notify("Run aborted", vim.log.levels.INFO)
        return
      end
    end
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
      notify(string.format(
        'The selected configuration references adapter `%s`, but dap.adapters.%s is undefined',
        config.type,
        config.type
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
        'Error on step_into: ' .. lazy.utils.fmt_error(err) .. ' (while requesting stepInTargets)',
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


local function terminate(lsession, terminate_opts, disconnect_opts, cb)
  cb = cb or function() end
  if not lsession then
    notify('No active session')
    cb()
    return
  end

  if lsession.closed then
    log().warn('User called terminate on already closed session that is still in use')
    sessions[lsession.id] = nil
    M.set_session(nil)
    cb()
    return
  end
  local capabilities = lsession.capabilities or {}
  if capabilities.supportsTerminateRequest then
    capabilities.supportsTerminateRequest = false
    local opts = terminate_opts or vim.empty_dict()
    local timeout_sec = (lsession.adapter.options or {}).disconnect_timeout_sec or 3
    local timeout_ms = timeout_sec * 1000
    lsession:request_with_timeout('terminate', opts, timeout_ms, function(err)
      if err then
        log().warn(lazy.utils.fmt_error(err))
      end
      if not lsession.closed then
        lsession:close()
      end
      notify('Session terminated')
      cb()
    end)
  else
    local opts = disconnect_opts or { terminateDebuggee = true }
    lsession:disconnect(opts, cb)
  end
end


function M.terminate(terminate_opts, disconnect_opts, cb)
  local lsession = session
  if not lsession then
    local _, s = next(sessions)
    if s then
      log().info("Terminate called without active session, switched to", s.id)
    end
    lsession = s
  end
  terminate(lsession, terminate_opts, disconnect_opts, cb)
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


function M.restart(config, opts)
  local lsession = opts and opts.session or session
  if not lsession then
    notify('No active session', vim.log.levels.INFO)
    return
  end
  config = config or lsession.config
  if lsession.capabilities.supportsRestartRequest then
    require("dap.async").run(function()
      local mt = getmetatable(config)
      if mt and type(mt.__call) == "function" then
        config = config()
        assert(config and type(config) == "table", "config metatable __call must return a config table")
      end
      config = vim.tbl_map(expand_config_variables, config)
      lsession:request('restart', config, function(err0, _)
        if err0 then
          notify('Error restarting debug adapter: ' .. lazy.utils.fmt_error(err0), vim.log.levels.ERROR)
        else
          notify('Restarted debug adapter', vim.log.levels.INFO)
        end
      end)
    end)
  else
    terminate(lsession, nil, nil, vim.schedule_wrap(function()
      local nopts = vim.deepcopy(opts) or {}
      nopts.new = true
      M.run(config, nopts)
    end))
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


---@param lsessions table<integer, Session>
---@param fn fun(lsession: Session)
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


--- Connect to a debug adapter via TCP
---@param adapter ServerAdapter
---@param config Configuration
---@param opts table
function M.attach(adapter, config, opts)
  if not config.request then
    notify('Config needs the `request` property which must be one of `attach` or `launch`', vim.log.levels.ERROR)
    return
  end
  assert(adapter.port, 'Adapter used with attach must have a port property')
  local s
  s = require('dap.session'):connect(adapter, opts, function(err)
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
  add_reset_session_hook(s)
  M.set_session(s)
  return s
end


--- Launch an executable debug adapter and initialize a session
---
---@param adapter ExecutableAdapter
---@param config Configuration
---@param opts table
function M.launch(adapter, config, opts)
  local s = require('dap.session'):spawn(adapter, opts)
  add_reset_session_hook(s)
  M.set_session(s)
  s:initialize(config)
  return s
end


function M.set_log_level(level)
  log().set_level(level)
end


function M._vim_exit_handler()
  for _, s in pairs(sessions) do
    if s.config.request == "attach" then
      s:disconnect({ terminateDebuggee = false })
    else
      terminate(s)
    end
  end
  vim.wait(500, function()
    ---@diagnostic disable-next-line: redundant-return-value
    return session == nil and next(sessions) == nil
  end)
  M.repl.close()
end


--- Currently focused session
---@return Session|nil
function M.session()
  return session
end


---@return table<number, Session>
function M.sessions()
  return sessions
end


---@param new_session Session|nil
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


api.nvim_command("autocmd ExitPre * lua require('dap')._vim_exit_handler()")
return M
