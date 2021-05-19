local M = {}
local api = vim.api
local dap = require('dap')
local timer = nil


local function destroy_timer()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end


local function trigger_completion()
  destroy_timer()
  dap.omnifunc(1, "")
end


function M._InsertCharPre()
  if timer then
    return
  end
  if tonumber(vim.fn.pumvisible()) == 1 then
    return
  end
  local session = dap.session()
  if not session then
    return
  end
  local char = api.nvim_get_vvar('char')
  local capabilities = session.capabilities or {}
  local triggers = capabilities.completionTriggerCharacters or {'.'}
  if vim.tbl_contains(triggers, char) then
    timer = vim.loop.new_timer()
    timer:start(50, 0, vim.schedule_wrap(trigger_completion))
  end
end


function M._InsertLeave()
  destroy_timer()
end


function M.attach(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  vim.cmd(string.format(
    "autocmd InsertCharPre <buffer=%d> lua require('dap.ext.autocompl')._InsertCharPre()",
    bufnr
  ))
  vim.cmd(string.format(
    "autocmd InsertLeave <buffer=%d> lua require('dap.ext.autocompl')._InsertLeave()",
    bufnr
  ))
end


return M
