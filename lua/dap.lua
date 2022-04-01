local api = vim.api
local utils = require('dap.utils')
local M = {}
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
      -- type SteppingGranularity = 'statement' | 'line' | 'instruction'
      stepping_granularity = 'statement';
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
--    -- Some predefined variables are supported. Their definitions can be found here
--    -- https://code.visualstudio.com/docs/editor/variables-reference#_predefined-variables-examples
--    -- The supported variables are:
--    -- ${file}
--    -- ${fileBasename}
--    -- ${fileBasenameNoExtension}
--    -- ${fileDirname}
--    -- ${fileExtname}
--    -- ${relativeFile}
--    -- ${relativeFileDirname}
--    -- ${workspaceFolder}
--    -- ${workspaceFolderBasename}
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
vim.fn.sign_define("DapBreakpointCondition", { text = "C", texthl = "", linehl = "", numhl = "" })
vim.fn.sign_define('DapBreakpointRejected', {text='R', texthl='', linehl='', numhl=''})
vim.fn.sign_define('DapLogPoint', {text='L', texthl='', linehl='', numhl=''})
vim.fn.sign_define('DapStopped', {text='→', texthl='', linehl='debugPC', numhl=''})


local function expand_config_variables(option)
  if type(option) == 'function' then
    option = option()
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
  else
    utils.notify(
      string.format(
        'Invalid adapter `%s` for config `%s`',
        vim.inspect(adapter),
        config.type
      ),
      vim.log.levels.ERROR
    )
  end
end


function M.run_last()
  if last_run then
    M.run(last_run.config, last_run.opts)
  else
    utils.notify('No configuration available to re-run', vim.log.levels.INFO)
  end
end



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
      utils.notify('Error on step_into: ' .. err.message .. ' (while requesting stepInTargets)', vim.log.levels.ERROR)
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
        utils.notify('Error restarting debug adapter: ' .. err0.message, vim.log.levels.ERROR)
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
  vim.fn.setqflist({}, 'r', {
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
    session:set_breakpoints(bufnr)
  end
  if vim.fn.getqflist({context = DAP_QUICKFIX_CONTEXT}).context == DAP_QUICKFIX_CONTEXT then
    M.list_breakpoints(false)
  end
end


function M.clear_breakpoints()
  if session then
    local bps = lazy.breakpoints.get()
    lazy.breakpoints.clear()
    for bufnr, _ in pairs(bps) do
      session:set_breakpoints(bufnr)
    end
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

  local bps = lazy.breakpoints.get()
  lazy.breakpoints.clear()
  local bufnr = api.nvim_get_current_buf()
  local lnum = api.nvim_win_get_cursor(0)[1]
  lazy.breakpoints.set({}, bufnr, lnum)

  local function restore_breakpoints()
    M.listeners.before.event_stopped['dap.run_to_cursor'] = nil
    M.listeners.before.event_terminated['dap.run_to_cursor'] = nil
    lazy.breakpoints.clear()
    for buf, buf_bps in pairs(bps) do
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
    session:set_breakpoints()
  end

  M.listeners.before.event_stopped['dap.run_to_cursor'] = restore_breakpoints
  M.listeners.before.event_terminated['dap.run_to_cursor'] = restore_breakpoints
  session:set_breakpoints(nil, function()
    session:_step('continue')
  end)
end


function M.continue()
  if not session then
    select_config_and_run()
  elseif session.stopped_thread_id then
    session:_step('continue')
  else
    local prompt = (session.initialized
      and "Session active, but not stopped at breakpoint> "
      or "Session still initializing> "
    )
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


--- Attach to an existing debug-adapter running on host, port
--  and then initialize it with config
--
-- Configuration:         -- Specifies how the debug adapter should connect/launch the debugee
--    request: string     -- attach or launch
--    ...                 -- debug adapter specific options
--
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
  assert(adapter.host, 'Adapter used with attach must have a host property')
  assert(adapter.port, 'Adapter used with attach must have a port property')
  session = require('dap.session'):connect(adapter, opts, function(err)
    assert(not err, vim.inspect(err))
    session:initialize(config)
  end)
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
-- Configuration:         -- Specifies how the debug adapter should connect/launch the debugee
--    request: string     -- attach or launch
--    ...                 -- debug adapter specific options
--
function M.launch(adapter, config, opts)
  session = require('dap.session'):spawn(adapter, opts)
  session:initialize(config)
  return session
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


--- Return the current session or nil
function M.session()
  return session
end


function M.set_session(s)
  session = s
end


api.nvim_command("autocmd ExitPre * lua require('dap')._vim_exit_handler()")
return M
