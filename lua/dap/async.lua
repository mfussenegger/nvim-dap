local async = {}

--- Run a function in a coroutine with error handling via vim.notify
---
--- If run is called within a coroutine, no new coroutine is created.
function async.run(fn)
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

async.countdown = {}
---Invokes cb immediately if count == 0
---@param count integer
---@param cb fun()
function async.countdown.new(count, cb)
  assert(count >= 0, "Countdown counter should be >= 0")
  local called = false
  if count == 0 then
    called = true
    cb()
  end
  return function()
    count = count - 1
    if count == 0 and not called then
      cb()
      called = true
    end
  end
end

---Function that represents some deferred computation
---When called, accepts an `on_done` argument. on_done must be called
---when the computation is completed
---@alias dap.async.Thunk fun(on_done: fun())

---Await all thunks. Invoke on_done when all thunks are finished
---@param thunks dap.async.Thunk[]
---@param on_done fun()
function async.await_all(thunks, on_done)
  local countdown = async.countdown.new(#thunks, on_done)
  for _, thunk in ipairs(thunks) do
    thunk(countdown)
  end
end

return async
