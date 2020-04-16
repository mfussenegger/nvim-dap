local uv = vim.loop
local api = vim.api
local log = require'dap.log'.create_logger('vim-dap.log')
local M = {}
local ns_breakpoints = 'dap_breakpoints'
local ns_pos = 'dap_pos'
local Session = {}
local session = nil


vim.fn.sign_define('DapBreakpoint', {text='B', texthl='', linehl='', numhl=''})
vim.fn.sign_define('DapStopped', {text='→', texthl='', linehl='debugPC', numhl=''})


local function msg_with_content_length(msg)
  return table.concat {
    'Content-Length: ';
    tostring(#msg);
    '\r\n\r\n';
    msg
  }
end

-- Copied from neovim rpc.lua
local function parse_headers(header)
  if type(header) ~= 'string' then
    return nil
  end
  local headers = {}
  for line in vim.gsplit(header, '\r\n', true) do
    if line == '' then
      break
    end
    local key, value = line:match('^%s*(%S+)%s*:%s*(.+)%s*$')
    if key then
      key = key:lower():gsub('%-', '_')
      headers[key] = value
    else
      error(string.format("Invalid header line %q", line))
    end
  end
  headers.content_length = tonumber(headers.content_length)
    or error(string.format("Content-Length not found in headers. %q", header))
  return headers
end


-- Mostly copied from neovim rpc.lua
local header_start_pattern = ("content"):gsub("%w", function(c) return "["..c..c:upper().."]" end)
local function parse_chunk_loop()
  local buffer = ''
  while true do
    local start, finish = buffer:find('\r\n\r\n', 1, true)
    if start then
      local buffer_start = buffer:find(header_start_pattern)
      local headers = parse_headers(buffer:sub(buffer_start, start - 1))
      buffer = buffer:sub(finish + 1)
      local content_length = headers.content_length
      while #buffer < content_length do
        buffer = buffer .. (coroutine.yield()
          or error("Expected more data for the body. The server may have died."))
      end
      local body = buffer:sub(1, content_length)
      buffer = buffer:sub(content_length + 1)
      buffer = buffer .. (coroutine.yield(headers, body)
        or error("Expected more data for the body. The server may have died."))
    else
      buffer = buffer .. (coroutine.yield()
        or error("Expected more data for the header. The server may have died."))
    end
  end
end


function Session:event_initialized(_)
  self.initialized = true
  self:set_breakpoints('')

  if self.capabilities.supportsConfigurationDoneRequest then
    -- TODO: does the client have to wait for setBreakpoints response and so on?
    self:request('configurationDone', nil, function(err1, _)
      if err1 then
        print(err1.message)
      end
    end)
  end
end


function Session:event_stopped(stopped)
  self.stopped_thread_id = stopped.threadId
  self:request('threads', nil, function() end)
  self:request('stackTrace', { threadId = stopped.threadId; }, function(_, frames)
    if frames.stackFrames and #frames.stackFrames > 0 then
      local last_frame = frames.stackFrames[1]
      if last_frame.source then
        local bufnr = vim.uri_to_bufnr(vim.uri_from_fname(last_frame.source.path))
        vim.fn.sign_unplace(ns_pos, { buffer = bufnr })
        vim.fn.sign_place(0, ns_pos, 'DapStopped', bufnr, { lnum = last_frame.line; priority = 20 })
      end

      self:request('scopes', { frameId = last_frame.id }, function(_, scopes)
        if not scopes or not scopes.scopes or #scopes.scopes < 1 then return end

        local scope = scopes.scopes[1]
        self:request('variables', { variablesReference = scope.variablesReference }, function(_, variables)
          print(vim.inspect(variables))
        end)
      end)
    end
  end)
end


function Session:event_terminated()
  self:close()
  session = nil
end


function Session:set_breakpoints(bufexpr)
  local bp_signs = vim.fn.sign_getplaced(bufexpr, {group = ns_breakpoints})
  for _, buf_bp_signs in pairs(bp_signs) do
    local breakpoints = {}
    local bufnr = buf_bp_signs.bufnr
    for _, bp in pairs(buf_bp_signs.signs) do
      table.insert(breakpoints, { line = bp.lnum; })
    end
    self:request('setBreakpoints', {
        source = { path = vim.fn.expand('#' .. bufnr .. ':p'); };
        breakpoints = breakpoints;
      },
      function (err1, _)
        if err1 then
          print("Error setting breakpoints: " .. err1.message)
          return
        end
      end
    )
  end
end


function Session:handle_body(body)
  local decoded = vim.fn.json_decode(body)
  self.seq = decoded.seq + 1
  local _ = log.debug() and log.debug(decoded)
  if decoded.request_seq then
    local callback = self.message_callbacks[decoded.request_seq]
    if not callback then return end
    self.message_callbacks[decoded.request_seq] = nil
    if decoded.success then
      callback(nil, decoded.body)
    else
      callback({ message = decoded.message; body = decoded.body; }, nil)
    end
  elseif decoded.event then
    local callback = self['event_' .. decoded.event]
    if callback then
      callback(self, decoded.body)
    end
  end
end


function Session:connect(config)
  local port = tonumber(config.port)
  local client = uv.new_tcp()
  local o = {
    message_callbacks = {};
    initialized = false;
    client = client;
    config = config;
    seq = 0;
    stopped_thread_id = nil;
  }
  client:connect('127.0.0.1', port, function(err)
    if (err) then print(err) end
  end)
  local parse_chunk = coroutine.wrap(parse_chunk_loop)
  parse_chunk()
  client:read_start(function (err, chunk)
    if err then
      print(err)
      return
    end
    if not chunk then
      return
    end
    while true do
      local headers, body = parse_chunk(chunk)
      if headers then
        vim.schedule(function()
          session:handle_body(body)
        end)
        chunk = ''
      else
        break
      end
    end
  end)
  setmetatable(o, self)
  self.__index = self
  return o
end


function Session:close()
  vim.fn.sign_unplace(ns_pos)

  self.message_callbacks = nil
  self.client:shutdown()
  self.client:close()
end


function Session:request(command, arguments, callback)
  local payload = {
    seq = self.seq;
    type = 'request';
    command = command;
    arguments = arguments
  }
  local _ = log.debug() and log.debug(payload)
  local current_seq = self.seq
  self.seq = self.seq + 1
  vim.schedule(function()
    local msg = msg_with_content_length(vim.fn.json_encode(payload))
    self.client:write(msg)
    if callback then
      self.message_callbacks[current_seq] = vim.schedule_wrap(callback)
    end
  end)
end


function Session:attach(config)
  self:request('attach', config)
end


function M.step_over()
  if not session then return end

  session:request('next', { threadId = session.stopped_thread_id })
end

function M.step_into()
  if not session then return end

  session:request('stepIn', { threadId = session.stopped_thread_id })
end

function M.step_out()
  if not session then return end

  session:request('stepOut', { threadId = session.stopped_thread_id })
end

function M.stop()
  if session then
    session:close()
    session = nil
  end
end

function M.restart()
  if not session then return end
  if session.capabilities.supportsRestartRequest then
    session:request('restart', nil, function(err0, _)
      if err0 then
        print('Error restarting debug adapter: ' .. err0.message)
      else
        print('Restarted debug adapter')
      end
    end)
  else
    print('Restart not supported')
  end
end

function M.toggle_breakpoint()
  local bufnr = api.nvim_get_current_buf()
  local row, _ = unpack(api.nvim_win_get_cursor(0))
  local signs = vim.fn.sign_getplaced(bufnr, { group = ns_breakpoints; lnum = row; })[1].signs
  if signs and #signs > 0 then
    for _, sign in pairs(signs) do
      vim.fn.sign_unplace(ns_breakpoints, { buffer = bufnr; id = sign.id; })
    end
  else
    vim.fn.sign_place(0, ns_breakpoints, 'DapBreakpoint', bufnr, { lnum = row })
  end
  if session and session.initialized then
    session:set_breakpoints(bufnr)
  end
end


function M.continue()
  if not session then return end

  session:request('continue', { threadId = session.stopped_thread_id; }, function(err0, _)
    if err0 then
      print("Error continueing: " .. err0.message)
    end
  end)
end


function M.attach(config)
  if session then
    session:close()
  end
  session = Session:connect(config)
  session:request('initialize', {
    clientId = 'neovim';
    clientname = 'neovim';
    adapterID = 'neovim';
    pathFormat = 'path';
    columnsStartAt1 = false;
    locale = os.getenv('LANG') or 'en_US';
  }, function(err0, result)
    if err0 then
      print("Could not initialize debug adapter: " .. err0.message)
      return
    end
    session.capabilities = result
    session:attach(config)
  end)
end


function M.set_log_level(level)
  log.set_level(level)
end


return M
