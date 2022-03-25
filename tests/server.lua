local uv = vim.loop
local rpc = require('dap.rpc')

local json_decode = vim.json and vim.json.decode or vim.fn.json_decode
local json_encode = vim.json and vim.json.encode or vim.fn.json_encode

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
  table.insert(self.spy.responses, payload)
  if self.socket then
    self.socket:write(rpc.msg_with_content_length(json_encode(payload)))
  end

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
  table.insert(self.spy.responses, payload)
  if self.socket then
    self.socket:write(rpc.msg_with_content_length(json_encode(payload)))
  end
end


function Client:send_event(event, body)
  self.seq = self.seq + 1
  local payload = {
    seq = self.seq,
    type = 'event',
    event = event,
    body = body,
  }
  table.insert(self.spy.events, payload)
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


function Client:launch(request)
  self:send_response(request, {})
end


function M.spawn()
  local server = uv.new_tcp()
  local host = '127.0.0.1'
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
  server:bind(host, 0)
  local client = {
    seq = 0,
    handlers = {},
    spy = spy,
  }
  setmetatable(client, {__index = Client})
  server:listen(128, function(err)
    assert(not err, err)
    local socket = uv.new_tcp()
    client.socket = socket
    server:accept(socket)
    socket:read_start(rpc.create_read_loop(vim.schedule_wrap(function(body)
      client:handle_input(body)
    end)))
  end)
  return {
    client = client,
    adapter = {
      type = 'server',
      host = host;
      port = server:getsockname().port,
      options = {
        disconnect_timeout_sec = 0.1
      },
    },
    spy = spy,
    stop = function()
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
