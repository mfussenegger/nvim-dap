
if not vim.api.nvim_create_user_command then
  return
end

local cmd = vim.api.nvim_create_user_command
cmd('DapSetLogLevel',
  function(opts)
    require('dap').set_log_level(unpack(opts.fargs))
  end,
  {
    nargs = 1,
    complete = function()
      return vim.tbl_keys(require('dap.log').levels)
    end
  }
)
cmd('DapShowLog', 'split | e ' .. vim.fn.stdpath('cache') .. '/dap.log | normal! G', {})
cmd('DapContinue', function() require('dap').continue() end, { nargs = 0 })
cmd('DapToggleBreakpoint', function() require('dap').toggle_breakpoint() end, { nargs = 0 })
cmd('DapToggleRepl', function() require('dap.repl').toggle() end, { nargs = 0 })
cmd('DapStepOver', function() require('dap').step_over() end, { nargs = 0 })
cmd('DapStepInto', function() require('dap').step_into() end, { nargs = 0 })
cmd('DapStepOut', function() require('dap').step_out() end, { nargs = 0 })
cmd('DapTerminate', function() require('dap').terminate() end, { nargs = 0 })
