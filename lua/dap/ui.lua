local api = vim.api
local utils = require('dap.utils')
local if_nil = utils.if_nil
local M = {}


---@param win integer
---@param opts table<string, any>?
function M.apply_winopts(win, opts)
  if not opts then
    return
  end
  assert(
    type(opts) == 'table',
    'winopts must be a table, not ' .. type(opts) .. ': ' .. vim.inspect(opts)
  )
  for k, v in pairs(opts) do
    if k == 'width' then
      api.nvim_win_set_width(win, v)
    elseif k == 'height' then
      api.nvim_win_set_height(win, v)
    elseif vim.tbl_contains({ 'border', 'title' }, k) then
      api.nvim_win_set_config(win, {[k]=v})
    else
      vim.wo[win][k] = v
    end
  end
end


--- Same as M.pick_one except that it skips the selection prompt if `items`
--  contains exactly one item.
function M.pick_if_many(items, prompt, label_fn, cb)
  if #items == 1 then
    if not cb then
      return items[1]
    else
      cb(items[1])
    end
  else
    return M.pick_one(items, prompt, label_fn, cb)
  end
end


function M.pick_one_sync(items, prompt, label_fn)
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


function M.pick_one(items, prompt, label_fn, cb)
  local co
  if not cb then
    co = coroutine.running()
    if co then
      cb = function(item)
        coroutine.resume(co, item)
      end
    end
  end
  cb = vim.schedule_wrap(cb)
  if vim.ui then
    vim.ui.select(items, {
      prompt = prompt,
      format_item = label_fn,
    }, cb)
  else
    local result = M.pick_one_sync(items, prompt, label_fn)
    cb(result)
  end
  if co then
    return coroutine.yield()
  end
end


local function with_indent(indent, fn)
  local move_cols = function(hl_group)
    local end_col = hl_group[3] == -1 and -1 or hl_group[3] + indent
    return {hl_group[1], hl_group[2] + indent, end_col}
  end
  return function(...)
    local text, hl_groups = fn(...)
    return string.rep(' ', indent) .. text, vim.tbl_map(move_cols, hl_groups or {})
  end
end


