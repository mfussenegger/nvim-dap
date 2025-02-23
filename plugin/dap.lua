local api = vim.api
if not api.nvim_create_user_command then
  return
end

local cmd = api.nvim_create_user_command
cmd('DapSetLogLevel',
  ---@param opts vim.api.keyset.create_user_command.command_args
  function(opts)
    require('dap').set_log_level(vim.trim(opts.args))
  end,
  {
    nargs = 1,
    complete = function()
      return vim.tbl_keys(require('dap.log').levels)
    end
  }
)
cmd('DapShowLog', function() require("dap._cmds").show_logs() end, { nargs = 0 })
cmd('DapContinue', function() require('dap').continue() end, { nargs = 0 })
cmd('DapToggleBreakpoint', function() require('dap').toggle_breakpoint() end, { nargs = 0 })
cmd('DapClearBreakpoints', function() require('dap').clear_breakpoints() end, { nargs = 0 })
cmd('DapToggleRepl', function() require('dap.repl').toggle() end, { nargs = 0 })
cmd('DapStepOver', function() require('dap').step_over() end, { nargs = 0 })
cmd('DapStepInto', function() require('dap').step_into() end, { nargs = 0 })
cmd('DapStepOut', function() require('dap').step_out() end, { nargs = 0 })
cmd('DapPause', function () require('dap').pause() end, { nargs = 0 })
cmd('DapTerminate', function() require('dap').terminate() end, { nargs = 0 })
cmd('DapDisconnect', function() require('dap').disconnect({ terminateDebuggee = false }) end, { nargs = 0 })
cmd('DapRestartFrame', function() require('dap').restart_frame() end, { nargs = 0 })

local function dapnew(args)
  return require("dap._cmds").new(args)
end
cmd("DapNew", dapnew, {
  nargs = "*",
  desc = "Start one or more new debug sessions",
  complete = function ()
    return require("dap._cmds").new_complete()
  end
})

cmd("DapEval", function(params)
  require("dap._cmds").eval(params)
end, {
  nargs = 0,
  range = "%",
  bang = true,
  bar = true,
  desc = "Create a new window & buffer to evaluate expressions",
})


if api.nvim_create_autocmd then
  local launchjson_group = api.nvim_create_augroup('dap-launch.json', { clear = true })
  local pattern =  '*/.vscode/launch.json'
  api.nvim_create_autocmd('BufNewFile', {
    group = launchjson_group,
    pattern = pattern,
    callback = function(args)
      require("dap._cmds").newlaunchjson(args)
    end
  })

  api.nvim_create_autocmd("BufReadCmd", {
    group = api.nvim_create_augroup("dap-readcmds", { clear = true }),
    pattern = "dap-eval://*",
    callback = function()
      require("dap._cmds").bufread_eval()
    end,
  })
end
