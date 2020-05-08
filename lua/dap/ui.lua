local M = {}


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