function M.new_tree(opts)
  assert(opts.render_parent, 'opts for tree requires a `render_parent` function')
  assert(opts.get_children, 'opts for tree requires a `get_children` function')
  assert(opts.has_children, 'opts for tree requires a `has_children` function')
  local get_key = opts.get_key or function(x) return x end
  opts.fetch_children = opts.fetch_children or function(item, cb)
    cb(opts.get_children(item))
  end
  opts.render_child = opts.render_child or opts.render_parent
  local compute_actions = opts.compute_actions or function() return {} end
  local extra_context = opts.extra_context or {}
  local implicit_expand_action = if_nil(opts.implicit_expand_action, true)
  local is_lazy = opts.is_lazy or function(_) return false end
  local load_value = opts.load_value or function(_, _) assert(false, "load_value not implemented") end

  local self  -- forward reference

  -- tree supports to re-draw with new data while retaining previously
  -- expansion information.
  --
  -- Since the data is completely changed, the expansion information must be
  -- held separately.
  --
  -- The structure must supports constructs like this:
  --
  --         root
  --       /     \
  --      a      b
  --     /       \
  --    x        x
  --   / \
  --  aa bb
  --
  -- It must be possible to distinguish the two `x`
  -- This assumes that `get_key` within a level is unique and that it is
  -- deterministic between two `render` operations.
  local expanded_root = {}

  local function get_expanded(item)
    local ancestors = {}
    local parent = item
    while true do
      parent = parent.__parent
      if parent then
        table.insert(ancestors, parent.key)
      else
        break
      end
    end
    local expanded = expanded_root
    for i = #ancestors, 1, -1 do
      local parent_expanded = expanded[ancestors[i]]
      if parent_expanded then
        expanded = parent_expanded
      else
        break
      end
    end
    return expanded
  end

  local function set_expanded(item, value)
    local expanded = get_expanded(item)
    expanded[get_key(item)] = value
  end

  local function is_expanded(item)
    local expanded = get_expanded(item)
    return expanded[get_key(item)] ~= nil
  end

  local expand = function(layer, value, lnum, context)
    set_expanded(value, {})
    opts.fetch_children(value, function(children)
      local ctx = {
        actions = context.actions,
        indent = context.indent + 2,
        compute_actions = context.compute_actions,
        tree = self,
      }
      ctx = vim.tbl_deep_extend('keep', ctx, extra_context)
      for _, child in pairs(children) do
        if opts.has_children(child) then
          child.__parent = { key = get_key(value), __parent = value.__parent }
        end
      end
      local render = with_indent(ctx.indent, opts.render_child)
      layer.render(children, render, ctx, lnum + 1)
    end)
  end

  local function eager_fetch_expanded_children(value, cb, ctx)
    ctx = ctx or { to_traverse = 1 }
    opts.fetch_children(value, function(children)
      ctx.to_traverse = ctx.to_traverse + #children
      for _, child in pairs(children) do
        if opts.has_children(child) then
          child.__parent = { key = get_key(value), __parent = value.__parent }
        end
        if is_expanded(child) then
          eager_fetch_expanded_children(child, cb, ctx)
        else
          ctx.to_traverse = ctx.to_traverse - 1
        end
      end
      ctx.to_traverse = ctx.to_traverse - 1
      if ctx.to_traverse == 0 then
        cb()
      end
    end)
  end

  local function render_all_expanded(layer, value, indent)
    indent = indent or 2
    local context = {
      actions = implicit_expand_action and { { label ='Expand', fn = self.toggle, }, } or {},
      indent = indent,
      compute_actions = compute_actions,
      tree = self,
    }
    context = vim.tbl_deep_extend('keep', context, extra_context)
    for _, child in pairs(opts.get_children(value)) do
      layer.render({child}, with_indent(indent, opts.render_child), context)
      if is_expanded(child) then
        render_all_expanded(layer, child, indent + 2)
      end
    end
  end

  local collapse = function(layer, value, lnum, context)
    if not is_expanded(value) then
      return
    end
    local num_vars = 1
    local collapse_child
    collapse_child = function(parent)
      num_vars = num_vars + 1
      if is_expanded(parent) then
        for _, child in pairs(opts.get_children(parent)) do
          collapse_child(child)
        end
        set_expanded(parent, nil)
      end
    end
    for _, child in ipairs(opts.get_children(value)) do
      collapse_child(child)
    end
    set_expanded(value, nil)
    layer.render({}, tostring, context, lnum + 1, lnum + num_vars)
  end

  self = {
    toggle = function(layer, value, lnum, context)
      if is_lazy(value) then
        load_value(value, function(var)
          local render = with_indent(context.indent, opts.render_child)
          layer.render({var}, render, context, lnum, lnum + 1)
        end)
      elseif is_expanded(value) then
        collapse(layer, value, lnum, context)
      elseif opts.has_children(value) then
        expand(layer, value, lnum, context)
      else
        utils.notify("No children on line " .. tostring(lnum) .. ". Can't expand", vim.log.levels.INFO)
      end
    end,

    render = function(layer, value, on_done, lnum, end_)
      layer.render({value}, opts.render_parent, nil, lnum, end_)
      if not opts.has_children(value) then
        if on_done then
          on_done()
        end
        return
      end
      if not is_expanded(value) then
        set_expanded(value, {})
      end
      eager_fetch_expanded_children(value, function()
        render_all_expanded(layer, value)
        if on_done then
          on_done()
        end
      end)
    end,
  }
  return self
end


