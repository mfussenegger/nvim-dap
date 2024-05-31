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

local function dapnew(args)
  local dap = require("dap")
  local fargs = args.fargs
  if not next(fargs) then
    dap.continue({ new = true })
    return
  end
  local bufnr = api.nvim_get_current_buf()
  require("dap.async").run(function()
    for _, get_configs in pairs(dap.providers.configs) do
      local configs = get_configs(bufnr)
      for _, config in ipairs(configs) do
        if vim.tbl_contains(fargs, config.name) then
          dap.run(config)
        end
      end
    end
  end)
end
cmd("DapNew", dapnew, {
  nargs = "*",
  desc = "Start one or more new debug sessions",
  complete = function ()
    local bufnr = api.nvim_get_current_buf()
    local dap = require("dap")
    local candidates = {}
    local done = false
    require("dap.async").run(function()
      for _, get_configs in pairs(dap.providers.configs) do
        local configs = get_configs(bufnr)
        for _, config in ipairs(configs) do
          local name = config.name:gsub(" ", "\\ ")
          table.insert(candidates, name)
        end
      end
      done = true
    end)
    vim.wait(2000, function() return done == true end)
    return candidates
  end
})


if api.nvim_create_autocmd then
  local launchjson_group = api.nvim_create_augroup('dap-launch.json', { clear = true })
  local pattern =  '*/.vscode/launch.json'
  api.nvim_create_autocmd('BufNewFile', {
    group = launchjson_group,
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

  api.nvim_create_autocmd("BufReadCmd", {
    group = api.nvim_create_augroup("dap-readcmds", { clear = true }),
    pattern = "dap-eval://*",
    callback = function()
      local bufnr = api.nvim_get_current_buf()
      local fname = api.nvim_buf_get_name(bufnr)
      vim.bo[bufnr].swapfile = false
      vim.bo[bufnr].buftype = "acwrite"
      vim.bo[bufnr].bufhidden = "wipe"
      local ft = fname:match("dap%-eval://(%w+)(.*)")
      if ft and ft ~= "" then
        vim.bo[bufnr].filetype = ft
      else
        local altbuf = vim.fn.bufnr("#", false)
        if altbuf then
          vim.bo[bufnr].filetype = vim.bo[altbuf].filetype
        end
      end
      api.nvim_create_autocmd("BufWriteCmd", {
        buffer = bufnr,
        callback = function(args)
          vim.bo[args.buf].modified = false
          local repl = require("dap.repl")
          local lines = api.nvim_buf_get_lines(args.buf, 0, -1, true)
          repl.execute(table.concat(lines, "\n"))
          repl.open()
        end,
      })
    end,
  })
end
