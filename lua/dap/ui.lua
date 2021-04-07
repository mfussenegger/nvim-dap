local api = vim.api

local M = {}


function M.apply_winopts(win, opts)
  if not opts then return end
  assert(
    type(opts) == 'table',
    'winopts must be a table, not ' .. type(opts) .. ': ' .. vim.inspect(opts)
  )
  for k, v in pairs(opts) do
    if k == 'width' then
      api.nvim_win_set_width(win, v)
    elseif k == 'height' then
      api.nvim_win_set_height(win, v)
    else
      api.nvim_win_set_option(win, k, v)
    end
  end
end


--- Same as M.pick_one except that it skips the selection prompt if `items`
--  contains exactly one item.
function M.pick_if_many(items, prompt, label_fn, cb)
  if #items == 1 then
    cb(items[1])
  else
    M.pick_one(items, prompt, label_fn, cb)
  end
end


function M.pick_one(items, prompt, label_fn, cb)
  local choices = {prompt}
  for i, item in ipairs(items) do
    table.insert(choices, string.format('%d: %s', i, label_fn(item)))
  end
  local choice = vim.fn.inputlist(choices)
  if choice < 1 or choice > #items then
    return cb(nil)
  end
  return cb(items[choice])
end


return M
