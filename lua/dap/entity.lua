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


local function get_parent(var, variables)
  for _, v in pairs(variables) do
    local children = variable.get_children(v)
    if children then
      if vim.tbl_contains(children, var) then
        return v
      end
      local parent = get_parent(var, children)
      if parent then
        return parent
      end
    end
  end
  return nil
end


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
  local parent = get_parent(item, session.current_frame.scopes)
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
  if session and frame.id == (session.current_frame or {}).id then
    return '→ ' .. frame.name .. ':' .. frame.line
  else
    return '  ' .. frame.name .. ':' .. frame.line
  end
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
    local is_stopped = thread.stopped
    local params = { threadId = thread.id }
    local on_frames = function(err, resp)
      if err then
        utils.notify(err.message, vim.log.levels.WARN)
      else
        thread.frames = resp.stackFrames
        if is_stopped then
          cb(threads_spec.get_children(thread))
        else
          thread.stopped = false
          session:request('continue', params, function(err0)
            if err0 then
              utils.notify(err.message, vim.log.levels.WARN)
            end
            cb(threads_spec.get_children(thread))
          end)
        end
      end
    end
    local get_frames = function()
      session:request('stackTrace', params, on_frames)
    end
    if is_stopped then
      get_frames()
    else
      session:_pause(thread.id, get_frames)
    end
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
        if vim.bo.bufhidden == 'wipe' and context.view then
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
          else
            thread.stopped = false
            session:request('continue', { threadId = thread.id }, function(err)
              if err then
                utils.notify(err.message, vim.log.levels.WARN)
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
