local M = {}


---@param err dap.ErrorResponse
---@return string?
function M.fmt_error(err)
  local body = err.body or {}
  if body.error and body.error.showUser then
    local msg = body.error.format
    for key, val in pairs(body.error.variables or {}) do
      msg = msg:gsub('{' .. key .. '}', val)
    end
    return msg
  end
  return err.message
end


-- Group values (a list) into a dictionary.
--  `get_key`   is used to get the key from an element of values
--  `get_value` is used to set the value from an element of values and
--               defaults to the full element
function M.to_dict(values, get_key, get_value)
  local rtn = {}
  get_value = get_value or function(v) return v end
  for _, v in pairs(values or {}) do
    rtn[get_key(v)] = get_value(v)
  end
  return rtn
end


---@param object? table|string
---@return boolean
function M.non_empty(object)
  if type(object) == "table" then
    return next(object) ~= nil
  end
  return object and #object > 0 or false
end


function M.index_of(items, predicate)
  for i, item in ipairs(items) do
    if predicate(item) then
      return i
    end
  end
end


--- Return running processes as a list with { pid, name } tables.
---
---@return {pid: integer, name: string}[]
function M.get_processes()
  local is_windows = vim.fn.has('win32') == 1
  local separator = is_windows and ',' or ' \\+'
  local command = is_windows and {'tasklist', '/nh', '/fo', 'csv'} or {'ps', 'ah'}
  -- output format for `tasklist /nh /fo` csv
  --    '"smss.exe","600","Services","0","1,036 K"'
  -- output format for `ps ah`
  --    " 107021 pts/4    Ss     0:00 /bin/zsh <args>"
  local get_pid = function (parts)
    if is_windows then
      return vim.fn.trim(parts[2], '"')
    else
      return parts[1]
    end
  end

  local get_process_name = function (parts)
    if is_windows then
      return vim.fn.trim(parts[1], '"')
    else
      return table.concat({unpack(parts, 5)}, ' ')
    end
  end

  local output = vim.fn.system(command)
  local lines = vim.split(output, '\n')
  local procs = {}

  local nvim_pid = vim.fn.getpid()
  for _, line in pairs(lines) do
    if line ~= "" then -- tasklist command outputs additional empty line in the end
      local parts = vim.fn.split(vim.fn.trim(line), separator)
      local pid, name = get_pid(parts), get_process_name(parts)
      pid = tonumber(pid)
      if pid and pid ~= nvim_pid then
        table.insert(procs, { pid = pid, name = name })
      end
    end
  end

  return procs
end


--- Show a prompt to select a process pid
--- Requires `ps ah` on Linux/Mac and `tasklist /nh /fo csv` on windows.
--
--- Takes an optional `opts` table with the following options:
---
--- - filter string|fun: A lua pattern or function to filter the processes.
---                      If a function the parameter is a table with
---                      {pid: integer, name: string}
---                      and it must return a boolean.
---                      Matches are included.
---
--- <pre>
--- require("dap.utils").pick_process({ filter = "sway" })
--- </pre>
---
--- <pre>
--- require("dap.utils").pick_process({
---   filter = function(proc) return vim.endswith(proc.name, "sway") end
--- })
--- </pre>
---
---@param opts? {filter: string|(fun(proc: {pid: integer, name: string}): boolean)}
function M.pick_process(opts)
  opts = opts or {}
  local label_fn = function(proc)
    return string.format("id=%d name=%s", proc.pid, proc.name)
  end
  local procs = M.get_processes()
  if opts.filter then
    local filter
    if type(opts.filter) == "string" then
      filter = function(proc)
        return proc.name:find(opts.filter)
      end
    elseif type(opts.filter) == "function" then
      filter = function(proc)
        return opts.filter(proc)
      end
    else
      error("opts.filter must be a string or a function")
    end
    procs = vim.tbl_filter(filter, procs)
  end
  local co = coroutine.running()
  if co then
    return coroutine.create(function()
      require('dap.ui').pick_one(procs, "Select process", label_fn, function(choice)
        coroutine.resume(co, choice and choice.pid or nil)
      end)
    end)
  else
    local result = require('dap.ui').pick_one_sync(procs, "Select process", label_fn)
    return result and result.pid or nil
  end
end


function M.notify(msg, log_level)
  if vim.in_fast_event() then
    vim.schedule(function()
      vim.notify(msg, log_level, {title = 'DAP'})
    end)
  else
    vim.notify(msg, log_level, {title = 'DAP'})
  end
end


function M.if_nil(x, default)
  return x == nil and default or x
end


return M
