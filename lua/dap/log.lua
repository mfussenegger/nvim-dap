-- Similar to lsp/log.lua in neovim,
-- but allows to create multiple loggers with different filenames each

local M = {}
local loggers = {}

M.levels = {
  TRACE = 0;
  DEBUG = 1;
  INFO  = 2;
  WARN  = 3;
  ERROR = 4;
}

local log_date_format = "%FT%H:%M:%SZ%z"

function M.create_logger(filename)
  local logger = loggers[filename]
  if logger then
    return logger
  end
  logger = {}
  loggers[filename] = logger

  local path_sep = vim.loop.os_uname().sysname == "Windows" and "\\" or "/"
  local function path_join(...)
    return table.concat(vim.tbl_flatten{...}, path_sep)
  end
  local logfilename = path_join(vim.fn.stdpath('cache'), filename)

  local current_log_level = M.levels.INFO

  function logger.set_level(level)
    current_log_level = assert(
      M.levels[tostring(level):upper()],
      string.format('Log level must be one of (trace, debug, info, warn, error), got: %q', level)
    )
  end

  function logger.get_filename()
    return logfilename
  end

  vim.fn.mkdir(vim.fn.stdpath('cache'), "p")
  local logfile = assert(io.open(logfilename, "a+"))
  for level, levelnr in pairs(M.levels) do
    logger[level:lower()] = function(...)
      local argc = select('#', ...)
      if levelnr < current_log_level then
        return false
      end
      if argc == 0 then
        return true
      end
      local info = debug.getinfo(2, 'Sl')
      local fileinfo = string.format('%s:%s', info.short_src, info.currentline)
      local parts = {
        table.concat({'[', level, ']', os.date(log_date_format), ']', fileinfo, ']'}, ' ')
      }
      for i = 1, argc do
        local arg = select(i, ...)
        if arg == nil then
          table.insert(parts, "nil")
        else
          table.insert(parts, vim.inspect(arg))
        end
      end
      logfile:write(table.concat(parts, '\t'), '\n')
      logfile:flush()
    end
  end
  logfile:write('\n')
  return logger
end

return M
