local ui = require('dap.ui')
local utils = require('dap.utils')
local api = vim.api
local M = {}


local function set_default_bufopts(buf)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  api.nvim_buf_set_keymap(
    buf, "n", "<CR>", "<Cmd>lua require('dap.ui').trigger_actions({ mode = 'first' })<CR>", {})
  api.nvim_buf_set_keymap(
    buf, "n", "a", "<Cmd>lua require('dap.ui').trigger_actions()<CR>", {})
  api.nvim_buf_set_keymap(
    buf, "n", "o", "<Cmd>lua require('dap.ui').trigger_actions()<CR>", {})
  api.nvim_buf_set_keymap(
    buf, "n", "<2-LeftMouse>", "<Cmd>lua require('dap.ui').trigger_actions()<CR>", {})
end


local function new_buf()
  local buf = api.nvim_create_buf(false, true)
  set_default_bufopts(buf)
  return buf
end


function M.new_cursor_anchored_float_win(buf)
  vim.bo[buf].bufhidden = "wipe"
  local border = vim.fn.exists('&winborder') == 1 and vim.o.winborder or 'single'
  local opts = vim.lsp.util.make_floating_popup_options(50, 30, {border = border})
  local win = api.nvim_open_win(buf, true, opts)
  if vim.fn.has("nvim-0.11") == 1 then
    vim.wo[win][0].scrolloff = 0
    vim.wo[win][0].wrap = false
  else
    vim.wo[win].scrolloff = 0
    vim.wo[win].wrap = false
  end
  vim.bo[buf].filetype = "dap-float"
  return win
end


function M.new_centered_float_win(buf)
  vim.bo[buf].bufhidden = "wipe"
  local columns = vim.o.columns
  local lines = vim.o.lines
  local width = math.floor(columns * 0.9)
  local height = math.floor(lines * 0.8)
  local border = vim.fn.exists('&winborder') == 1 and vim.o.winborder or 'single'
  local opts = {
    relative = 'editor',
    style = 'minimal',
    row = math.floor((lines - height) * 0.5),
    col = math.floor((columns - width) * 0.5),
    width = width,
    height = height,
    border = border,
  }
  local win = api.nvim_open_win(buf, true, opts)
  if vim.fn.has("nvim-0.11") == 1 then
    vim.wo[win][0].scrolloff = 0
    vim.wo[win][0].wrap = false
  else
    vim.wo[win].scrolloff = 0
    vim.wo[win].wrap = false
  end
  vim.bo[buf].filetype = "dap-float"
  return win
end


local function with_winopts(new_win, winopts)
  return function(...)
    local win = new_win(...)
    ui.apply_winopts(win, winopts)
    return win
  end
end


local function mk_sidebar_win_func(winopts, wincmd)
  return function()
    vim.cmd(wincmd or '30 vsplit')
    local win = api.nvim_get_current_win()
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].statusline = ' '
    ui.apply_winopts(win, winopts)
    return win
  end
end


--- Decorates a `new_win` function, adding a hook that will cause the window to
-- be resized if the content changes.
function M.with_resize(new_win)
  return setmetatable({resize=true}, {
    __call = function(_, buf)
      return new_win(buf)
    end
  })
end


