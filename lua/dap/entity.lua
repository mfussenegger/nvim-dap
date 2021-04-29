local M = {}


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


function variable.get_key(var)
  return var.name or var
end


function variable.render_parent(var)
  if var.name then
    return variable.render_child(var, 0)
  end
  local syntax_group = var.type and syntax_mapping[var.type]
  if syntax_group then
    return var.result, {{syntax_group, 0, -1},}
  end
  return var.result
end

function variable.render_child(var, indent)
  indent = indent or 0
  local hl_regions = {
    {'Identifier', indent, #var.name + indent + 1}
  }
  local prefix = string.rep(' ', indent) .. var.name .. ': '
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
  if vim.tbl_islist(var.variables) then
    return var.variables
  else
    return var.variables and vim.tbl_values(var.variables) or {}
  end
end


local function sort_vars(vars)
  local sorted_variables = {}
  for _, v in pairs(vars) do
    table.insert(sorted_variables, v)
  end
  table.sort(
    sorted_variables,
    function(a, b)
      local num_a = string.match(a.name, '^%[?(%d+)%]?$')
      local num_b = string.match(b.name, '^%[?(%d+)%]?$')
      if num_a and num_b then
        return tonumber(num_a) < tonumber(num_b)
      else
        return a.name < b.name
      end
    end
  )
  return sorted_variables
end


function variable.fetch_children(var, cb)
  local session = require('dap').session()
  if var.variables then
    cb(variable.get_children(var))
  elseif session then
    local params = { variablesReference = var.variablesReference }
    session:request('variables', params, function(err, resp)
      if err then
        M.append(err.message)
      else
        var.variables = sort_vars(resp.variables)
        cb(var.variables)
      end
    end)
  end
end


variable.tree_spec = {
  get_key = variable.get_key,
  render_parent = variable.render_parent,
  render_child = variable.render_child,
  has_children = variable.has_children,
  get_children = variable.get_children,
  fetch_children = variable.fetch_children,
}


local scope = {}
M.scope = scope


function scope.render_parent(value)
  return value.name
end

scope.tree_spec = {
  get_key = variable.get_key,
  render_parent = scope.render_parent,
  render_child = variable.render_child,
  has_children = variable.has_children,
  get_children = variable.get_children,
  fetch_children = variable.fetch_children
}


local frames = {}
M.frames = frames

function frames.render_item(frame)
  local session = require('dap').session()
  if session and frame.id == session.current_frame.id then
    return '→ ' .. frame.name
  else
    return '  ' .. frame.name
  end
end



return M
