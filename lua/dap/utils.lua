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
---@deprecated
function M.to_dict(values, get_key, get_value)
  if vim.notify_once then
    vim.notify_once("dap.utils.to_dict is deprecated for removal in nvim-dap 0.10.0")
  end
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


---@generic T
---@param items T[]
---@param predicate fun(items: T):boolean
---@result integer?
function M.index_of(items, predicate)
  for i, item in ipairs(items) do
    if predicate(item) then
      return i
    end
  end
  return nil
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
---@param opts? {filter: string|(fun(proc: dap.utils.Proc): boolean)}
---
---@return dap.utils.Proc[]
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




--- Trim a process name to better fit into `columns`
---
---@param name string
---@param columns integer
---@param wordlimit integer
---@return string
local function trim_procname(name, columns, wordlimit)
  if #name <= columns then
    return name
  end

  local function trimpart(part, i)
    if #part <= wordlimit then
      return part
    end
    -- `/usr/bin/cmd` -> `cmd`
    part = part:gsub("(/?[^/]+/)", "")

    -- preserve command name in full length, but trim arguments if they exceed word limit
    if i > 1 and #part > wordlimit then
      return "‥" .. part:sub(#part - wordlimit)
    end
    return part
  end

  -- proc name can include arguments `foo --bar --baz`
  -- trim each element and drop trailing args if still too long
  local i = 0
  local parts = {}
  local len = 0
  for word in name:gmatch("[^%s]+") do
    i = i + 1
    local trimmed = trimpart(word, i)
    len = len + #trimmed
    if i > 1 and len > columns then
      table.insert(parts, "[‥]")
      break
    else
      table.insert(parts, trimmed)
    end
  end
  return i > 0 and table.concat(parts, " ") or trimpart(name, 1)
end

---@private
M._trim_procname = trim_procname


---@class dap.utils.Proc
---@field pid integer
---@field name string

---@class dap.utils.pick_process.Opts
---@field filter? string|fun(proc: dap.utils.Proc):boolean
---@field label? fun(proc: dap.utils.Proc): string
---@field prompt? string

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
--- - label         fun: A function to generate a custom label for the processes.
---                      If not provided, a default label is used.
--- - prompt     string: The title/prompt of pick process select.
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
--- <pre>
--- require("dap.utils").pick_process({
---   label = function(proc) return string.format("Process: %s (PID: %d)", proc.name, proc.pid) end
--- })
--- </pre>
---
---@param opts? dap.utils.pick_process.Opts
function M.pick_process(opts)
  opts = opts or {}
  local cols = math.max(14, math.floor(vim.o.columns * 0.7))
  local wordlimit = math.max(10, math.floor(cols / 3))
  local label_fn = opts.label or function(proc)
    local name = trim_procname(proc.name, cols, wordlimit)
    return string.format("id=%d name=%s", proc.pid, name)
  end
  local procs = M.get_processes(opts)
  local co, ismain = coroutine.running()
  local ui = require("dap.ui")
  local pick = (co and not ismain) and ui.pick_one or ui.pick_one_sync
  local result = pick(procs, opts.prompt or "Select process: ", label_fn)
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


---@generic T
---@param x T?
---@param default T
---@return T
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


--- Split an argument string on whitespace characters into a list,
--- except if the whitespace is contained within single or double quotes.
---
--- Leading and trailing whitespace is removed.
---
--- Examples:
---
--- ```lua
--- require("dap.utils").splitstr("hello world")
--- {"hello", "world"}
--- ```
---
--- ```lua
--- require("dap.utils").splitstr('a "quoted string" is preserved')
--- {"a", "quoted string", "is, "preserved"}
--- ```
---
--- Requires nvim 0.10+
---
--- @param str string
--- @return string[]
function M.splitstr(str)
  local lpeg = vim.lpeg
  local P, S, C = lpeg.P, lpeg.S, lpeg.C

  ---@param quotestr string
  ---@return vim.lpeg.Pattern
  local function qtext(quotestr)
    local quote = P(quotestr)
    local escaped_quote = P('\\') * quote
    return quote * C(((1 - P(quote)) + escaped_quote) ^ 0) * quote
  end
  str = str:match("^%s*(.*%S)")
  if not str or str == "" then
    return {}
  end

  local space = S(" \t\n\r") ^ 1
  local unquoted = C((1 - space) ^ 0)
  local element = qtext('"') + qtext("'") + unquoted
  local p = lpeg.Ct(element * (space * element) ^ 0)
  return lpeg.match(p, str)
end


return M
