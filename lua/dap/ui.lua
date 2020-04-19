local api = vim.api
local M = {}
local winid = nil
local bufnr = nil

local function new_win()
  vim.cmd("belowright new")
  winid = vim.fn.win_getid()
  api.nvim_win_set_var(0, '[dap-threads]', 1)
  bufnr = api.nvim_get_current_buf()
  api.nvim_buf_set_option(bufnr, 'buftype', 'nofile')
  api.nvim_buf_set_option(bufnr, 'bufhidden', 'wipe')
  api.nvim_buf_set_option(bufnr, 'buflisted', false)
  api.nvim_buf_set_option(bufnr, 'swapfile', false)
  api.nvim_buf_set_name(bufnr, '[dap-threads]')
  api.nvim_buf_attach(bufnr, false, {
    on_detach = function(_)
      winid = nil
      bufnr = nil
    end;
  })
end


function M.threads_render(threads)
  if not winid then
    new_win()
  end
  local indent = 0
  local lines = {}
  for _, thread in pairs(threads) do
    table.insert(lines, 'Thread ' .. thread.name)
    indent = indent + 4
    for _, frame in pairs(thread.frames or {}) do
      table.insert(lines, string.rep(' ', indent) .. frame.name)
      for _, scope in pairs(frame.scopes or {}) do
        table.insert(lines, string.rep(' ', indent) .. scope.name)

        indent = indent + 4
        for _, variable in pairs(scope.variables or {}) do
          table.insert(
            lines,
            string.format('%s%s: %s',
              string.rep(' ', indent),
              variable.name,
              variable.value
            )
          )
        end
        indent = indent - 4
      end
    end
    indent = indent - 4
  end
  api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end


function M.threads_clear()
  if not winid then
    return
  end
  api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
end


function M.pick_one(items, prompt, label_fn)
  if not items or #items == 0 then
    return nil
  end
  if #items == 1 then
    return items[1]
  end
  local choices = {prompt}
  for i, item in ipairs(items) do
    table.insert(choices, string.format('%d: %s', i, label_fn(item)))
  end
  local choice = vim.fn.inputlist(choices)
  if choice < 1 or choice > #items then
    return nil
  end
  return items[choice]
end


return M
