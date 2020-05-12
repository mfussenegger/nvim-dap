local api = vim.api
local M = {}

local win = nil
local buf = nil
local session = nil
local last_cmd = nil

M.commands = {
  continue = {'.continue', '.c'},
  next_ = {'.next', '.n'},
  into = {'.into'},
  out = {'.out'},
  scopes = {'.scopes'},
  threads = {'.threads'},
  frames = {'.frames'},
  exit = {'exit', '.exit'},
  up = {'.up'},
  down = {'.down'},
  goto_ = {'.goto'}
}

function M.print_stackframes()
  local frames = (session.threads[session.stopped_thread_id] or {}).frames or {}
  for _, frame in pairs(frames) do
    if frame.id == session.current_frame.id then
       M.append('→ '..frame.name)
    else
       M.append('  '..frame.name)
    end
  end
end

function M.open()
  if win and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf then
    return
  end
  if not buf then
    buf = api.nvim_create_buf(true, true)
    api.nvim_buf_set_name(buf, '[dap-repl]')
    api.nvim_buf_set_option(buf, 'buftype', 'prompt')
    api.nvim_buf_set_option(buf, 'omnifunc', 'v:lua.dap.omnifunc')
    vim.fn.prompt_setprompt(buf, 'dap> ')
    vim.fn.prompt_setcallback(buf, 'dap#repl_execute')
    api.nvim_buf_attach(buf, false, {
      on_detach = function()
        buf = nil
        return true
      end;
    })
  end
  local current_win = api.nvim_get_current_win()
  api.nvim_command('belowright new')
  win = api.nvim_get_current_win()
  api.nvim_win_set_buf(win, buf)
  api.nvim_set_current_win(current_win)
end


function M.append(line, lnum)
  if buf then
    if api.nvim_get_current_win() == win and lnum == '$' then
      lnum = nil
    end
    local lines = vim.split(line, '\n')
    vim.fn.appendbufline(buf, lnum or (vim.fn.line('$') - 1), lines)
    api.nvim_buf_set_option(buf, 'modified', false)
  end
end


function M.execute(text)
  if text == '' then
    if last_cmd then
      text = last_cmd
    else
      api.nvim_buf_set_option(buf, 'modified', false)
      return
    end
  else
    last_cmd = text
  end
  if vim.tbl_contains(M.commands.exit, text) then
    if session then
      session:disconnect()
    end
    api.nvim_buf_set_option(buf, 'modified', false)
    api.nvim_command('close')
    return
  end
  if not session then
    M.append('No active debug session')
    return
  end
  if vim.tbl_contains(M.commands.continue, text) then
    session:_step('continue')
  elseif vim.tbl_contains(M.commands.next_, text) then
    session:_step('next')
  elseif vim.tbl_contains(M.commands.into, text) then
    session:_step('stepIn')
  elseif vim.tbl_contains(M.commands.out, text) then
    session:_step('stepOut')
  elseif vim.tbl_contains(M.commands.up, text) then
    session:_frame_delta(1)
    M.print_stackframes()
  elseif vim.tbl_contains(M.commands.down, text) then
    session:_frame_delta(-1)
    M.print_stackframes()
  elseif vim.tbl_contains(M.commands.goto_, vim.split(text, ' ')[1]) then
    local split = vim.split(text, ' ')
    if split[2] then
      session:_goto(tonumber(split[2]))
    end
  elseif vim.tbl_contains(M.commands.scopes, text) then
    local frame = session.current_frame
    if frame then
      for _, scope in pairs(frame.scopes) do
        M.append(string.format("%s  (frame: %s)", scope.name, frame.name))
        for _, variable in pairs(scope.variables) do
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
  else
    local lnum = vim.fn.line('$') - 1
    session:evaluate(text, function(err, resp)
      if err then
        M.append(err.message, lnum)
      else
        M.append(resp.result, lnum)
      end
    end)
  end
end


function M.set_session(s)
  session = s
  last_cmd = nil
  if s and buf and api.nvim_buf_is_loaded(buf) then
    api.nvim_buf_set_lines(buf, 0, -1, true, {})
  end
end


return M
