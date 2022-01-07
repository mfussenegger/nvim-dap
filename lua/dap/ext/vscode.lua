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
  local json_decode = vim.fn.json_decode
  if vim.json then
    json_decode = vim.json.decode
  end
  local data = json_decode(contents)

  -- Groups filetypes of debugee configs by adapters if a config use the adapter.
  -- { <adapter> = { <filetype> = boolean } }
  local filetypes_of_adapters = {}
  for filetype, configs in pairs(dap.configurations) do
    for _, config in ipairs(configs) do
      local filetypes = filetypes_of_adapters[config.type] or {}
      filetypes_of_adapters[config.type] = filetypes
      filetypes[filetype] = true
    end
  end

  assert(data.configurations, "launch.json must have a 'configurations' key")
  for _, config in ipairs(data.configurations) do
    assert(config.type, "Configuration in launch.json must have a 'type' key")
    local filetypes = filetypes_of_adapters[config.type]
    if filetypes then
      -- Add this config for filetypes containing configs with this adapter.
      for filetype, _ in pairs(filetypes) do
        local configurations = dap.configurations[filetype] or {}
        dap.configurations[filetype] = configurations
        table.insert(configurations, config)
      end
    else
      -- Fallback: make an assumption that adapter's name equals to filetype
      local configurations = dap.configurations[config.type] or {}
      dap.configurations[config.type] = configurations
      table.insert(configurations, config)
    end
  end
end

return M
