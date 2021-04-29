local ui = require('dap.ui')
local api = vim.api
local M = {}
M.max_win_width = 100


-- TODO: better defaults, distinguish per widget, make composable

local function new_buf()
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
  api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  api.nvim_buf_set_keymap(
    buf, "n", "<CR>", "<Cmd>lua require('dap.ui').trigger_actions()<CR>", {})
  api.nvim_buf_set_keymap(
    buf, "n", "<2-LeftMouse>", "<Cmd>lua require('dap.ui').trigger_actions()<CR>", {})
  return buf
end


function M.new_float_win(buf)
  local opts = vim.lsp.util.make_floating_popup_options(50, 30, {})
  local win = api.nvim_open_win(buf, true, opts)
  return win
end


local function new_sidebar_win()
  vim.cmd('30 vsplit')
  local win = api.nvim_get_current_win()
  api.nvim_win_set_option(win, 'number', false)
  api.nvim_win_set_option(win, 'relativenumber', false)
  return win
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
  local lines = api.nvim_buf_get_lines(buf, 0, -1, true)
  local width = 0
  local height = #lines
  for _, line in pairs(lines) do
    width = math.max(width, #line)
  end
  width = math.min(width + 3, M.max_win_width)
  height = math.min(height + 3, api.nvim_get_option('lines'))
  api.nvim_win_set_width(win, width)
  api.nvim_win_set_height(win, height)
end


local function resizing_layer(win, buf)
  local layer = ui.layer(buf)
  local orig_render = layer.render
  layer.render = function(...)
    orig_render(...)
    resize_window(win, buf)
  end
  return layer
end


M.resolve_expression = function()
  return vim.fn.expand('<cexpr>')
end


M.scopes = {
  new_buf = function(view)
    local dap = require('dap')
    local function reset_tree()
      view.tree = nil
    end
    dap.listeners.after['event_terminated'][view] = reset_tree
    dap.listeners.after['event_exited'][view] = reset_tree
    local buf = new_buf()
    api.nvim_buf_attach(buf, false, {
      on_detach = function()
        dap.listeners.after['event_terminated'][view] = nil
        dap.listeners.after['event_exited'][view] = nil
      end
    })
    return buf
  end,
  render = function(view)
    local session = require('dap').session()
    local frame = session and session.current_frame or {}
    local tree = view.tree
    if not tree then
      tree = ui.new_tree(require('dap.entity').scope.tree_spec)
      view.tree = tree
    end
    local layer = view.layer()
    for _, scope in pairs(frame.scopes or {}) do
      tree.render(layer, scope)
    end
  end,
}


M.frames = {
  new_buf = new_buf,
  render = function(view)
    local session = require('dap').session()
    local frames = (session and session.threads[session.stopped_thread_id] or {}).frames or {}
    local context = {}
    context.actions = {
      {
        label = "Jump to frame",
        fn = function(_, frame)
          if session then
            session:_frame_set(frame)
            -- TODO: view shouldn't close if it is a sidebar
            view.close()
          else
            print('Cannot navigate to frame without active session')
          end
        end
      },
    }
    local layer = view.layer()
    local render_frame = require('dap.entity').frames.render_item
    layer.render(frames, render_frame, context)
  end
}


M.expression = {
  new_buf = new_buf,
  before_open = function(view)
    view.__expression = M.resolve_expression()
  end,
  render = function(view)
    local session = require('dap').session()
    local frame = session and session.current_frame
    local expression = view.__expression
    local variable
    local scopes = frame.scopes or {}
    for _, s in pairs(scopes) do
      variable = s.variables and s.variables[expression]
      if variable then
        break
      end
    end
    if variable then
      local tree = ui.new_tree(require('dap.entity').variable.tree_spec)
      tree.render(view.layer(), variable)
    else
      session:evaluate(expression, function(err, resp)
        local layer = view.layer()
        if err then
          local msg = 'Cannot evaluate "'..expression..'"!'
          layer.render({msg})
        elseif resp and resp.result then
          local tree = ui.new_tree(require('dap.entity').variable.tree_spec)
          tree.render(layer, resp)
        end
      end)
    end
  end,
}


function M.builder(widget)
  assert(widget, 'widget is required')
  local nbuf = widget.new_buf
  local nwin = widget.new_win
  local hooks = {{widget.before_open, widget.after_open},}
  local builder = {}

  function builder.add_hooks(before_open, after_open)
    table.insert(hooks, {before_open, after_open})
    return builder
  end

  function builder.keep_focus()
    builder.add_hooks(
      function() return api.nvim_get_current_win() end,
      function(win)
        api.nvim_set_current_win(win)
      end
    )
    return builder
  end

  function builder.new_buf(val)
    nbuf = val
    return builder
  end

  function builder.new_win(val)
    nwin = val
    return builder
  end

  function builder.build()
    local before_open_results
    local view = ui.new_view(nbuf, nwin, {

      before_open = function(view)
        before_open_results = {}
        for _, hook in pairs(hooks) do
          local result = hook[1] and hook[1](view) or vim.NIL
          table.insert(before_open_results, result)
        end
      end,

      after_open = function(view, ...)
        for idx, hook in pairs(hooks) do
          if hook[2] then
            local result = hook[2](view, before_open_results[idx])
            table.insert(before_open_results, result)
          end
        end
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


function M.hover(widget, ...)
  return M.builder(widget)
    .new_win(M.with_resize(M.new_float_win))
    .build()
    .open(...)
end


--- Decorate a `new_buf` function so that it will register a
-- `dap.listeners.after[listener]` which will trigger a `view.refresh` call.
--
-- Use this if you want a widget to live-update.
function M.with_refresh(new_buf_, listener)
  return function(view)
    local dap = require('dap')
    dap.listeners.after[listener][view] = view.refresh
    local buf = new_buf_(view)
    api.nvim_buf_attach(buf, false, {
      on_detach = function()
        dap.listeners.after[listener][view] = nil
      end
    })
    return buf
  end
end


--- Open the given widget in a sidebar
function M.sidebar(widget)
  local view = M.builder(widget)
    .keep_focus()
    .new_win(new_sidebar_win)
    .new_buf(M.with_refresh(widget.new_buf, 'variables'))
    .build()
  view.open()
  return view
end


return M
