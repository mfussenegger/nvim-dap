local ui = require('dap.ui')
local api = vim.api
local M = {}
M.max_win_width = 100


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


local function new_float_win(buf)
  local opts = vim.lsp.util.make_floating_popup_options(50, 30, {})
  local win = api.nvim_open_win(buf, true, opts)
  return win
end


local function with_resize(new_win)
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
  new_buf = new_buf,
  new_win = with_resize(new_float_win),
  render = function(view)
    local session = require('dap').session()
    local frame = session and session.current_frame or {}
    local tree = ui.new_tree(require('dap.entity').scope.tree_spec)
    local layer = view.layer()
    for _, scope in pairs(frame.scopes or {}) do
      tree.render(layer, scope)
    end
  end,
}


M.frames = {
  new_buf = new_buf,
  new_win = with_resize(new_float_win),
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
  new_win = with_resize(new_float_win),
  before_open = M.resolve_expression,
  render = function(view, expression)
    local session = require('dap').session()
    local frame = session and session.current_frame
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
  local before_open = widget.before_open
  local builder
  builder = {

    new_buf = function(val)
      nbuf = val
      return builder
    end,

    new_win = function(val)
      nwin = val
      return builder
    end,

    before_open = function(val)
      before_open = val
      return builder
    end,

    build = function()
      local view = ui.new_view(nbuf, nwin, {
        before_open = before_open,
        after_open = widget.render,
      })
      view.layer = function()
        if nwin.resize then
          return resizing_layer(view.win, view.buf)
        else
          return ui.layer(view.buf)
        end
      end
      return view
    end
  }
  return builder
end


function M.hover(widget, ...)
  return M.builder(widget)
    .build()
    .open(...)
end


return M
