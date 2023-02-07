local dap = require('dap')
local notify = require('dap.utils').notify
local M = {}

M.json_decode = vim.json.decode
M.type_to_filetypes = {}

local function create_input(type_, input)
  if type_ == "promptString" then
    return function()
      local description = input.description or 'Input'
      if not vim.endswith(description, ': ') then
        description = description .. ': '
      end
      return vim.fn.input(description, input.default or '')
    end
  elseif type_ == "pickString" then
    return function()
      local options = assert(input.options, "input of type pickString must have an `options` property")
      local opts = {
        prompt = input.description,
        format_item = function(option)
          return option["label"] or option
        end
      }
      local co = coroutine.running()
      vim.ui.select(options, opts, function(option)
        vim.schedule(function()
          coroutine.resume(co, option["value"] or option or input.default or '')
        end)
      end)
      return coroutine.yield()
    end
  else
    local msg = "Unsupported input type in vscode launch.json: " .. type_
    notify(msg, vim.log.levels.WARN)
  end
end


local function create_inputs(inputs)
  local result = {}
  for _, input in ipairs(inputs) do
    local id = assert(input.id, "input must have a `id`")
    local key = "${input:" .. id .. "}"
    local type_ = assert(input.type, "input must have a `type`")
    local fn = create_input(type_, input)
    if fn then
      result[key] = fn
    end
  end
  return result
end

local function chain(default, fns)
  return function()
    local result = default
    for _, fn in ipairs(fns) do
      result = fn(result)
    end
    return result
  end
end

local function collect_input_keys(inputs, value, keys)
  if type(value) == "table" then
    local new_value = {}
    for k, v in pairs(value) do
      new_value[k] = collect_input_keys(inputs, v, keys)
    end
    value = new_value
  end
  if type(value) ~= "string" then
    return
  end
  local matches = string.gmatch(value, "${input:([%w_]+)}")
  for input_id in matches do
    local input_key = "${input:" .. input_id .. "}"
    local input = inputs[input_key]
    if not input then
      local msg = "No input with id `" .. input_id .. "` found in inputs"
      notify(msg, vim.log.levels.WARN)
    else
      keys[input_id] = 1
    end
  end
end


local function collect_matches(value, pattern)
  local result = {}
  local matches = string.gmatch(value, pattern)
  for match in matches do
    table.insert(result, match)
  end
  return result
end


local function apply_input(once, input_key_to_input_functions, value)
  if type(value) == "table" then
    local new_value = {}
    for k, v in pairs(value) do
      new_value[k] = apply_input(once, input_key_to_input_functions, v)
    end
    value = new_value
  end
  if type(value) ~= "string" then
    return value
  end
  local matches = collect_matches(value, "${input:([%w_]+)}")
  local input_functions = {}
  if next(matches) then
    for input_key, input_fn in pairs(input_key_to_input_functions) do
      table.insert(input_functions, function(val)
        assert(coroutine.running(), "Must run in coroutine")
        if once[input_key] == nil then
          local updated = input_fn()
          once[input_key] = updated
        end
        local replace_with = once[input_key]
        if replace_with ~= nil then
          return string.gsub(val, input_key, replace_with)
        else
          return val
        end
      end)
    end
  end
  if next(input_functions) then
    return chain(value, input_functions)
  else
    return value
  end
end


local function apply_inputs(config, inputs)
  local result = {}

  -- first figure out which keys we need
  local input_ids = {}
  for _, value in pairs(config) do
    collect_input_keys(inputs, value, input_ids)
  end

  -- now collect value fn's for them
  local input_key_to_input_functions = {}
  for input_id, _ in pairs(input_ids) do
    local input_key = "${input:" .. input_id .. "}"
    local input = inputs[input_key]
    input_key_to_input_functions[input_key] = input
  end

  -- finall apply the values
  local once = {}
  for key, value in pairs(config) do
    result[key] = apply_input(once, input_key_to_input_functions, value)
  end

  return result
end


--- Lift properties of a child table to top-level
local function lift(tbl, key)
  local child = tbl[key]
  if child then
    tbl[key] = nil
    return vim.tbl_extend('force', tbl, child)
  end
  return tbl
end


function M._load_json(jsonstr)
  local data = M.json_decode(jsonstr)
  local inputs = create_inputs(data.inputs or {})
  local has_inputs = next(inputs) ~= nil

  local sysname
  if vim.fn.has('linux') == 1 then
    sysname = 'linux'
  elseif vim.fn.has('mac') == 1 then
    sysname = 'osx'
  elseif vim.fn.has('win32') == 1 then
    sysname = 'windows'
  end

  local configs = {}
  for _, config in ipairs(data.configurations or {}) do
    config = lift(config, sysname)
    table.insert(configs, has_inputs and apply_inputs(config, inputs) or config)
  end
  return configs
end


--- Extends dap.configurations with entries read from .vscode/launch.json
function M.load_launchjs(path, type_to_filetypes)
  type_to_filetypes = vim.tbl_extend('keep', type_to_filetypes or {}, M.type_to_filetypes)
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
  local configurations = M._load_json(contents)

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

