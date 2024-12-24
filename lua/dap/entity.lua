local utils = require('dap.utils')
local M = {}


local variable = {}
M.variable = variable

local types_to_hl_group = {
  boolean = "Boolean",
  string = "String",
  int = "Number",
  long = "Number",
  number = "Number",
  double = "Float",
  float = "Float",
  ["function"] = "Function",
}


---@param var dap.Variable|dap.EvaluateResponse
function variable.get_key(var)
  return var.name or var.result
end


function variable.is_lazy(var)
  return (var.presentationHint or {}).lazy
end


---@alias dap.entity.hl [string, integer, integer][]


---@param var dap.Variable|dap.EvaluateResponse
---@result string, dap.entity.hl[]
function variable.render_parent(var)
  if var.name then
    return variable.render_child(var --[[@as dap.Variable]], 0)
  end
  local syntax_group = var.type and types_to_hl_group[var.type:lower()]
  if syntax_group then
    return var.result, {{syntax_group, 0, -1},}
  end
  return var.result
end

---@param var dap.Variable
---@param indent integer
---@result string, dap.entity.hl[]
function variable.render_child(var, indent)
  indent = indent or 0
  local hl_regions = {
    {'Identifier', indent, #var.name + indent + 1}
  }
  local prefix = string.rep(' ', indent) .. var.name .. ': '
  local syntax_group = var.type and types_to_hl_group[var.type:lower()]
  if syntax_group then
    table.insert(hl_regions, {syntax_group, #prefix, -1})
  end
  return prefix .. var.value, hl_regions
end

function variable.has_children(var)
  return (var.variables and #var.variables > 0) or var.variablesReference ~= 0
end

---@param var dap.Variable|dap.Scope
---@result dap.Variable[]
function variable.get_children(var)
  return var.variables or {}
end


---@param a dap.Variable
---@param b dap.Variable
local function cmp_vars(a, b)
  local num_a = string.match(a.name, '^%[?(%d+)%]?$')
  local num_b = string.match(b.name, '^%[?(%d+)%]?$')
  if num_a and num_b then
    return tonumber(num_a) < tonumber(num_b)
  else
    return a.name < b.name
  end
end


---@param var dap.Variable|dap.Scope
---@param cb fun(variables: dap.Variable[])
function variable.fetch_children(var, cb)
  local session = require('dap').session()
  if var.variables then
    cb(variable.get_children(var))
  elseif session and var.variablesReference > 0 then

    ---@param err? dap.ErrorResponse
    ---@param resp? dap.VariableResponse
    local function on_variables(err, resp)
      if err then
        utils.notify('Error fetching variables: ' .. err.message, vim.log.levels.ERROR)
      elseif resp then
        local variables = resp.variables
        local unloaded = #variables
        local function countdown()
          unloaded = unloaded - 1
          if unloaded == 0 then
            var.variables = variables
            cb(variables)
          end
        end

        table.sort(variables, cmp_vars)
        for i, v in ipairs(variables) do
          v.parent = var
          if variable.is_lazy(v) then
            variable.load_value(v, function(loaded_v)
              variables[i] = loaded_v
              countdown()
            end)
          else
            countdown()
          end
        end
      end
    end
    ---@type dap.VariablesArguments
    local params = { variablesReference = var.variablesReference }
    session:request('variables', params, on_variables)
  else
    cb({})
  end
end


function variable.load_value(var, cb)
  assert(variable.is_lazy(var), "Must not call load_value if not lazy")
  local session = require('dap').session()
  if not session then
    cb(var)
  else
    ---@type dap.VariablesArguments
    local params = { variablesReference = var.variablesReference }
    ---@param err? dap.ErrorResponse
    ---@param resp? dap.VariableResponse
    local function on_variables(err, resp)
      if err then
        utils.notify('Error fetching variable: ' .. err.message, vim.log.levels.ERROR)
      elseif resp then
        local new_var = resp.variables[1]
        -- keep using the old variable;
        -- it has parent references and the parent contains references to the child
        var.value = new_var.value
        var.presentationHint = new_var.presentationHint
        var.variablesReference = new_var.variablesReference
        var.namedVariables = new_var.namedVariables
        var.indexedVariables = new_var.indexedVariables
        cb(var)
      end
    end
    session:request('variables', params, on_variables)
  end
end


---@param item dap.Variable
local function set_variable(_, item, _, context)
  local session = require('dap').session()
  if not session then
    utils.notify('No active session, cannot set variable')
    return
  end
  if not session.current_frame then
    utils.notify('Session has no active frame, cannot set variable')
    return
  end
  local parent = item.parent
  if not parent then
    utils.notify(string.format(
      "Cannot set variable on %s, couldn't find its parent container",
      item.name
    ))
    return
  end
  local view = context.view
  if view and vim.bo.bufhidden == 'wipe' then
    view.close()
  end
  local value = vim.fn.input(string.format('New `%s` value: ', item.name))
  local params = {
    variablesReference = parent.variablesReference,
    name = item.name,
    value = value,
  }
  session:request('setVariable', params, function(err)
    if err then
      utils.notify('Error setting variable: ' .. err.message, vim.log.levels.WARN)
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
      utils.notify('Error on setExpression: ' .. tostring(err), vim.log.levels.WARN)
    else
      session:_request_scopes(session.current_frame)
    end
  end)
end


---@param item dap.Variable
local function copy_evalname(_, item, _, _)
  vim.fn.setreg("", item.evaluateName)
end


variable.tree_spec = {
  get_key = variable.get_key,
  render_parent = variable.render_parent,
  render_child = variable.render_child,
  has_children = variable.has_children,
  get_children = variable.get_children,
  is_lazy = variable.is_lazy,
  load_value = variable.load_value,
  fetch_children = variable.fetch_children,
  compute_actions = function(info)
    local session = require('dap').session()
    if not session then
      return {}
    end
    local result = {}
    local capabilities = session.capabilities
    ---@type dap.Variable
    local item = info.item
    if item.evaluateName then
      table.insert(result, { label = "Copy as expression", fn = copy_evalname, })
    end
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
  local line
  if session and frame.id == (session.current_frame or {}).id then
    line = '→ ' .. frame.name .. ':' .. frame.line
  else
    line = '  ' .. frame.name .. ':' .. frame.line
  end
  if frame.presentationHint == 'subtle' then
    return line, {{'Comment', 0, -1},}
  end
  return line
end


M.threads = {
  tree_spec = {
    implicit_expand_action = false,
  },
}
local threads_spec = M.threads.tree_spec

function threads_spec.get_key(thread)
  return thread.id
end

function threads_spec.render_parent(thread)
  return thread.name
end

function threads_spec.render_child(thread_or_frame)
  if thread_or_frame.line then
    -- it's a frame
    return frames.render_item(thread_or_frame)
  end
  if thread_or_frame.stopped then
    return '⏸️ ' .. thread_or_frame.name
  else
    return '▶️ ' .. thread_or_frame.name
  end
end

function threads_spec.has_children(thread_or_frame)
  -- Threads have frames
  return thread_or_frame.line == nil
end

function threads_spec.get_children(thread)
  if thread.threads then
    return thread.threads or {}
  end
  return thread.frames or {}
end


function threads_spec.fetch_children(thread, cb)
  local session = require('dap').session()
  if thread.line then
    -- this is a frame, not a thread
    cb({})
  elseif thread.threads then
    cb(thread.threads)
  elseif session then
    coroutine.wrap(function()
      local co = coroutine.running()
      local is_stopped = thread.stopped
      if not is_stopped then
        session:_pause(thread.id, function(err, result)
          coroutine.resume(co, err, result)
        end)
        coroutine.yield()
      end
      local params = { threadId = thread.id }
      local err, resp = session:request('stackTrace', params)
      if err then
        utils.notify('Error fetching stackTrace: ' .. tostring(err), vim.log.levels.WARN)
      else
        thread.frames = resp.stackFrames
      end
      if not is_stopped then
        local err0 = session:request('continue', params)
        if err0 then
          utils.notify('Error on continue: ' .. tostring(err0), vim.log.levels.WARN)
        else
          thread.stopped = false
          local progress = require('dap.progress')
          progress.report('Thread resumed: ' .. tostring(thread.id))
          progress.report('Running: ' .. session.config.name)
        end
      end
      cb(threads_spec.get_children(thread))
    end)()
  else
    cb({})
  end
end


function threads_spec.compute_actions(info)
  local session = require('dap').session()
  if not session then
    return {}
  end
  local context = info.context
  local thread = info.item
  local result = {}
  if thread.line then
    -- this is a frame, not a thread
    table.insert(result, {
      label = 'Jump to frame',
      fn = function(_, frame)
        session:_frame_set(frame)
        if context.view and vim.bo[context.view.buf].bufhidden == 'wipe' then
          context.view.close()
        end
      end
    })
  else
    table.insert(result, { label = 'Expand', fn = context.tree.toggle })
    if thread.stopped then
      table.insert(result, {
        label = 'Resume thread',
        fn = function()
          if session.stopped_thread_id == thread.id then
            session:_step('continue')
            context.refresh()
          else
            thread.stopped = false
            session:request('continue', { threadId = thread.id }, function(err)
              if err then
                utils.notify('Error on continue: ' .. tostring(err), vim.log.levels.WARN)
              end
              context.refresh()
            end)
          end
        end
      })
    else
      table.insert(result, {
        label = 'Stop thread',
        fn = function()
          session:_pause(thread.id, context.refresh)
        end
      })
    end
  end
  return result
end


return M
