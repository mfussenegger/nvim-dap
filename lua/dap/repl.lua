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


function M.execute(text)
  if text == '' then
    api.nvim_command('set nomodified')
    return
  end
  if text == 'exit' then
    api.nvim_command('set nomodified')
    api.nvim_command('close')
  end
  local function append(line)
    if buf then
      vim.fn.appendbufline(buf, vim.fn.line('$') - 1, line)
    end
    api.nvim_command('set nomodified')
  end
  if not session then
    append('No active debug session')
    return
  end
  session:evaluate(text, function(err, resp)
    if err then
      append(err.message)
    else
      append(resp.result)
    end
  end)
end


function M.set_session(s)
  session = s
end


return M
