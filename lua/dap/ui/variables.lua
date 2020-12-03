local api = vim.api
local utils = require("dap.utils")
local non_empty_sequence = utils.non_empty_sequence

local M = {}

M.multiline_variable_display = false
M.max_win_width = 100
M.variable_value_separator = " = "
M.show_types = true

local floating_buf = nil
local floating_win = nil
local variable_buffers = {}

-- Variable (https://microsoft.github.io/debug-adapter-protocol/specification#Types_Variable)
--- name: string
--- value: string (since we're also accepting scopes here: also optional)
--- type?: string
--- presentationHint?: VariablePresentationHint
--- evaluateName?: string
--- variablesReference: number
--- namedVariables?: number
--- indexedVariables?: number
--- memoryReference?: string
local function write_variables(buf, variables, line, column, win)
  line = line or 0
  column = column or 0

  local state = variable_buffers[buf]
  local win_width = api.nvim_win_get_width(win)
  local win_height = api.nvim_win_get_height(win)
  local indent = string.rep(" ", column)

  local sorted_variables = {}
  for _, v in pairs(variables) do
    table.insert(sorted_variables, v)
  end
  table.sort(
    sorted_variables,
    function(a, b)
      return a.name < b.name
    end
  )
  local max_textlength = 0

  for _, v in pairs(sorted_variables) do
    state.line_to_variable[line] = v
    local text =
      indent..
      v.name..
        (non_empty_sequence(v.value) and M.variable_value_separator..v.value or "")..
          " "..((M.show_types and v.type) and (" "..v.type) or "")

    local splitted_text = vim.split(text, "\n")

    if M.multiline_variable_display then
      local newline_indent = #(indent..v.name..M.variable_value_separator)
      for i = 2, #splitted_text do
        splitted_text[i] = string.rep(' ', newline_indent)..splitted_text[i]
      end
      api.nvim_buf_set_lines(buf, line, line + #splitted_text, false, splitted_text)
      line = line + #splitted_text
    else
      api.nvim_buf_set_lines(buf, line, line + 1, false, splitted_text)
      api.nvim_buf_set_lines(buf, line, line + 1, false, {table.concat(splitted_text, " ")})
      line = line + 1
    end

    if v.variables and variable_buffers[buf].expanded[v.variablesReference] then
      local inner_max
      line, inner_max = write_variables(buf, v.variables, line, column + 2, win)
      max_textlength = math.max(max_textlength, inner_max)
    end
    max_textlength = math.max(max_textlength, #text)
  end
  if win then
    if win_width < max_textlength then
      api.nvim_win_set_width(win, math.min(max_textlength + 2, M.max_win_width))
    end
    if win_height < line then
      api.nvim_win_set_height(win, line)
    end
  end
  api.nvim_buf_set_lines(buf, line, -1, false, {})
  return line, max_textlength
end


local function update_variable_buffer(buf, win)
  api.nvim_buf_set_option(buf, "modifiable", true)
  local state = variable_buffers[buf]
  write_variables(buf, state.variables, 0, 0, win)
end


function M.toggle_variable_expanded()
  local buf = api.nvim_get_current_buf()
  local state = variable_buffers[buf]
  local pos = api.nvim_win_get_cursor(0)
  local win = api.nvim_get_current_win()
  if not state then return end

  local v = state.line_to_variable[pos[1] - 1]

  if v and v.variablesReference > 0 then
    if state.expanded[v.variablesReference] then
      state.expanded[v.variablesReference] = nil
      update_variable_buffer(buf, win)
      api.nvim_win_set_cursor(win, pos)
    else
      state.expanded[v.variablesReference] = true
      if v.variables then
        update_variable_buffer(buf, win)
        api.nvim_win_set_cursor(win, pos)
      else
        local session = state.session
        if not session then
          return
        end
        if not session.stopped_thread_id then
          return
        end
        session:request(
          "variables",
          {variablesReference = v.variablesReference},
          function(_, response)
            if response then
              v.variables =
                utils.calc_kv_table_from_values(
                function(var)
                  return var.name
                end,
                response.variables
              )
              update_variable_buffer(buf, win)
            end
            api.nvim_win_set_cursor(win, pos)
          end
        )
      end
    end
  end
end


local function create_variable_buffer(buf, win, session, root_variables)
  variable_buffers[buf] = {
    variables = root_variables,
    expanded = {},
    session = session,
    line_to_variable = {}
  }
  for _, v in pairs(root_variables) do
    -- Is variable expandable?
    if v.variablesReference > 0 then
      variable_buffers[buf].expanded[v.variablesReference] = true
      if not v.variables then
        session:request(
          "variables",
          {variablesReference = v.variablesReference},
          function(_, response)
            if response then
              v.variables =
                utils.calc_kv_table_from_values(
                function(var)
                  return var.name
                end,
                response.variables
              )
              update_variable_buffer(buf, win)
            end
          end
        )
      end
    end
  end
  update_variable_buffer(buf, win)
end


local function popup()
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
  api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  api.nvim_buf_set_option(buf, 'filetype', 'dap-variables')
  api.nvim_buf_set_option(buf, 'syntax', 'dap-variables')
  api.nvim_buf_set_keymap(
    buf,
    "n",
    "<CR>",
    "<Cmd>lua require('dap.ui.variables').toggle_variable_expanded()<CR>",
    {}
  )
  api.nvim_buf_set_keymap(
    buf,
    "n",
    "<2-LeftMouse>",
    "<Cmd>lua require('dap.ui.variables').toggle_variable_expanded()<CR>",
    {}
  )
  -- width and height are increased later once variables are written to the buffer
  local opts = vim.lsp.util.make_floating_popup_options(1, 1, {})
  local win = api.nvim_open_win(buf, true, opts)
  return win, buf
end


function M.hover()
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
  if vim.tbl_contains(vim.api.nvim_list_wins(), floating_win) then
    vim.api.nvim_set_current_win(floating_win)
  else
    local cword = vim.fn.expand("<cword>")
    local variable
    local scopes = frame.scopes or {}
    for _, s in pairs(scopes) do
      variable = s.variables and s.variables[cword]
      if variable then
        break
      end
    end
    if variable then
      floating_win, floating_buf = popup()
      create_variable_buffer(floating_buf, floating_win, session, {variable})
    else
      print('"'..cword..'" not found!')
    end
  end
end

return M
