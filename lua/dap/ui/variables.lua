local api = vim.api
local utils = require("dap.utils")
local non_empty = utils.non_empty
local dap = require'dap'

local M = {}

M.multiline_variable_display = false
M.max_win_width = 100
M.variable_value_separator = " = "
M.show_types = true

local floating_buf = nil
local floating_win = nil
local variable_buffers = {}


local function get_subscribution_id(buf)
  return 'variables_buf_'..buf
end


local function is_subscribed(buf)
  local id = get_subscribution_id(buf)
  return dap.custom_event_handlers.event_terminated[id] ~= nil
end


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
  local win_valid = api.nvim_win_is_valid(win)
  local win_width = win_valid and api.nvim_win_get_width(win)
  local win_height = win_valid and api.nvim_win_get_height(win)
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
        (non_empty(v.value) and M.variable_value_separator..v.value or "")..
          " "..((M.show_types and v.type) and (" "..v.type) or "")

    if M.multiline_variable_display then
      -- verbatim \n in strings to real new lines
      text = text:gsub('\\r\\n', '\n'):gsub('\\r', '\n'):gsub('\\n','\n')
    end
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
    if win_valid and win_width < max_textlength then
      api.nvim_win_set_width(win, math.min(max_textlength + 2, M.max_win_width))
    end
    if win_valid and win_height < line then
      api.nvim_win_set_height(win, line)
    end
  end
  api.nvim_buf_set_lines(buf, line, -1, false, {})
  return line, max_textlength
end


local function update_variable_buffer(buf, win)
  api.nvim_buf_set_option(buf, "modifiable", true)
  local state = variable_buffers[buf]
  state.line_to_variable = {}
  write_variables(buf, state.variables, 0, 0, win)
end

-- forward declaration of function
local subscribe_to_session_events


local function create_variable_buffer(buf, win, session, get_root_variables)
  local root_variables = get_root_variables()
  if not root_variables then return end

  if not is_subscribed(buf) then
    subscribe_to_session_events(buf, win, session, get_root_variables)
  end

  variable_buffers[buf] = {
    variables = root_variables,
    expanded = {},
    session = session,
    line_to_variable = {},
    is_valid = true
  }
  for _, v in pairs(root_variables) do
    -- Is variable expandable?
    if v.variablesReference and v.variablesReference > 0 then
      variable_buffers[buf].expanded[v.variablesReference] = true
      if not v.variables then
        session:request(
          "variables",
          {variablesReference = v.variablesReference},
          function(_, response)
            if response then
              v.variables = utils.to_dict(
                response.variables,
                function(var) return var.name end
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

local function unsubscribe_to_session_events(buf)
  local id = get_subscribution_id(buf)

  dap.custom_event_handlers.event_terminated[id] = nil
  dap.custom_event_handlers.event_stopped[id] = nil
  dap.custom_response_handlers.variable[id] = nil
end


function subscribe_to_session_events(buf, win, session, get_root_variables)
  local id = get_subscribution_id(buf)

  dap.custom_event_handlers.event_terminated[id] = function()
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      vim.api.nvim_win_close(win, false)
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {'Session was terminated!'})
  end

  dap.custom_event_handlers.event_stopped[id] = function()
    local state = variable_buffers[buf]
    state.is_valid = false
  end

  dap.custom_response_handlers.variables[id] = function()
    local state = variable_buffers[buf]
    if state.is_valid then
      update_variable_buffer(buf, win)
    else
      create_variable_buffer(buf, win, session, get_root_variables)
    end
  end

  vim.api.nvim_buf_attach(buf, false,
  {
    on_detach = function() unsubscribe_to_session_events(buf) end
  })
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
              v.variables = utils.to_dict(
                response.variables,
                function(var) return var.name end
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
  api.nvim_buf_set_keymap(
    buf,
    "n",
    "g?",
    "<Cmd>lua require('dap.ui.variables').toggle_multiline_display()<CR>",
    {}
  )
  -- width and height are increased later once variables are written to the buffer
  local opts = vim.lsp.util.make_floating_popup_options(1, 1, {})
  local win = api.nvim_open_win(buf, true, opts)
  return win, buf
end


function M.resolve_expression()
  return vim.fn.expand("<cword>")
end


local function is_stopped_at_frame()
  local session = dap.session()
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


function M.scopes()
  if not is_stopped_at_frame() then return end

  local session = dap.session()

  floating_win, floating_buf = popup()
  create_variable_buffer(floating_buf, floating_win, session, function() return session.current_frame.scopes end)
end


function M.hover(resolve_expression_fn)
  if not is_stopped_at_frame() then return end


  if vim.tbl_contains(vim.api.nvim_list_wins(), floating_win) then
    vim.api.nvim_set_current_win(floating_win)
  else
    local expression = resolve_expression_fn and resolve_expression_fn() or M.resolve_expression()

    local function find_variable()
      local session = dap.session()
      local frame = session.current_frame
      local scopes = frame.scopes or {}
      local variable

      for _, s in pairs(scopes) do
        variable = s.variables and s.variables[expression]
        if variable then
          break
        end
      end
      return variable
    end
    local variable = find_variable()

    local session = dap.session()
    if variable then
      floating_win, floating_buf = popup()
      create_variable_buffer(floating_buf, floating_win, session, function() return {find_variable()} end)
    else
      session:evaluate(expression, function(err, resp)
        if err then
          print('Cannot evaluate "'..expression..'"!')
        else
          if resp and resp.result then
            floating_win, floating_buf = popup()
            resp.value = resp.result
            resp.name = expression
            create_variable_buffer(floating_buf, floating_win, session, function() return {resp} end)
          end
        end
      end)
    end
  end
end


function M.visual_hover()
  M.hover(utils.get_visual_selection_text)
end


function M.toggle_multiline_display(value)
  M.multiline_variable_display = value or (not M.multiline_variable_display)
  local buf = api.nvim_get_current_buf()
  if variable_buffers[buf] then
    local win = api.nvim_get_current_win()
    update_variable_buffer(buf, win)
  end
end

return M
