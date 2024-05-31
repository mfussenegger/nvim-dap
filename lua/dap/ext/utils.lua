local notify = require('dap.utils').notify
local M = {}


---@class dap.ext.utils.Input
---@field id string
---@field type "promptString"|"pickString"
---@field description string
---@field default? string
---@field options string[]|{label: string, value: string}[]


---@param input dap.ext.utils.Input
---@return function
local function create_input(input)
  if input.type == "promptString" then
    return function()
      local description = input.description or 'Input'
      if not vim.endswith(description, ': ') then
        description = description .. ': '
      end
      if vim.ui.input then
        local co = coroutine.running()
        local opts = {
          prompt = description,
          default = input.default or '',
        }
        vim.ui.input(opts, function(result)
          vim.schedule(function()
            coroutine.resume(co, result)
          end)
        end)
        return coroutine.yield()
      else
        return vim.fn.input(description, input.default or '')
      end
    end
  elseif input.type == "pickString" then
    return function()
      local options = assert(input.options, "input of type pickString must have an `options` property")
      local opts = {
        prompt = input.description,
        format_item = function(x)
          return x.label and x.label or x
        end,
      }
      local co = coroutine.running()
      vim.ui.select(options, opts, function(option)
        vim.schedule(function()
          local value = option and option.value or option
          coroutine.resume(co, value or (input.default or ''))
        end)
      end)
      return coroutine.yield()
    end
  else
    local msg = "Unsupported input type: " .. input.type
    notify(msg, vim.log.levels.WARN)
    return function()
      return "${input:" .. input.id .. "}"
    end
  end
end


---@param inputs dap.ext.utils.Input[]
---@return table<string, function> inputs map from ${input:<id>} to function resolving the input value
local function create_inputs(inputs)
  local result = {}
  for _, input in ipairs(inputs) do
    local id = assert(input.id, "input must have a `id`")
    local key = "${input:" .. id .. "}"
    assert(input.type, "input must have a `type`")
    local fn = create_input(input)
    if fn then
      result[key] = fn
    end
  end
  return result
end


---@param inputs table<string, function>
---@param value any
---@param cache table<string, any>
local function apply_input(inputs, value, cache)
  if type(value) == "table" then
    local new_value = {}
    for k, v in pairs(value) do
      new_value[k] = apply_input(inputs, v, cache)
    end
    value = new_value
  end
  if type(value) ~= "string" then
    return value
  end

  local matches = string.gmatch(value, "${input:([%w_]+)}")
  for input_id in matches do
    local input_key = "${input:" .. input_id .. "}"
    local result = cache[input_key]
    if not result then
      local input = inputs[input_key]
      if not input then
        local msg = "No input with id `" .. input_id .. "` found in inputs"
        notify(msg, vim.log.levels.WARN)
      else
        result = input()
        cache[input_key] = result
      end
    end
    if result then
      value = value:gsub(input_key, result)
    end
  end
  return value
end


---@param config table<string, any>
---@param inputs table<string, function>
local function apply_inputs(config, inputs)
  local result = {}
  local cache = {}
  for key, value in pairs(config) do
    result[key] = apply_input(inputs, value, cache)
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


---@param data table<string, any>
---@return dap.Configuration[]
function M.load_configs(data)
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
    if (has_inputs) then
      config = setmetatable(config, {
        __call = function()
          local c = vim.deepcopy(config)
          return apply_inputs(c, inputs)
        end
      })
    end
    table.insert(configs, config)
  end
  return configs
end

return M
