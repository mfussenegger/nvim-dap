local ui = require('dap.ui')
local M = {}

M.toggle_variable_expanded = ui.trigger_actions
M.multiline_variable_display = false


function M.scopes()
  local widgets = require('dap.ui.widgets')
  widgets.hover(widgets.scopes)
end

function M.hover(resolve_expression_fn)
  -- if not is_stopped_at_frame() then return end
  local widgets = require('dap.ui.widgets')
  local builder = widgets.builder(widgets.expression)
  if resolve_expression_fn then
    builder.before_open(resolve_expression_fn)
  end
  builder.build().open()
end


function M.visual_hover()
  local utils = require("dap.utils")
  M.hover(utils.get_visual_selection_text)
end


function M.toggle_multiline_display(value)
  M.multiline_variable_display = value or (not M.multiline_variable_display)
  -- TODO:
end

return M
