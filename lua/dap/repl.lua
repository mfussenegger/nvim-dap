local api = vim.api
local ui = require('dap.ui')
local M = {}

local win = nil
local buf = nil
local layer = nil
local session = nil


local history = {
  last = nil,
  entries = {},
  idx = 1
}


local variables_ns = api.nvim_create_namespace('dap.repl.variables')


M.commands = {
  continue = {'.continue', '.c'},
  next_ = {'.next', '.n'},
  step_back = {'.back', '.b'},
  reverse_continue = {'.reverse-continue', '.rc'},
  into = {'.into'},
  into_targets = {'.into-targets'},
  out = {'.out'},
  scopes = {'.scopes'},
  threads = {'.threads'},
  frames = {'.frames'},
  exit = {'exit', '.exit'},
  up = {'.up'},
  down = {'.down'},
  goto_ = {'.goto'},
  pause = {'.pause', '.p'},
  capabilities = {'.capabilities'},
  help = {'help', '.help', '.h'},
  custom_commands = {}
}


local function render_frame(frame)
  if frame.id == session.current_frame.id then
    return '→ ' .. frame.name
  else
    return '  ' .. frame.name
  end
end


function M.print_stackframes(frames)
  if not layer then
    return
  end
  frames = frames or (session.threads[session.stopped_thread_id] or {}).frames or {}
  local context = {}
  M.append('(press enter on line to jump to frame)')
  local start = ui.get_last_line(buf)
  context.actions = {
    {
      label = 'Jump to frame',
      fn = function(frame)
        if session then
          session:_frame_set(frame)
          layer.render(frames, render_frame, context, start, start + #frames)
        else
          print('Cannot navigate to frame without active session')
        end
      end,
    },
  }
  layer.render(frames, render_frame, context)
end


local syntax_mapping = {
  boolean = 'Boolean',
  String = 'String',
  int = 'Number',
  long = 'Number',
  double = 'Float',
  float = 'Float',
}


local function print_var(resp, lnum)
  M.append(resp.result, lnum)
  local syntax_group = resp.type and syntax_mapping[resp.type]
  if syntax_group then
    api.nvim_buf_add_highlight(buf, variables_ns, syntax_group, lnum, 0, -1)
  end
end


local function print_children(variables)
  for _, val in ipairs(variables) do
    local prefix = '  ' .. val.name .. ': '
    local lnum = M.append(prefix .. val.value)
    if not lnum then
      break -- buffer disappeared
    end
    api.nvim_buf_add_highlight(buf, variables_ns, 'Identifier', lnum, 2, #val.name + 3)
    local syntax_group = val.type and syntax_mapping[val.type]
    if syntax_group then
      api.nvim_buf_add_highlight(buf, variables_ns, syntax_group, lnum, #prefix, -1)
    end
  end
end


local function evaluate_input(text, lnum)
  session:evaluate(text, function(err, resp)
    if err then
      M.append(err.message, lnum)
      return
    end
    if resp.variablesReference == 0 then
      print_var(resp, lnum)
      return
    end

    local params = {
      variablesReference = resp.variablesReference
    }
    session:request('variables', params, function(err1, v_resp)
      if err1 then
        M.append(err1.message, lnum)
        return
      end
      print_var(resp, lnum)
      print_children(v_resp.variables)
    end)
  end)
end


local function print_commands()
  M.append('Commands:')
  for _, commands in pairs(M.commands) do
    if #commands > 0 then
      M.append('  ' .. table.concat(commands, ', '))
    end
  end
end


local function execute(text)
  if text == '' then
    if history.last then
      text = history.last
    else
      return
    end
  else
    history.last = text
    table.insert(history.entries, text)
    history.idx = #history.entries + 1
  end

  local splitted_text = vim.split(text, ' ')
  if vim.tbl_contains(M.commands.exit, text) then
    if session then
      -- Should result in a `terminated` event which closes the session and sets it to nil
      session:disconnect()
    end
    api.nvim_command('close')
    return
  end
  if vim.tbl_contains(M.commands.help, text) then
    print_commands()
    return
  end
  if not session then
    M.append('No active debug session')
    return
  end
  if vim.tbl_contains(M.commands.continue, text) then
    require('dap').continue()
  elseif vim.tbl_contains(M.commands.next_, text) then
    require('dap').step_over()
  elseif vim.tbl_contains(M.commands.capabilities, text) then
    M.append(vim.inspect(session.capabilities))
  elseif vim.tbl_contains(M.commands.into, text) then
    require('dap').step_into()
  elseif vim.tbl_contains(M.commands.into_targets, text) then
    require('dap').step_into({askForTargets=true})
  elseif vim.tbl_contains(M.commands.out, text) then
    require('dap').step_out()
  elseif vim.tbl_contains(M.commands.up, text) then
    session:_frame_delta(1)
    M.print_stackframes()
  elseif vim.tbl_contains(M.commands.step_back, text) then
    require('dap').step_back()
  elseif vim.tbl_contains(M.commands.pause, text) then
    session:_pause()
  elseif vim.tbl_contains(M.commands.reverse_continue, text) then
    require('dap').reverse_continue()
  elseif vim.tbl_contains(M.commands.down, text) then
    session:_frame_delta(-1)
    M.print_stackframes()
  elseif vim.tbl_contains(M.commands.goto_, splitted_text[1]) then
    if splitted_text[2] then
      session:_goto(tonumber(splitted_text[2]))
    end
  elseif vim.tbl_contains(M.commands.scopes, text) then
    local frame = session.current_frame
    if frame then
      for _, scope in pairs(frame.scopes) do
        M.append(string.format("%s  (frame: %s)", scope.name, frame.name))
        for _, variable in pairs(scope.variables or {}) do
          M.append(string.rep(' ', 2) .. variable.name .. ': ' .. variable.value)
        end
      end
    end
  elseif vim.tbl_contains(M.commands.threads, text) then
    for _, thread in pairs(session.threads) do
      if session.stopped_thread_id == thread.id then
        M.append('→ ' .. thread.name)
      else
        M.append('  ' .. thread.name)
      end
    end
  elseif vim.tbl_contains(M.commands.frames, text) then
    M.print_stackframes()
  elseif M.commands.custom_commands[splitted_text[1]] then
    local command = table.remove(splitted_text, 1)
    M.commands.custom_commands[command](text)
  else
    local lnum = vim.fn.line('$') - 1
    evaluate_input(text, lnum)
  end
end


--- Close the REPL if it is open.
--
-- Does not disconnect an active session.
--
-- Returns true if the REPL was open and got closed. false otherwise
function M.close()
  local closed
  if win and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf then
    api.nvim_win_close(win, true)
    win = nil
    closed = true
  else
    closed = false
  end

  if buf then
    api.nvim_buf_delete(buf, {force = true})
    buf = nil
  end

  return closed
end


--- Open the REPL
--
--@param winopts  optional table which may include:
--                  `height` to set the window height
--                  `width` to set the window width
--
--                  Any other key/value pair, that will be treated as window
--                  option.
--
--@param wincmd command that is used to create the window for the REPL.
--              Defaults to 'belowright split'
function M.open(winopts, wincmd)
  if win and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf then
    return
  end
  if not buf then
    local prev_buf = api.nvim_get_current_buf()

    buf = api.nvim_create_buf(true, true)
    api.nvim_buf_set_name(buf, '[dap-repl]')
    api.nvim_buf_set_option(buf, 'buftype', 'prompt')
    api.nvim_buf_set_option(buf, 'omnifunc', "v:lua.require'dap'.omnifunc")
    layer = ui.layer(buf)
    local ok, path = pcall(api.nvim_buf_get_option, prev_buf, 'path')
    if ok then
      api.nvim_buf_set_option(buf, 'path', path)
    end

    api.nvim_buf_set_keymap(buf, 'n', '<CR>', "<Cmd>lua require('dap.repl').on_enter()<CR>", {})
    api.nvim_buf_set_keymap(buf, 'i', '<up>', "<Cmd>lua require('dap.repl').on_up()<CR>", {})
    api.nvim_buf_set_keymap(buf, 'i', '<down>', "<Cmd>lua require('dap.repl').on_down()<CR>", {})
    vim.fn.prompt_setprompt(buf, 'dap> ')
    vim.fn.prompt_setcallback(buf, execute)
    api.nvim_buf_attach(buf, false, {
      on_detach = function()
        buf = nil
        layer = nil
        return true
      end;
    })
  end
  local current_win = api.nvim_get_current_win()
  assert(not wincmd or type(wincmd) == 'string', 'wincmd must be nil or a string')
  api.nvim_command(wincmd or 'belowright split')
  win = api.nvim_get_current_win()
  api.nvim_win_set_buf(win, buf)
  api.nvim_buf_set_option(buf, 'filetype', 'dap-repl')
  api.nvim_set_current_win(current_win)
  ui.apply_winopts(win, winopts)
end


--- Open the REPL if it is closed, close it if it is open.
function M.toggle(winopts, wincmd)
  if not M.close() then
    M.open(winopts, wincmd)
  end
end


function M.on_enter()
  if not layer then
    return
  end
  local lnum, col = unpack(api.nvim_win_get_cursor(0))
  lnum = lnum - 1
  local info = layer.get(lnum, 0, col)
  if not info then
    vim.notify('No action possible on: ' .. api.nvim_buf_get_lines(buf, lnum, lnum + 1, true)[1])
    return
  end
  local actions = info.context.actions
  if not actions or #actions == 0 then
    return
  end
  ui.pick_if_many(
    actions,
    'Actions> ',
    function(x) return type(x.label) == 'string' and x.label or x.label(info.item) end,
    function(action)
      if action then
        action.fn(info.item, lnum)
      end
    end
  )
end


local function select_history(delta)
  if not buf then
    return
  end
  history.idx = history.idx + delta
  if history.idx < 1 then
    history.idx = #history.entries
  elseif history.idx > #history.entries then
    history.idx = 1
  end
  local text = history.entries[history.idx]
  if text then
    local lnum = vim.fn.line('$') - 1
    api.nvim_buf_set_lines(buf, lnum, lnum + 1, true, {'dap> ' .. text })
  end
end


function M.on_up()
  select_history(-1)
end

function M.on_down()
  select_history(1)
end


function M.append(line, lnum)
  if buf then
    if api.nvim_get_current_win() == win and lnum == '$' then
      lnum = nil
    end
    local lines = vim.split(line, '\n')
    api.nvim_buf_call(buf, function()
      lnum = lnum or (vim.fn.line('$') - 1)
      vim.fn.appendbufline(buf, lnum, lines)
    end)
    return lnum
  end
  return nil
end


function M.set_session(s)
  session = s
  history.last = nil
  history.entries = {}
  history.idx = 1
  if s and buf and api.nvim_buf_is_loaded(buf) then
    api.nvim_buf_set_lines(buf, 0, -1, true, {})
  end
end


return M
