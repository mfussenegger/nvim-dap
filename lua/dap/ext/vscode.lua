local dap = require('dap')
local M = {}

--- Extends dap.configurations with entries read from .vscode/launch.json
--
function M.load_launchjs(path)
  local resolved_path = path or (vim.fn.getcwd() .. '/.vscode/launch.json')
  local file = io.open(resolved_path)
  if not file then
    return
  end
  local contents = file:read("*all")
  file:close()
  local data = vim.fn.json_decode(contents)
  assert(data.configurations, "launch.json must have a 'configurations' key")
  for _, config in ipairs(data.configurations) do
    assert(config.type, "Configuration in launch.json must have a 'type' key")
    local configurations = dap.configurations[config.type]
    if not configurations then
      configurations = {}
      dap.configurations[config.type] = configurations
    end
    table.insert(configurations, config)
  end
end

return M
