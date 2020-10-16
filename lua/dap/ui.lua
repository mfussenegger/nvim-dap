local M = {}


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
