local dap = require('dap')
local M = {}

--- Extends dap.configurations with entries read from .vscode/launch.json
function M.load_launchjs(path, type_to_filetypes)
  type_to_filetypes = type_to_filetypes or {}
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
  local json_decode = vim.fn.json_decode
  if vim.json then
    json_decode = vim.json.decode
  end
  local data = json_decode(contents)

  assert(data.configurations, "launch.json must have a 'configurations' key")
  for _, config in ipairs(data.configurations) do
    assert(config.type, "Configuration in launch.json must have a 'type' key")
    local filetypes = type_to_filetypes[config.type] or {config.type,}
    for _, filetype in pairs(filetypes) do
      local configurations = dap.configurations[filetype] or {}
      dap.configurations[filetype] = configurations
      table.insert(configurations, config)
    end
  end
end


return M