--- Create a view that can be opened, closed and toggled.
--
-- The view manages a single buffer and a single window. Both are created when
-- the view is opened and destroyed when the view is closed.
--
-- Arguments passed to `view.open()` are forwarded to the `new_win` function
--
-- @param new_buf (view -> number): function to create a new buffer. Must return the bufnr
-- @param new_win (-> number): function to create a new window. Must return the winnr
-- @param opts A dictionary with `before_open` and `after_open` hooks.
function M.new_view(new_buf, new_win, opts)
  assert(new_buf, 'new_buf must not be nil')
  assert(new_win, 'new_win must not be nil')
  opts = opts or {}
  local self
  self = {
    buf = nil,
    win = nil,

    toggle = function(...)
      if not self.close({ mode = 'toggle' }) then
        self.open(...)
      end
    end,

    close = function(close_opts)
      close_opts = close_opts or {}
      local closed = false
      local win = self.win
      local buf = self.buf
      if win and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf then
        api.nvim_win_close(win, true)
        self.win = nil
        closed = true
      end
      local hide = close_opts.mode == 'toggle'
      if buf and not hide then
        pcall(api.nvim_buf_delete, buf, {force=true})
        self.buf = nil
      end
      return closed
    end,

    ---@return integer
    _init_buf = function()
      if self.buf then
        return self.buf
      end
      local buf = new_buf(self)
      assert(buf, 'The `new_buf` function is supposed to return a buffer')
      api.nvim_buf_attach(buf, false, { on_detach = function() self.buf = nil end })
      self.buf = buf
      return buf
    end,

    open = function(...)
      local win = self.win
      local before_open_result
      if opts.before_open then
        before_open_result = opts.before_open(self, ...)
      end
      local buf = self._init_buf()
      if not win or not api.nvim_win_is_valid(win) then
        win = new_win(buf, ...)
      end
      api.nvim_win_set_buf(win, buf)

      -- Trigger filetype again to ensure ftplugin files can change window settings
      local ft = vim.bo[buf].filetype
      vim.bo[buf].filetype = ft

      self.buf = buf
      self.win = win
      if opts.after_open then
        opts.after_open(self, before_open_result, ...)
      end
      return buf, win
    end
  }
  return self
end


function M.trigger_actions(opts)
  opts = opts or {}
  local buf = api.nvim_get_current_buf()
  local layer = M.get_layer(buf)
  if not layer then return end
  local lnum, col = unpack(api.nvim_win_get_cursor(0))
  lnum = lnum - 1
  local info = layer.get(lnum, 0, col) or {}
  local context = info.context or {}
  local actions = {}
  vim.list_extend(actions, context.actions or {})
  if context.compute_actions then
    vim.list_extend(actions, context.compute_actions(info))
  end
  if opts.filter then
    local filter = (type(opts.filter) == 'function'
      and opts.filter
      or function(x) return x.label == opts.filter end
    )
    actions = vim.tbl_filter(filter, actions)
  end
  if #actions == 0 then
    utils.notify('No action possible on: ' .. api.nvim_buf_get_lines(buf, lnum, lnum + 1, true)[1], vim.log.levels.INFO)
    return
  end
  if opts.mode == 'first' then
    local action = actions[1]
    action.fn(layer, info.item, lnum, info.context)
    return
  end
  M.pick_if_many(
    actions,
    'Actions> ',
    function(x) return type(x.label) == 'string' and x.label or x.label(info.item) end,
    function(action)
      if action then
        action.fn(layer, info.item, lnum, info.context)
      end
    end
  )
end


---@type table<number, dap.ui.Layer>
local layers = {}

--- Return an existing layer
---
---@param buf integer
---@return nil|dap.ui.Layer
function M.get_layer(buf)
  return layers[buf]
end

---@class dap.ui.LineInfo
---@field mark_id number
---@field item any
---@field context table|nil


---@param buf integer
local function line_count(buf)
  if vim.bo[buf].buftype ~= "prompt" then
    return api.nvim_buf_line_count(buf)
  end
  if vim.fn.has("nvim-0.12") == 1 then
    local ok, mark = pcall(api.nvim_buf_get_mark, buf, ":")
    if ok then
      return mark[1] - 1
    end
  end
  return api.nvim_buf_line_count(buf) - 1
end

