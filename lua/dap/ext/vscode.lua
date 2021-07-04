local dap = require('dap')
local M = {}

--- Extends dap.configurations with entries read from .vscode/launch.json
--
function M.load_launchjs(path)
  local resolved_path = path or (vim.fn.getcwd() .. '/.vscode/launch.json')
  if not vim.loop.fs_stat(resolved_path) then
    return
  end
  local lines = {}
  for line in io.lines(resolved_path) do
    if not vim.startswith(vim.trim(line), '//') then
      table.insert(lines, line)
    end
  end
  local contents = table.concat(lines, '\n')
  local data = vim.fn.json_decode(contents)
  assert(data.configurations, "launch.json must have a 'configurations' key")
  for _, config in ipairs(data.configurations) do
    assert(config.type, "Configuration in launch.json must have a 'type' key")
    local config_key = config.nvimKey or config.type
    local configurations = dap.configurations[config_key]
    if not configurations then
      configurations = {}
      dap.configurations[config_key] = configurations
    end
    table.insert(configurations, config)
  end
end

return M
