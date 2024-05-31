local ext_utils = require('dap.ext.utils')
local dap = require('dap')
local M = {}

M.json_decode = vim.json.decode
M.type_to_filetypes = {}


---@param path string?
---@return dap.Configuration[]
function M.getconfigs(path)
  local resolved_path = path or (vim.fn.getcwd() .. '/.vscode/launch.json')
  if not vim.loop.fs_stat(resolved_path) then
    return {}
  end
  local lines = {}
  for line in io.lines(resolved_path) do
    if not vim.startswith(vim.trim(line), '//') then
      table.insert(lines, line)
    end
  end
  local contents = table.concat(lines, '\n')
  local data = assert(M.json_decode(contents), "launch.json must contain a JSON object")
  return ext_utils.load_configs(data)
end


--- Extends dap.configurations with entries read from .vscode/launch.json
function M.load_launchjs(path, type_to_filetypes)
  type_to_filetypes = vim.tbl_extend('keep', type_to_filetypes or {}, M.type_to_filetypes)
  local configurations = M.getconfigs(path)

  assert(configurations, "launch.json must have a 'configurations' key")
  for _, config in ipairs(configurations) do
    assert(config.type, "Configuration in launch.json must have a 'type' key")
    assert(config.name, "Configuration in launch.json must have a 'name' key")
    local filetypes = type_to_filetypes[config.type] or { config.type, }
    for _, filetype in pairs(filetypes) do
      local dap_configurations = dap.configurations[filetype] or {}
      for i, dap_config in pairs(dap_configurations) do
        if dap_config.name == config.name then
          -- remove old value
          table.remove(dap_configurations, i)
        end
      end
      table.insert(dap_configurations, config)
      dap.configurations[filetype] = dap_configurations
    end
  end
end

return M