local function resize_window(win, buf)
  if not api.nvim_win_is_valid(win) then
    -- Could happen if the user moves the buffer into a new window
    return
  end
  local lines = api.nvim_buf_get_lines(buf, 0, -1, true)
  local width = 0
  local height = #lines
  for _, line in pairs(lines) do
    width = math.max(width, #line)
  end
  local columns = vim.o.columns
  local max_win_width = math.floor(columns * 0.9)
  width = math.min(width, max_win_width)
  local max_win_height = vim.o.lines
  height = math.min(height, max_win_height)
  api.nvim_win_set_width(win, width)
  api.nvim_win_set_height(win, height)
end


local function resizing_layer(win, buf)
  local layer = ui.layer(buf)
  local orig_render = layer.render
  ---@diagnostic disable-next-line: inject-field
  layer.render = function(...)
    orig_render(...)
    if api.nvim_win_is_valid(win) and api.nvim_win_get_config(win).relative ~= '' then
      resize_window(win, buf)
    end
  end
  return layer
end


M.scopes = {
  refresh_listener = 'scopes',
  new_buf = function(view)
    local dap = require('dap')
    local function reset_tree()
      view.tree = nil
    end
    dap.listeners.after['event_terminated'][view] = reset_tree
    dap.listeners.after['event_exited'][view] = reset_tree
    local buf = new_buf()
    api.nvim_create_autocmd("TextYankPost", {
      buffer = buf,
      callback = function()
        require("dap._cmds").yank_evalname()
      end,
    })
    vim.bo[buf].tagfunc = "v:lua.require'dap'._tagfunc"
    api.nvim_buf_attach(buf, false, {
      on_detach = function()
        dap.listeners.after['event_terminated'][view] = nil
        dap.listeners.after['event_exited'][view] = nil
      end
    })
    api.nvim_buf_set_name(buf, 'dap-scopes-' .. tostring(buf))
    return buf
  end,
  render = function(view)
    local session = require('dap').session()
    local frame = session and session.current_frame or {}
    local tree = view.tree
    if not tree then
      local spec = vim.deepcopy(require('dap.entity').scope.tree_spec)
      spec.extra_context = { view = view }
      tree = ui.new_tree(spec)
      view.tree = tree
    end
    local layer = view.layer()
    local scopes = frame.scopes or {}
    local render
    render = function(idx, scope, replace)
      if not scope then
        return
      end

      tree.render(layer, scope, function()
        render(next(scopes, idx))
      end, replace and 0 or nil, replace and -1 or nil)
    end
    local idx, scope = next(scopes)
    render(idx, scope, true)
  end,
}


M.threads = {
  refresh_listener = 'event_thread',
  new_buf = function()
    local buf = new_buf()
    api.nvim_buf_set_name(buf, 'dap-threads-' .. tostring(buf))
    return buf
  end,
  render = function(view)
    local layer = view.layer()
    local session = require('dap').session()
    if not session then
      layer.render({'No active session'})
      return
    end

    ---@diagnostic disable-next-line: invisible
    if session.dirty.threads then
      session:update_threads(function()
        M.threads.render(view)
      end)
      return
    end

    local tree = view.tree
    if not tree then
      local spec = vim.deepcopy(require('dap.entity').threads.tree_spec)
      spec.extra_context = {
        view = view,
        refresh = view.refresh,
      }
      tree = ui.new_tree(spec)
      view.tree = tree
    end

    local root = {
      id = 0,
      name = 'Threads',
      threads = vim.tbl_values(session.threads)
    }
    tree.render(layer, root)
  end,
}


M.frames = {
  refresh_listener = 'scopes',
  new_buf = function()
    local buf = new_buf()
    api.nvim_buf_set_name(buf, 'dap-frames-' .. tostring(buf))
    return buf
  end,
  render = function(view)
    local session = require('dap').session()
    local layer = view.layer()
    if not session then
      layer.render({'No active session'})
      return
    end
    if not session.stopped_thread_id then
      layer.render({'Not stopped at any breakpoint. No frames available'})
      return
    end
    local thread = session.threads[session.stopped_thread_id]
    if not thread then
      local msg = string.format("Stopped thread (%d) not found. Can't display frames", session.stopped_thread_id)
      layer.render({msg})
      return
    end

    local frames = thread.frames
    require("dap.async").run(function()
      if not frames then
        local err, response = session:request("stackTrace", { threadId = thread.id })
        ---@cast response dap.StackTraceResponse
        if err or not response then
          layer.render({"Stopped thread has no frames"})
          return
        end
        frames = response.stackFrames
      end
      local context = {}
      context.actions = {
        {
          label = "Jump to frame",
          fn = function(_, frame)
            if session then
              local close = vim.bo.bufhidden == "wipe"
              session:_frame_set(frame)
              if close then
                view.close()
              end
            else
              utils.notify('Cannot navigate to frame without active session', vim.log.levels.INFO)
            end
          end
        },
      }
      local render_frame = require('dap.entity').frames.render_item
      layer.render(frames, render_frame, context)
    end)
  end
}


M.sessions = {
  refresh_listener = {
    'event_initialized',
    'event_terminated',
    'disconnect',
    'event_stopped'
  },
  new_buf = function()
    local buf = new_buf()
    api.nvim_buf_set_name(buf, 'dap-sessions-' .. tostring(buf))
    return buf
  end,
  render = function(view)
    local dap = require('dap')
    local sessions = dap.sessions()
    local layer = view.layer()
    local lsessions = {}

    local add
    add = function(s)
      table.insert(lsessions, s)
      for _, child in pairs(s.children) do
        add(child)
      end
    end
    for _, s in pairs(sessions) do
      add(s)
    end
    local context = {}
    context.actions = {
      {
        label = "Focus session",
        fn = function(_, s)
          local close = vim.bo.bufhidden == "wipe"
          if s then
            dap.set_session(s)
            view.refresh()
          end
          if close then
            view.close()
          end
        end
      }
    }
    local focused = dap.session()
    local render_session = function(s)
      local text = s.id .. ': ' .. s.config.name
      local parent = s.parent
      local num_parents = 0
      while parent ~= nil do
        parent = parent.parent
        num_parents = num_parents + 1
      end
      local prefix
      if focused and s.id == focused.id then
        prefix = "→ "
      else
        prefix = "  "
      end
      return prefix .. string.rep("  ", num_parents) .. text
    end
    layer.render({}, tostring, nil, 0, -1)
    layer.render(lsessions, render_session, context)
  end,
}


do

  ---@param scopes dap.Scope[]
  ---@param expression string
  ---@return dap.Variable?
  local function find_var(scopes, expression)
    for _, s in ipairs(scopes) do
      for _, var in ipairs(s.variables or {}) do
        if var.name == expression then
          return var
        end
      end
    end
    return nil
  end

  M.expression = {
    new_buf = function()
      local buf = new_buf()
      vim.bo[buf].tagfunc = "v:lua.require'dap'._tagfunc"
      api.nvim_create_autocmd("TextYankPost", {
        buffer = buf,
        callback = function()
          require("dap._cmds").yank_evalname()
        end,
      })
      return buf
    end,
    before_open = function(view)
      view.__expression = vim.fn.expand('<cexpr>')
    end,
    render = function(view, expr)
      local session = require('dap').session()
      local layer = view.layer()
      if not session then
        layer.render({'No active session'})
        return
      end
      local expression = expr or view.__expression
      local context = session.capabilities.supportsEvaluateForHovers and "hover" or "repl"
      local args = {
        expression = expression,
        context = context
      }
      local frame = session.current_frame or {}
      local scopes = frame.scopes or {}
      session:evaluate(args, function(err, resp)
        local spec = vim.deepcopy(require('dap.entity').variable.tree_spec)
        spec.extra_context = { view = view }
        if err then
          local variable = find_var(scopes, expression)
          if variable then
            local tree = ui.new_tree(spec)
            tree.render(view.layer(), variable)
          else
            local msg = 'Cannot evaluate "'..expression..'"!'
            layer.render({msg})
          end
        elseif resp and resp.result then
          local attributes = (resp.presentationHint or {}).attributes or {}
          if resp.variablesReference > 0 or vim.tbl_contains(attributes, "rawString") then
            local tree = ui.new_tree(spec)
            tree.render(layer, resp)
          else
            local lines = vim.split(resp.result, "\n", { plain = true })
            layer.render(lines)
          end
        end
      end)
    end,
  }
end


function M.builder(widget)
  assert(widget, 'widget is required')
  local nwin
  local nbuf = widget.new_buf
  local hooks = {{widget.before_open, widget.after_open},}
  local builder = {}

  function builder.add_hooks(before_open, after_open)
    table.insert(hooks, {before_open, after_open})
    return builder
  end

  function builder.keep_focus()
    builder.add_hooks(
      function()
        return api.nvim_get_current_win()
      end,
      function(_, win)
        api.nvim_set_current_win(win)
      end
    )
    return builder
  end

  function builder.new_buf(val)
    assert(val and type(val) == "function", '`new_buf` must be a function')
    nbuf = val
    return builder
  end

  function builder.new_win(val)
    assert(val, '`new_win` must be a callable')
    nwin = val
    return builder
  end

  function builder.build()
    assert(nwin, '`new_win` function must be set')
    local before_open_results
    local view = ui.new_view(nbuf, nwin, {

      before_open = function(view)
        before_open_results = {}
        for _, hook in pairs(hooks) do
          local result = hook[1] and hook[1](view) or vim.NIL
          table.insert(before_open_results, result)
        end
      end,

      after_open = function(view, _, ...)
        for idx, hook in pairs(hooks) do
          if hook[2] then
            hook[2](view, before_open_results[idx])
          end
        end
        before_open_results = {}
        return widget.render(view, ...)
      end
    })

    view.layer = function()
      if type(nwin) == "table" and nwin.resize then
        return resizing_layer(view.win, view.buf)
      else
        return ui.layer(view.buf)
      end
    end

    view.refresh = function()
      local layer = view.layer()
      layer.render({}, tostring, nil, 0, -1)
      widget.render(view)
    end
    return view
  end
  return builder
end


---@param expr nil|string|fun():string
---@return string
local function eval_expression(expr)
  local mode = api.nvim_get_mode()
  if mode.mode == 'v' then
    -- [bufnum, lnum, col, off]; 1-indexed
    local start = vim.fn.getpos('v')
    local end_ = vim.fn.getpos('.')

    local start_row = start[2]
    local start_col = start[3]

    local end_row = end_[2]
    local end_col = end_[3]

    if start_row == end_row and end_col < start_col then
      end_col, start_col = start_col, end_col
    elseif end_row < start_row then
      start_row, end_row = end_row, start_row
      start_col, end_col = end_col, start_col
    end

    api.nvim_feedkeys(api.nvim_replace_termcodes('<ESC>', true, false, true), 'n', false)

    -- buf_get_text is 0-indexed; end-col is exclusive
    local lines = api.nvim_buf_get_text(0, start_row - 1, start_col - 1, end_row - 1, end_col, {})
    return table.concat(lines, '\n')
  end
  expr = expr or '<cexpr>'
  if type(expr) == "function" then
    return expr()
  else
    return vim.fn.expand(expr)
  end
end


---@param expr nil|string|fun():string
---@param winopts table<string, any>?
function M.hover(expr, winopts)
  local value = eval_expression(expr)
  local view = M.builder(M.expression)
    .new_win(M.with_resize(with_winopts(M.new_cursor_anchored_float_win, winopts)))
    .build()
  local buf = view.open(value)
  api.nvim_buf_set_name(buf, 'dap-hover-' .. tostring(buf) .. ': ' .. value)
  api.nvim_win_set_cursor(view.win, {1, 0})
  return view
end


function M.cursor_float(widget, winopts)
  local view = M.builder(widget)
    .new_win(M.with_resize(with_winopts(M.new_cursor_anchored_float_win, winopts)))
    .build()
  view.open()
  return view
end


function M.centered_float(widget, winopts)
  local view = M.builder(widget)
    .new_win(with_winopts(M.new_centered_float_win, winopts))
    .build()
  view.open()
  return view
end


--- View the value of the expression under the cursor in a preview window
---
---@param expr nil|string|fun():string
---@param opts? {listener?: string[]}
function M.preview(expr, opts)
  opts = opts or {}
  local value = eval_expression(expr)

  local function new_preview_buf()
    vim.cmd('pedit ' .. 'dap-preview: ' .. value)
    for _, win in pairs(api.nvim_list_wins()) do
      if vim.wo[win].previewwindow then
        local buf = api.nvim_win_get_buf(win)
        set_default_bufopts(buf)
        vim.bo[buf].bufhidden = 'delete'
        return buf
      end
    end
  end

  local function new_preview_win()
    -- Avoid pedit call if window is already open
    -- Otherwise on_detach is triggered
    for _, win in ipairs(api.nvim_list_wins()) do
      if vim.wo[win].previewwindow then
        return win
      end
    end
    vim.cmd('pedit ' .. 'dap-preview: ' .. value)
    for _, win in ipairs(api.nvim_list_wins()) do
      if vim.wo[win].previewwindow then
        return win
      end
    end
  end

  if opts.listener and next(opts.listener) then
    new_preview_buf = M.with_refresh(new_preview_buf, opts.listener)
  end
  local view = M.builder(M.expression)
    .new_buf(new_preview_buf)
    .new_win(new_preview_win)
    .build()
  view.open(value)
  view.__expression = value
  return view
end


--- Decorate a `new_buf` function so that it will register a
-- `dap.listeners.after[listener]` which will trigger a `view.refresh` call.
--
-- Use this if you want a widget to live-update.
---@param listener string|string[]
function M.with_refresh(new_buf_, listener)
  local listeners
  if type(listener) == "table" then
    listeners = listener
  else
    listeners = {listener}
  end
  return function(view)
    local dap = require('dap')
    for _, l in pairs(listeners) do
      dap.listeners.after[l][view] = view.refresh
    end
    local buf = new_buf_(view)
    api.nvim_buf_attach(buf, false, {
      on_detach = function()
        for _, l in pairs(listeners) do
          dap.listeners.after[l][view] = nil
        end
      end
    })
    return buf
  end
end


--- Open the given widget in a sidebar
--@param winopts with options that configure the window
--@param wincmd command used to create the sidebar
function M.sidebar(widget, winopts, wincmd)
  return M.builder(widget)
    .keep_focus()
    .new_win(mk_sidebar_win_func(winopts, wincmd))
    .new_buf(M.with_refresh(widget.new_buf, widget.refresh_listener or 'event_stopped'))
    .build()
end


---@param session dap.Session
---@param expr string
---@param max_level integer
local function get_var_lines(session, expr, max_level)
  local req_args = {
    expression = expr,
    context = "repl",
    frameId = (session.current_frame or {}).id
  }
  local eval_err, eval_result = session:request("evaluate", req_args)
  assert(not eval_err, vim.inspect(eval_err))

  local lines = {}
  local value = eval_result.result:gsub("\n", "\\n")
  table.insert(lines, value)

  local function add_children(ref, level)
    require("dap.progress").report("Fetching " .. tostring(ref))

    ---@type dap.VariablesArguments
    local vargs = {
      variablesReference = ref,
    }
    ---@type dap.ErrorResponse, dap.VariableResponse
    local err, result = session:request("variables", vargs)
    assert(not err, vim.inspect(err))
    for _, variable in ipairs(result.variables) do
      local val = variable.value:gsub("\n", "\\n")
      local indent = level * 2
      local line = string.rep(" ", indent) .. variable.name .. ": " .. val
      table.insert(lines, line)
      if level < max_level and variable.variablesReference > 0 then
        add_children(variable.variablesReference, level + 1)
      end
    end
  end

  if eval_result.variablesReference > 0 then
    add_children(eval_result.variablesReference, 0)
  end

  return lines
end


--- Generate a diff between two expressions
---
--- Opens a new tab with two windows and buffers in diff mode.
--- The diff is based on the lines of the variable tree's, expanded up to `max_level`
---
---@param expr1 string
---@param expr2 string
---@param max_level? integer default: 1
function M.diff_var(expr1, expr2, max_level)
  local dap = require("dap")
  local session = dap.session()
  if not session then
    utils.notify("No active session", vim.log.levels.INFO)
    return
  end
  max_level = max_level or 1
  require("dap.async").run(function()
    local lines1 = get_var_lines(session, expr1, max_level)
    local lines2 = get_var_lines(session, expr2, max_level)
    require("dap.progress").report("Diff operation done")
    require("dap.progress").report("Running: " .. session.config.name)
    vim.cmd.tabnew()
    local buf1 = api.nvim_get_current_buf()
    api.nvim_buf_set_lines(buf1, 0, -1, true, lines1)
    vim.bo[buf1].modified = false
    vim.bo[buf1].bufhidden = "wipe"
    vim.cmd.diffthis()

    vim.cmd.vnew()
    local buf2 = api.nvim_get_current_buf()
    api.nvim_buf_set_lines(buf2, 0, -1, true, lines2)
    vim.bo[buf2].modified = false
    vim.bo[buf2].bufhidden = "wipe"
    vim.cmd.diffthis()
  end)
end


return M
