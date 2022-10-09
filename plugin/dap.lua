
local api = vim.api
if not api.nvim_create_user_command then
  return
end

local cmd = api.nvim_create_user_command
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
cmd('DapLoadLaunchJSON', function() require('dap.ext.vscode').load_launchjs() end, { nargs = 0 })
cmd('DapRestartFrame', function() require('dap').restart_frame() end, { nargs = 0 })


if api.nvim_create_autocmd then
  local group = api.nvim_create_augroup('dap-launch.json', { clear = true })
  local pattern =  '*/.vscode/launch.json'
  api.nvim_create_autocmd('BufNewFile', {
    group = group,
    pattern = pattern,
    callback = function(args)
      local lines = {
        '{',
        '   "version": "0.2.0",',
        '   "configurations": [',
        '       {',
        '           "type": "<adapter-name>",',
        '           "request": "launch",',
        '           "name": "Launch"',
        '       }',
        '   ]',
        '}'
      }
      api.nvim_buf_set_lines(args.buf, 0, -1, true, lines)
    end
  })
  api.nvim_create_autocmd('BufWritePost', {
    group = group,
    pattern = pattern,
    callback = function(args)
      require('dap.ext.vscode').load_launchjs(args.file)
    end
  })
end
