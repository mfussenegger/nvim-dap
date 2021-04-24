local api = vim.api
local utils = require("dap.utils")
local ui = require('dap.ui')

local M = {}

M.toggle_variable_expanded = ui.trigger_actions
M.multiline_variable_display = false
M.max_win_width = 100


local function new_variable_buf()
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
  api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  api.nvim_buf_set_option(buf, 'filetype', 'dap-variables')
  api.nvim_buf_set_option(buf, 'syntax', 'dap-variables')
  api.nvim_buf_set_keymap(
    buf,
    "n",
    "<CR>",
    "<Cmd>lua require('dap.ui').trigger_actions()<CR>",
    {}
  )
  api.nvim_buf_set_keymap(
    buf,
    "n",
    "<2-LeftMouse>",
    "<Cmd>lua require('dap.ui').trigger_actions()<CR>",
    {}
  )
  api.nvim_buf_set_keymap(
    buf,
    "n",
    "g?",
    "<Cmd>lua require('dap.ui.variables').toggle_multiline_display()<CR>",
    {}
  )
  return buf
end

local function new_float_win(buf)
  -- width and height are increased later once variables are written to the buffer
  local opts = vim.lsp.util.make_floating_popup_options(50, 30, {})
  local win = api.nvim_open_win(buf, true, opts)
  return win
end


local float_view = ui.new_view(new_variable_buf, new_float_win)


function M.resolve_expression()
  return vim.fn.expand("<cexpr>")
end


local function is_stopped_at_frame()
  local session = require('dap').session()
  if not session then
    print("No active session. Can't show hover window")
    return
  end
  if not session.stopped_thread_id then
    print("No stopped thread. Can't show hover window")
    return
  end
  local frame = session.current_frame
  if not frame then
    print("No frame to inspect available. Can't show hover window")
    return
  end
  return true
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


function M.scopes()
  if not is_stopped_at_frame() then return end

  local session = require('dap').session()

  float_view.open()
  local tree = ui.new_tree(require('dap.entity').scope.tree_spec)
  local frame = session.current_frame or {}
  local layer = resizing_layer(float_view.win, float_view.buf)
  for _, scope in pairs(frame.scopes or {}) do
    tree.render(layer, scope)
  end
  resize_window(float_view.win, float_view.buf)
end


function M.hover(resolve_expression_fn)
  if not is_stopped_at_frame() then return end

  local session = require('dap').session()
  local frame = session.current_frame


  local expression = resolve_expression_fn and resolve_expression_fn() or M.resolve_expression()
  local variable
  local scopes = frame.scopes or {}
  for _, s in pairs(scopes) do
    variable = s.variables and s.variables[expression]
    if variable then
      break
    end
  end
  if variable then
    float_view.open()
    local layer = resizing_layer(float_view.win, float_view.buf)
    local tree = ui.new_tree(require('dap.entity').variable.tree_spec)
    tree.render(layer, variable)
  else
    session:evaluate(expression, function(err, resp)
      if err then
        print('Cannot evaluate "'..expression..'"!')
      elseif resp and resp.result then
        float_view.open()
        local layer = resizing_layer(float_view.win, float_view.buf)
        local tree = ui.new_tree(require('dap.entity').variable.tree_spec)
        tree.render(layer, resp)
      end
    end)
  end
end


function M.visual_hover()
  M.hover(utils.get_visual_selection_text)
end


function M.toggle_multiline_display(value)
  M.multiline_variable_display = value or (not M.multiline_variable_display)
  -- TODO:
end

return M
