local dap = require('dap')
local notify = require('dap.utils').notify
local M = {}

M.json_decode = vim.json.decode
M.type_to_filetypes = {}


---@class dap.vscode.launch.Input
---@field id string
---@field type "promptString"|"pickString"
---@field description string
---@field default? string
---@field options string[]|{label: string, value: string}[]


---@param input dap.vscode.launch.Input
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
    local msg = "Unsupported input type in vscode launch.json: " .. input.type
    notify(msg, vim.log.levels.WARN)
    return function()
      return "${input:" .. input.id .. "}"
    end
  end
end


---@param inputs dap.vscode.launch.Input[]
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


function M._load_json(jsonstr)
  local ok, data = pcall(M.json_decode, jsonstr)
  if not ok then
    error("Error parsing launch.json: " .. data)
  end
  assert(type(data) == "table", "launch.json must contain a JSON object")
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
  return M._load_json(contents)
end


--- Extends dap.configurations with entries read from .vscode/launch.json
---@deprecated
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
