local M = {}


---@param err dap.ErrorResponse
---@return string
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
---
---@return {pid: integer, name: string}[]
function M.get_processes(opts)
  opts = opts or {}
  local is_windows = vim.fn.has('win32') == 1
  local separator = is_windows and ',' or ' \\+'
  local command = is_windows and {'tasklist', '/nh', '/fo', 'csv'} or {'ps', 'ah', '-U', os.getenv("USER")}
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

  return procs
end


--- Show a prompt to select a process pid
--- Requires `ps ah -u $USER` on Linux/Mac and `tasklist /nh /fo csv` on windows.
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
  local procs = M.get_processes(opts)
  local co, ismain = coroutine.running()
  local ui = require("dap.ui")
  local pick = (co and not ismain) and ui.pick_one or ui.pick_one_sync
  local result = pick(procs, "Select process: ", label_fn)
  return result and result.pid or require("dap").ABORT
end


---@param msg string
---@param log_level? integer
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


---@param opts {filter?: string|(fun(name: string):boolean), executables?: boolean}
---@return string[]
local function get_files(path, opts)
  local filter = function(_) return true end
  if opts.filter then
    if type(opts.filter) == "string" then
      filter = function(filepath)
        return filepath:find(opts.filter)
      end
    elseif type(opts.filter) == "function" then
      filter = function(filepath)
        return opts.filter(filepath)
      end
    else
      error('opts.filter must be a string or a function')
    end
  end
  if opts.executables and vim.fs.dir then
    local f = filter
    local uv = vim.uv or vim.loop
    local user_execute = tonumber("00100", 8)
    filter = function(filepath)
      if not f(filepath) then
        return false
      end
      local stat = uv.fs_stat(filepath)
      return stat and bit.band(stat.mode, user_execute) == user_execute or false
    end
  end

  if vim.fs.dir then
    local files = {}
    for name, type in vim.fs.dir(path, { depth = 50 }) do
      if type == "file" then
        local filepath = vim.fs.joinpath(path, name)
        if filter(filepath) then
          table.insert(files, filepath)
        end
      end
    end
    return files
  end


  local cmd = {"find", path, "-type", "f"}
  if opts.executables then
    -- The order of options matters!
    table.insert(cmd, "-executable")
  end
  table.insert(cmd, "-follow")

  local output = vim.fn.system(cmd)
  return vim.tbl_filter(filter, vim.split(output, '\n'))
end


--- Show a prompt to select a file.
--- Returns the path to the selected file.
--- Requires nvim 0.10+ or a `find` executable
---
--- Takes an optional `opts` table with following options:
---
--- - filter string|fun: A lua pattern or function to filter the files.
---                      If a function the parameter is a string and it
---                      must return a boolean. Matches are included.
---
--- - executables boolean: Show only executables. Defaults to true
--- - path string: Path to search for files. Defaults to cwd
---
--- <pre>
--- require('dap.utils').pick_file({ filter = '.*%.py', executables = true })
--- </pre>
---@param opts? {filter?: string|(fun(name: string): boolean), executables?: boolean, path?: string}
---
---@return thread|string|dap.Abort
function M.pick_file(opts)
  opts = opts or {}
  local executables = opts.executables == nil and true or opts.executables
  local path = opts.path or vim.fn.getcwd()
  local files = get_files(path, {
    filter = opts.filter,
    executables = executables
  })
  local prompt = executables and "Select executable: " or "Select file: "
  local co, ismain = coroutine.running()
  local ui = require("dap.ui")
  local pick = (co and not ismain) and ui.pick_one or ui.pick_one_sync

  if not vim.endswith(path, "/") then
    path = path .. "/"
  end

  ---@param abspath string
  ---@return string
  local function relpath(abspath)
    local _, end_ = abspath:find(path)
    return end_ and abspath:sub(end_ + 1) or abspath
  end
  return pick(files, prompt, relpath) or require("dap").ABORT
end


return M
