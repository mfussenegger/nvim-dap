local M = {}
local api = vim.api
local timer = nil


local function destroy_timer()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end


local function trigger_completion(buf)
  destroy_timer()
  if api.nvim_get_current_buf() == buf then
    api.nvim_feedkeys(api.nvim_replace_termcodes('<C-x><C-o>', true, false, true), 'm', true)
  end
end


function M._InsertCharPre()
  if timer then
    return
  end
  if tonumber(vim.fn.pumvisible()) == 1 then
    return
  end
  local buf = api.nvim_get_current_buf()
  local char = api.nvim_get_vvar('char')
  local session = require('dap').session()
  local trigger_characters = ((session or {}).capabilities or {}).completionTriggerCharacters
  local triggers
  if trigger_characters and next(trigger_characters) then
    triggers = trigger_characters
  else
    triggers = {'.'}
  end
  if vim.tbl_contains(triggers, char) then
    timer = vim.loop.new_timer()
    timer:start(50, 0, vim.schedule_wrap(function()
      trigger_completion(buf)
    end))
  end
end


function M._InsertLeave()
  destroy_timer()
end


function M.attach(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  if api.nvim_create_autocmd then
    local group = api.nvim_create_augroup(("dap.ext.autocmpl-%d"):format(bufnr), { clear = true })
    api.nvim_create_autocmd("InsertCharPre", {
      group = group,
      buffer = bufnr,
      callback = function()
        pcall(M._InsertCharPre)
      end,
    })
    api.nvim_create_autocmd("InsertLeave", {
      group = group,
      buffer = bufnr,
      callback = destroy_timer
    })
  else
    vim.cmd(string.format([[
      augroup dap_autocomplete-%d
      au!
      autocmd InsertCharPre <buffer=%d> lua require('dap.ext.autocompl')._InsertCharPre()
      autocmd InsertLeave <buffer=%d> lua require('dap.ext.autocompl')._InsertLeave()
      augroup end
      ]],
      bufnr,
      bufnr,
      bufnr
    ))
  end
end


return M
