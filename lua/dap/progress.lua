local M = {}
local messages = {}

local max_size = 11
local idx_read = 0
local idx_write = 0

local last_msg = nil


function M.reset()
  messages = {}
  idx_read = 0
  idx_write = 0
  last_msg = nil
end


---@param msg string
function M.report(msg)
  messages[idx_write] = msg
  idx_write = (idx_write + 1) % max_size
  if idx_write == idx_read then
    idx_read = (idx_read + 1) % max_size
  end

  if vim.in_fast_event() then
    vim.schedule(function()
      vim.cmd('doautocmd <nomodeline> User DapProgressUpdate')
    end)
  else
    vim.cmd('doautocmd <nomodeline> User DapProgressUpdate')
  end
end


---@return string?
function M.poll_msg()
  if idx_read == idx_write then
    return nil
  end
  local msg = messages[idx_read]
  messages[idx_read] = nil
  idx_read = (idx_read + 1) % max_size
  return msg
end


---@return string
function M.status()
  local msg = M.poll_msg() or last_msg
  if msg then
    last_msg = msg
    return msg
  else
    return ''
  end
end


return M
