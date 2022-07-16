local server = require('tests.server')
local opts = {
  port = _G.DAP_PORT
}
io.stdout:setvbuf("no")
io.stderr:setvbuf("no")
local debug_adapter = server.spawn(opts)
io.stderr:write("Listening on port=" .. debug_adapter.adapter.port .. "\n")
local original_disconnect = debug_adapter.client.disconnect
debug_adapter.client.disconnect = function(self, request)
  original_disconnect(self, request)
  os.exit(0)
end
vim.loop.run()
vim.loop.walk(vim.loop.close)
vim.loop.run()
