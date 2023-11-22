local M = {}

--- Run a function in a coroutine with error handling via vim.notify
---
--- If run is called within a coroutine, no new coroutine is created.
function M.run(fn)
  local co, is_main = coroutine.running()
  if co and not is_main then
    fn()
  else
    coroutine.wrap(function()
      xpcall(fn, function(err)
        local msg = debug.traceback(err, 2)
        require("dap.utils").notify(msg, vim.log.levels.ERROR)
      end)
    end)()
  end
end

return M
