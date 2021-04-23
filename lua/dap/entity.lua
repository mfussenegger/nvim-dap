local M = {}
local ui = require('dap.ui')


local variable = {}
M.variable = variable

local syntax_mapping = {
  boolean = 'Boolean',
  String = 'String',
  int = 'Number',
  long = 'Number',
  double = 'Float',
  float = 'Float',
}


function variable.render_parent(var)
  local syntax_group = var.type and syntax_mapping[var.type]
  if syntax_group then
    return var.result, {{syntax_group, 0, -1},}
  end
  return var.result
end

function variable.render_child(var)
  local hl_regions = {
    {'Identifier', 2, #var.name + 3}
  }
  local prefix = '  ' .. var.name .. ': '
  local syntax_group = var.type and syntax_mapping[var.type]
  if syntax_group then
    table.insert(hl_regions, {syntax_group, #prefix, -1})
  end
  return prefix .. var.value, hl_regions
end

function variable.has_children(var)
  return (var.variables and #var.variables > 0) or var.variablesReference ~= 0
end

function variable.get_children(var)
  return var.variables or {}
end

function variable.fetch_children(var, cb)
  local session = require('dap').session()
  if var.variables then
    cb(var.variables)
  elseif session then
    local params = { variablesReference = var.variablesReference }
    session:request('variables', params, function(err, resp)
      if err then
        M.append(err.message)
      else
        var.variables = resp.variables
        cb(resp.variables)
      end
    end)
  end
end

variable.tree_spec = {
  render_parent = variable.render_parent,
  render_child = variable.render_child,
  has_children = variable.has_children,
  get_children = variable.get_children,
  fetch_children = variable.fetch_children,
}


return M
