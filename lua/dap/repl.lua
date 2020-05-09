local api = vim.api
local M = {}

local win = nil
local buf = nil
local session = nil

M.commands = {
  continue = {'.continue', '.c'},
  next_ = {'.next', '.n'},
  into = {'.into'},
  out = {'.out'},
  scopes = {'.scopes'},
  threads = {'.threads'},
  frames = {'.frames'},
  exit = {'exit', '.exit'},
}

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
    api.nvim_buf_set_option(buf, 'modified', false)
    return
  end
  if vim.tbl_contains(M.commands.exit, text) then
    api.nvim_buf_set_option(buf, 'modified', false)
    api.nvim_command('close')
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
    local frames = (session.threads[session.stopped_thread_id] or {}).frames
    for _, frame in pairs(frames) do
      M.append(frame.name)
    end
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
  if s and buf and api.nvim_buf_is_loaded(buf) then
    api.nvim_buf_set_lines(buf, 0, -1, true, {})
  end
end


return M
