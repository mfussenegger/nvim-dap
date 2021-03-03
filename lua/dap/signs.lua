
local reloadable = require('dap.reloadable')

local bp_info = reloadable.get_value('BpInfo')
local ns_breakpoints = require('dap.constants').ns_breakpoints

local M = {}

function M.get_breakpoints(bufexpr)
  if bufexpr then
    return vim.fn.sign_getplaced(bufexpr, {group = ns_breakpoints})
  end
  local bufs_with_signs = vim.fn.sign_getplaced()
  local result = {}
  for _, buf_signs in ipairs(bufs_with_signs) do
    buf_signs = vim.fn.sign_getplaced(buf_signs.bufnr, {group = ns_breakpoints})[1]
    if #buf_signs.signs > 0 then
      table.insert(result, buf_signs)
    end
  end
  return result
end


function M.remove_breakpoints(bufnr, lnum)
  local signs = vim.fn.sign_getplaced(bufnr, { group = ns_breakpoints; lnum = lnum; })[1].signs
  if signs and #signs > 0 then
    for _, sign in pairs(signs) do
      vim.fn.sign_unplace(ns_breakpoints, { buffer = bufnr; id = sign.id; })
      bp_info[sign.id] = nil
    end
    return true
  else
    return false
  end
end

return M
