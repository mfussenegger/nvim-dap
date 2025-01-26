local M = {}

---@type table<string, dap.log.Log>
local loggers = {}

M._loggers = loggers

---@enum dap.log.Level
M.levels = {
  TRACE = 0,
  DEBUG = 1,
  INFO  = 2,
  WARN  = 3,
  ERROR = 4,
}

local log_date_format = "!%F %H:%M:%S"


---@class dap.log.Log
---@field _fname string
---@field _path string
---@field _file file*?
---@field _level dap.log.Level


---@class dap.log.Log
local Log = {}
local log_mt = {
  __index = Log
}


function Log:write(...)
  self:open()
  self._file:write(...)
end

function Log:open()
  if not self._file then
    local f = assert(io.open(self._path, "w+"))
    self._file = f
  end
end

---@param level dap.log.Level|string
function Log:set_level(level)
  if type(level) == "string" then
    self._level = assert(
      M.levels[tostring(level):upper()],
      string.format('Log level must be one of (trace, debug, info, warn, error), got: %q', level)
    )
  else
    self._level = level
  end
end

function Log:get_path()
  return self._path
end


function Log:close()
  if self._file then
    self._file:flush()
    self._file:close()
    self._file = nil
  end
end

function Log:remove()
  self:close()
  os.remove(self._path)
  loggers[self._fname] = nil
end


---@param level string
---@param levelnr integer
---@return boolean
function Log:_log(level, levelnr, ...)
  local argc = select('#', ...)
  if levelnr < self._level then
    return false
  end
  if argc == 0 then
    return true
  end
  local info = debug.getinfo(3, 'Sl')
  local _, end_ = info.short_src:find("nvim-dap/lua", 1, true)
  local src = end_ and info.short_src:sub(end_ + 2) or info.short_src
  local fileinfo = string.format('%s:%s', src, info.currentline)
  local parts = {
    table.concat({'[', level, '] ', os.date(log_date_format), ' ', fileinfo}, '')
  }
  for i = 1, argc do
    local arg = select(i, ...)
    if arg == nil then
      table.insert(parts, "nil")
    else
      table.insert(parts, vim.inspect(arg))
    end
  end
  self:write(table.concat(parts, '\t'), '\n')
  return true
end



--- Not generating methods below in a loop to help out luals


function Log:trace(...)
  self:_log("TRACE", M.levels.TRACE, ...)
end

function Log:debug(...)
  self:_log("DEBUG", M.levels.DEBUG, ...)
end

function Log:info(...)
  self:_log("INFO", M.levels.INFO, ...)
end

function Log:warn(...)
  self:_log("WARN", M.levels.WARN, ...)
end

function Log:error(...)
  self:_log("ERROR", M.levels.ERROR, ...)
end


---@param fname string
---@return string path
---@return string cache_dir
local function getpath(fname)
  local path_sep = vim.loop.os_uname().sysname == "Windows" and "\\" or "/"
  local joinpath = (vim.fs or {}).joinpath or function(...)
    ---@diagnostic disable-next-line: deprecated
    return table.concat(vim.tbl_flatten{...}, path_sep)
  end
  local cache_dir = vim.fn.stdpath('cache')
  assert(type(cache_dir) == "string")
  return joinpath(cache_dir, fname), cache_dir
end


---@return dap.log.Log
function M.create_logger(filename)
  local logger = loggers[filename]
  if logger then
    logger:open()
    return logger
  end
  local path, cache_dir = getpath(filename)
  local log = {
    _fname = filename,
    _path = path,
    _level = M.levels.INFO
  }
  logger = setmetatable(log, log_mt)
  loggers[filename] = logger

  vim.fn.mkdir(cache_dir, "p")
  logger:open()
  return logger
end


return M
