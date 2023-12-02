local M = {}
local dap = require("dap")
local assert = require("luassert")

function M.wait(predicate, msg)
  vim.wait(1000, predicate)
  local result = predicate()
  if type(msg) == "string" then
    assert.are_not.same(false, result, msg)
  else
    assert.are_not.same(false, result, msg and vim.inspect(msg()) or nil)
  end
  assert.are_not.same(nil, result)
end


---@param command string
---@return string[] commands received
function M.wait_for_response(server, command)
  local function received_command()
    for _, response in pairs(server.spy.responses) do
      if response.command == command then
        return true
      end
    end
    return false
  end
  local function get_command(x)
    return x.command
  end
  M.wait(received_command, function()
    if next(server.spy.responses) then
      local responses = vim.tbl_map(get_command, server.spy.responses)
      return string.format("Expected `%s` in: %s", command, table.concat(responses, ", "))
    else
      return "Server sent no responses, expected: " .. command
    end
  end)
  return vim.tbl_map(get_command, server.spy.responses)
end


function M.run_and_wait_until_initialized(conf, server)
  dap.run(conf)
  vim.wait(1000, function()
    local session = dap.session()
    -- wait for initialize and launch requests
    return (session and session.initialized and #server.spy.requests == 2 or false)
  end, 100)
  return assert(dap.session(), "Must have session after run")
end

return M
