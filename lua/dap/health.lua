local M = {}

---@param command string?
local function check_executable(command)
  local health = vim.health
  if not command then
    health.error("Missing required `command` property")
  else
    if vim.fn.executable(command) ~= 1 then
      health.error(table.concat({
        "`command` is not executable.",
        "Check path and permissions.",
        "Use vim.fn.expand to handle ~ or $HOME:\n  ",
        command
      }, " "))
    else
      health.ok("is executable: " .. command)
    end
  end
end


function M.check()
  local health = vim.health
  if not health or not health.start then
    return
  end
  health.start("dap: Adapters")
  local dap = require("dap")
  for t, adapter in pairs(dap.adapters) do
    health.start("dap.adapter: " .. t)
    if type(adapter) == "function" then
      health.info("Adapter is a function. Can't validate it")
    else
      if adapter.type == "executable" then
        adapter = adapter --[[@as dap.ExecutableAdapter]]
        check_executable(adapter.command)
      elseif adapter.type == "server" then
        adapter = adapter --[[@as dap.ServerAdapter]]
        if not adapter.port then
          health.error("Missing required `port` property")
        end
        if adapter.executable then
          check_executable(adapter.executable.command)
        end
      elseif adapter.type == "pipe" then
        adapter = adapter --[[@as dap.PipeAdapter]]
        if not adapter.pipe then
          health.error("Missing required `pipe` property")
        end
      else
        health.error(adapter.type .. " must be one of: executable, server or pipe")
      end
    end
  end

  health.start("dap: Sessions")
  local sessions = dap.sessions()
  if not next(sessions) then
    health.ok("No active sessions")
  else
    for _, session in pairs(sessions) do
      if session.initialized then
        health.ok("  id: " .. session.id .. "\n  type: " .. session.config.type)
      else
        health.warn(table.concat({
          "\n  id: ", session.id,
          "\n  type: ", session.config.type,
          "\n  started, but not initialized. ",
          "Either the adapter definition or the used configuration is wrong, ",
          "or the defined adapter doesn't speak DAP",
        }))
      end
    end
  end
end


return M
