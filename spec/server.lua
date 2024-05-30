local uv = vim.loop
local rpc = require('dap.rpc')

local json_decode = vim.json.decode
local json_encode = vim.json.encode

local M = {}
local Client = {}


function Client:send_err_response(request, message, error)
  self.seq = request.seq + 1
  local payload = {
    seq = self.seq,
    type = 'response',
    command = request.command,
    success = false,
    request_seq = request.seq,
    message = message,
    body = {
      error = error,
    },
  }
  if self.socket then
    self.socket:write(rpc.msg_with_content_length(json_encode(payload)))
  end
  table.insert(self.spy.responses, payload)
end


function Client:send_response(request, body)
  self.seq = request.seq + 1
  local payload = {
    seq = self.seq,
    type = 'response',
    command = request.command,
    success = true,
    request_seq = request.seq,
    body = body,
  }
  if self.socket then
    self.socket:write(rpc.msg_with_content_length(json_encode(payload)))
  end
  table.insert(self.spy.responses, payload)
end


function Client:send_event(event, body)
  self.seq = self.seq + 1
  local payload = {
    seq = self.seq,
    type = 'event',
    event = event,
    body = body,
  }
  self.socket:write(rpc.msg_with_content_length(json_encode(payload)))
  table.insert(self.spy.events, payload)
end


---@param command string
---@param arguments any
function Client:send_request(command, arguments)
  self.seq = self.seq + 1
  local payload = {
    seq = self.seq,
    type = "request",
    command = command,
    arguments = arguments,
  }
  self.socket:write(rpc.msg_with_content_length(json_encode(payload)))
end


function Client:handle_input(body)
  local request = json_decode(body)
  table.insert(self.spy.requests, request)
  local handler = self[request.command]
  if handler then
    handler(self, request)
  else
    print('no handler for ' .. request.command)
  end
end


function Client:initialize(request)
  self:send_response(request, {})
  self:send_event('initialized', {})
end


function Client:disconnect(request)
  self:send_event('terminated', {})
  self:send_response(request, {})
end


function Client:terminate(request)
  self:send_event('terminated', {})
  self:send_response(request, {})
end


function Client:launch(request)
  self:send_response(request, {})
end


function M.spawn(opts)
  opts = opts or {}
  opts.mode = opts.mode or "tcp"
  local spy = {
    requests = {},
    responses = {},
    events = {},
  }
  function spy.clear()
    spy.requests = {}
    spy.responses = {}
    spy.events = {}
  end
  local adapter
  local server
  if opts.mode == "tcp" then
    server = assert(uv.new_tcp())
    assert(server:bind("127.0.0.1", opts.port or 0), "Must be able to bind to ip:port")
    adapter = {
      type = "server",
      host = "127.0.0.1",
      port = server:getsockname().port,
      options = {
        disconnect_timeout_sec = 0.1
      }
    }
  else
    server = assert(uv.new_pipe())
    local pipe = os.tmpname()
    os.remove(pipe)
    assert(server:bind(pipe), "Must be able to bind to pipe")
    adapter = {
      type = "pipe",
      pipe = pipe,
      options = {
        disconnect_timeout_sec = 0.1
      }
    }
  end
  local client = {
    seq = 0,
    handlers = {},
    spy = spy,
    num_connected = 0,
  }
  setmetatable(client, {__index = Client})
  server:listen(128, function(err)
    assert(not err, err)
    client.num_connected = client.num_connected + 1
    local socket = assert(opts.mode == "tcp" and uv.new_tcp() or uv.new_pipe())
    client.socket = socket
    server:accept(socket)
    local function on_chunk(body)
      client:handle_input(body)
    end
    local function on_eof()
      client.num_connected = client.num_connected - 1
    end
    socket:read_start(rpc.create_read_loop(on_chunk, on_eof))
  end)
  return {
    client = client,
    adapter = adapter,
    spy = spy,
    stop = function()
      if opts.mode ~= "tcp" then
        pcall(os.remove, adapter.pipe)
      end
      if client.socket then
        client.socket:shutdown(function()
          client.socket:close()
          client.socket = nil
        end)
      end
    end,
  }
end


return M
