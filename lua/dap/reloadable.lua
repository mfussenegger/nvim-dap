---@brief [[
--- dap.reloadable is useful for keeping state between reloads of a file.
---
--- This allows for iterative testing without restarting dap
---@brief ]]

local reloadable = {}

__DapState = __DapState or {}
reloadable.state = __DapState

reloadable.table = function(name)
  reloadable.state[name] = reloadable.state[name] or {}

  return reloadable.state[name]
end

reloadable.set_value = function(name, val)
  reloadable.state[name] = val
end

reloadable.get_value = function(name)
  return reloadable.state[name]
end

return reloadable
