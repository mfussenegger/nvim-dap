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


do
  function M.get_last_line(bufnr)
    return api.nvim_buf_call(bufnr, function() return vim.fn.line('$') - 1 end)
  end

  function M.layer(buf)
    assert(buf, 'Need a buffer to operate on')
    local marks = {}
    local ns = api.nvim_create_namespace('dap.ui_layer_' .. buf)
    return {
      __marks = marks,
      --- Render the items and associate each item to the rendered line
      -- The item and context can then be retrieved using `.get(lnum)`
      --
      -- lines between start and end_ are replaced
      -- If start == end_, new lines are inserted at the given position
      -- If start == nil, appends to the end of the buffer
      --
      -- start is 0-indexed
      -- end_ is 0-indexed exclusive
      render = function(xs, render_fn, context, start, end_)
        start = start or M.get_last_line(buf)
        end_ = end_ or start
        if end_ > start then
          local extmarks = api.nvim_buf_get_extmarks(buf, ns, {start, 0}, {end_ - 1, -1}, {})
          for _, mark in pairs(extmarks) do
            local mark_id = mark[1]
            marks[mark_id] = nil
            api.nvim_buf_del_extmark(buf, ns, mark_id)
          end
        end
        local lines = vim.tbl_map(render_fn, xs)
        api.nvim_buf_set_lines(buf, start, end_, true, lines)
        for i = start, start + #lines - 1 do
          local line = api.nvim_buf_get_lines(buf, i, i + 1, true)[1]
          local mark_id = api.nvim_buf_set_extmark(buf, ns, i, 0, {end_col=(#line - 1)})
          marks[mark_id] = { mark_id = mark_id, item = xs[i + 1 - start], context = context }
        end
      end,

      --- Get the information associated with a line
      --
      -- lnum is 0-indexed
      get = function(lnum, start_col, end_col)
        local line = api.nvim_buf_get_lines(buf, lnum, lnum + 1, true)[1]
        start_col = start_col or 0
        end_col = end_col or #line
        local start = {lnum, start_col}
        local end_ = {lnum, end_col}
        local extmarks = api.nvim_buf_get_extmarks(buf, ns, start, end_, {})
        if not extmarks or #extmarks == 0 then
          return
        end
        assert(#extmarks == 1, 'Expecting only a single mark per line and region: ' .. vim.inspect(extmarks))
        local extmark = extmarks[1]
        return marks[extmark[1]]
      end
    }
  end
end


return M
