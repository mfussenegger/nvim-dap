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


--- Show a prompt to select a process pid
function M.pick_process()
  local output = vim.fn.system({'ps', 'a'})
  local lines = vim.split(output, '\n')
  local procs = {}
  for _, line in pairs(lines) do
    -- output format
    --    " 107021 pts/4    Ss     0:00 /bin/zsh <args>"
    local parts = vim.fn.split(vim.fn.trim(line), ' \\+')
    local pid = parts[1]
    local name = table.concat({unpack(parts, 5)}, ' ')
    if pid and pid ~= 'PID' then
      pid = tonumber(pid)
      if pid ~= vim.fn.getpid() then
        table.insert(procs, { pid = pid, name = name })
      end
    end
  end
  local label_fn = function(proc)
    return string.format("id=%d name=%s", proc.pid, proc.name)
  end
  local result = require('dap.ui').pick_one_sync(procs, "Select process", label_fn)
  return result and result.pid or nil
end


----- Get a ts compatible range of the current visual selection.
----
---- The range of ts nodes start with 0 and the ending range is exclusive.
function M.visual_selection_range()
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
  vim.notify(msg, log_level, {title = 'DAP'})
end


function M.if_nil(x, default)
  return x == nil and default or x
end


return M