--- Returns a layer, creating it if it's missing.
---@param buf integer
---@return dap.ui.Layer
function M.layer(buf)
  assert(buf, 'Need a buffer to operate on')
  local layer = layers[buf]
  if layer then
    return layer
  end

  ---@type table<number, dap.ui.LineInfo>
  local marks = {}
  local ns = api.nvim_create_namespace('dap.ui_layer_' .. buf)
  local nshl = api.nvim_create_namespace('dap.ui_layer_hl_' .. buf)
  local remove_marks = function(extmarks)
    for _, mark in pairs(extmarks) do
      local mark_id = mark[1]
      marks[mark_id] = nil
      api.nvim_buf_del_extmark(buf, ns, mark_id)
    end
  end

  ---@class dap.ui.Layer
  layer = {
    buf = buf,
    __marks = marks,

    --- Render the items and associate each item to the rendered line
    ---  The item and context can then be retrieved using `.get(lnum)`
    ---
    ---  lines between start and end_ are replaced
    ---  If start == end_, new lines are inserted at the given position
    ---  If start == nil, appends to the end of the buffer
    ---
    ---@generic T
    ---@param xs T[]
    ---@param render_fn? fun(T):string
    ---@param context table|nil
    ---@param start nil|number 0-indexed
    ---@param end_ nil|number 0-indexed exclusive
    render = function(xs, render_fn, context, start, end_)
      if not api.nvim_buf_is_valid(buf) then
        return
      end
      local modifiable = vim.bo[buf].modifiable
      vim.bo[buf].modifiable = true
      if not start and not end_ then
        start = line_count(buf)
        -- Avoid inserting a new line at the end of the buffer
        -- The case of no lines and one empty line are ambiguous;
        -- set_lines(buf, 0, 0) would "preserve" the "empty buffer line" while set_lines(buf, 0, -1) replaces it
        -- Need to use regular end_ = start in other cases to support injecting lines in all other cases
        if start == 1 and (api.nvim_buf_get_lines(buf, 0, -1, true))[1] == "" then
          start = 0
          end_ = -1
        else
          end_ = start
        end
      else
        start = start or (line_count(buf) - 1)
        end_ = end_ or start
      end
      render_fn = render_fn or tostring
      if end_ > start then
        remove_marks(api.nvim_buf_get_extmarks(buf, ns, {start, 0}, {end_ - 1, -1}, {}))
      elseif end_ == -1 then
        remove_marks(api.nvim_buf_get_extmarks(buf, ns, {start, 0}, {-1, -1}, {}))
      end
      -- This is a dummy call to insert new lines in a region
      -- the loop below will add the actual values
      local lines = vim.tbl_map(function() return '' end, xs)
      api.nvim_buf_set_lines(buf, start, end_, true, lines)
      if start == -1 then
        start = line_count(buf) - #lines
      end

      for i = start, start + #lines - 1 do
        local item = xs[i + 1 - start]
        local text, hl_regions = render_fn(item)
        if not text then
          local debuginfo = debug.getinfo(render_fn)
          error(('render function must return a string, got nil instead. render_fn: '
            .. debuginfo.short_src .. ':' .. debuginfo.linedefined
            .. ' '
            .. vim.inspect(xs)
          ))
        end
        text = text:gsub('\n', '\\n')
        api.nvim_buf_set_lines(buf, i, i + 1, true, {text})
        if hl_regions then
          for _, hl_region in pairs(hl_regions) do
            api.nvim_buf_add_highlight(
              buf, nshl, hl_region[1], i, hl_region[2], hl_region[3])
          end
        end

        local end_col = math.max(0, #text - 1)
        local mark_id = api.nvim_buf_set_extmark(buf, ns, i, 0, {end_col=end_col})
        marks[mark_id] = { mark_id = mark_id, item = item, context = context }
      end
      vim.bo[buf].modifiable = modifiable
    end,

    --- Get the information associated with a line
    ---
    ---@param lnum number 0-indexed line number
    ---@param start_col nil|number
    ---@param end_col nil|number
    ---@return nil|dap.ui.LineInfo
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
  layers[buf] = layer
  api.nvim_buf_attach(buf, false, { on_detach = function(_, b) layers[b] = nil end })
  return layer
end


return M
