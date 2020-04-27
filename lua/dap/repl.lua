local api = vim.api
local M = {}

local win = nil
local buf = nil
local session = nil


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


local function append(line, lnum)
  if buf then
    vim.fn.appendbufline(buf, lnum or (vim.fn.line('$') - 1), line)
    api.nvim_buf_set_option(buf, 'modified', false)
  end
end


function M.execute(text)
  if text == '' then
    api.nvim_buf_set_option(buf, 'modified', false)
    return
  end
  if text == 'exit' or text == '.exit' then
    api.nvim_buf_set_option(buf, 'modified', false)
    api.nvim_command('close')
  end
  if not session then
    append('No active debug session')
    return
  end
  if text == '.continue' or text == '.c' then
    session:_step('continue')
  elseif text == '.next' or text == '.n' then
    session:_step('next')
  elseif text == '.into' then
    session:_step('stepIn')
  elseif text == '.out' then
    session:_step('stepOut')
  elseif text == '.scopes' then
    local frame = session.current_frame
    if frame then
      for _, scope in pairs(frame.scopes) do
        append(string.format("%s  (frame: %s)", scope.name, frame.name))
        for _, variable in pairs(scope.variables) do
          append(string.rep(' ', 2) .. variable.name .. ': ' .. variable.value)
        end
      end
    end
  elseif text == '.threads' then
    for _, thread in pairs(session.threads) do
      if session.stopped_thread_id == thread.id then
        append('→ ' .. thread.name)
      else
        append('  ' .. thread.name)
      end
    end
  elseif text == '.frames' then
    local frames = (session.threads[session.stopped_thread_id] or {}).frames
    for _, frame in pairs(frames) do
      append(frame.name)
    end
  else
    local lnum = vim.fn.line('$') - 1
    session:evaluate(text, function(err, resp)
      if err then
        append(err.message, lnum)
      else
        append(resp.result, lnum)
      end
    end)
  end
end


function M.set_session(s)
  session = s
end


return M
