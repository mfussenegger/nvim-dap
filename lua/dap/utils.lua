local M = {}


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


function M.non_empty(object)
  if type(object) == "table" then
    return next(object) ~= nil
  end
  return object and #object > 0
end


function M.index_of(items, predicate)
  for i, item in ipairs(items) do
    if predicate(item) then
      return i
    end
  end
end


--- Return running processes as a list with { pid, name } tables.
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
function M.pick_process()
  local label_fn = function(proc)
    return string.format("id=%d name=%s", proc.pid, proc.name)
  end
  local co = coroutine.running()
  if co then
    return coroutine.create(function()
      local procs = M.get_processes()
      require('dap.ui').pick_one(procs, "Select process", label_fn, function(choice)
        coroutine.resume(co, choice and choice.pid or nil)
      end)
    end)
  else
    local procs = M.get_processes()
    local result = require('dap.ui').pick_one_sync(procs, "Select process", label_fn)
    return result and result.pid or nil
  end
end


----- Get a ts compatible range of the current visual selection.
----
---- The range of ts nodes start with 0 and the ending range is exclusive.
function M.visual_selection_range()
  local msg = "dap.utils.visual_selection_range is deprecated for removal in 0.3.0. "
    .. "If you're using it with dap.ui.widgets.hover you no longer need it. "
    .. "See https://github.com/mfussenegger/nvim-dap/pull/621"
  if vim.notify_once then
    vim.notify_once(msg, vim.log.levels.WARN)
  else
    M.notify(msg, vim.log.levels.WARN)
  end
  local _, csrow, cscol, _ = unpack(vim.fn.getpos("'<"))
  local _, cerow, cecol, _ = unpack(vim.fn.getpos("'>"))
  if csrow < cerow or (csrow == cerow and cscol <= cecol) then
    return csrow - 1, cscol - 1, cerow - 1, cecol
  else
    return cerow - 1, cecol - 1, csrow - 1, cscol
  end
end


---- Returns visual selection if it exists or nil
function M.get_visual_selection_text()
  local msg = "dap.utils.get_visual_selection_text is deprecated for removal in 0.3.0. "
    .. "If you're using it with dap.ui.widgets.hover you no longer need it. "
    .. "See https://github.com/mfussenegger/nvim-dap/pull/621"
  if vim.notify_once then
    vim.notify_once(msg, vim.log.levels.WARN)
  else
    M.notify(msg, vim.log.levels.WARN)
  end
  local bufnr = vim.api.nvim_get_current_buf()

  -- We have to remember that end_col is end-exclusive
  local start_row, start_col, end_row, end_col = M.visual_selection_range()

  if start_row ~= end_row then
    local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row+1, false)
    lines[1] = string.sub(lines[1], start_col+1)
    lines[#lines] = string.sub(lines[#lines], 1, end_col)
    return table.concat(lines, '\n')
  else
    local line = vim.api.nvim_buf_get_lines(bufnr, start_row, start_row+1, false)[1]
    -- If line is nil then the line is empty
    return line and table.concat({ string.sub(line, start_col+1, end_col) }, '\n')
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
