local utils = require('dap.utils')
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
  return var.name or var.result
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
  elseif session and var.variablesReference then
    local params = { variablesReference = var.variablesReference }
    session:request('variables', params, function(err, resp)
      if err then
        utils.notify(err.message, vim.log.levels.ERROR)
      else
        var.variables = sort_vars(resp.variables)
        cb(var.variables)
      end
    end)
  else
    cb({})
  end
end


local function set_variable(_, item, _, context)
  local session = require('dap').session()
  if not session then
    utils.notify('No active session, cannot set variable')
    return
  end
  local view = context.view
  if view and vim.bo.bufhidden == 'wipe' then
    view.close()
  end
  local value = vim.fn.input(string.format('New `%s` value: ', item.name))
  local params = {
    variablesReference = item.variablesReference,
    name = item.name,
    value = value,
  }
  session:request('setVariable', params, function(err)
    if err then
      utils.notify(err.message, vim.log.levels.WARN)
    else
      session:_request_scopes(session.current_frame)
    end
  end)
end


local function set_expression(_, item, _, context)
  local session = require('dap').session()
  if not session then
    utils.notify('No activate session, cannot set expression')
    return
  end
  local view = context.view
  if view and vim.bo.bufhidden == 'wipe' then
    view.close()
  end
  local value = vim.fn.input(string.format('New `%s` expression: ', item.name))
  local params = {
    expression = item.evaluateName,
    value = value,
    frameId = session.current_frame and session.current_frame.id
  }
  session:request('setExpression', params, function(err)
    if err then
      utils.notify(err.message, vim.log.levels.WARN)
    else
      session:_request_scopes(session.current_frame)
    end
  end)
end


variable.tree_spec = {
  get_key = variable.get_key,
  render_parent = variable.render_parent,
  render_child = variable.render_child,
  has_children = variable.has_children,
  get_children = variable.get_children,
  fetch_children = variable.fetch_children,
  compute_actions = function(info)
    local session = require('dap').session()
    if not session then
      return {}
    end
    local result = {}
    local capabilities = session.capabilities
    local item = info.item
    if item.evaluateName and capabilities.supportsSetExpression then
      table.insert(result, { label = 'Set expression', fn = set_expression, })
    elseif capabilities.supportsSetVariable then
      table.insert(result, { label = 'Set variable', fn = set_variable, })
    end
    return result
  end
}


local scope = {}
M.scope = scope


function scope.render_parent(value)
  return value.name
end

scope.tree_spec = vim.tbl_extend('force', variable.tree_spec, {
  render_parent = scope.render_parent,
})


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
