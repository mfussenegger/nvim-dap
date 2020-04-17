dap = {} -- luacheck: ignore 111 - to support v:lua.dap... uses


local uv = vim.loop
local api = vim.api
local log = require('dap.log').create_logger('vim-dap.log')
local ui = require('dap.ui')
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
  self:request('threads', nil, function(err0, threads_resp)
    if err0 then
      print('Error retrieving threads: ' .. err0.message)
      return
    end
    local threads = {}
    self.threads = threads
    for _, thread in pairs(threads_resp.threads) do
      threads[thread.id] = thread
    end
    self:request('stackTrace', { threadId = stopped.threadId; }, function(err1, frames_resp)
      if err1 then
        print('Error retrieving stack traces: ' .. err1.message)
        return
      end
      local frames = {}
      local current_frame = nil
      threads[stopped.threadId].frames = frames
      for _, frame in pairs(frames_resp.stackFrames) do
        if not current_frame then
          current_frame = frame
          threads.current_frame = frame
        end
        frames[frame.id] = frame
      end
      if not current_frame then
        return
      end
      if current_frame.source then
        local bufnr = vim.uri_to_bufnr(vim.uri_from_fname(current_frame.source.path))
        vim.fn.sign_unplace(ns_pos, { buffer = bufnr })
        vim.fn.sign_place(0, ns_pos, 'DapStopped', bufnr, { lnum = current_frame.line; priority = 11 })
        if not stopped.preserveFocusHint then
          for _, win in pairs(api.nvim_list_wins()) do
            if api.nvim_win_get_buf(win) == bufnr then
              api.nvim_win_set_cursor(win, { current_frame.line, current_frame.column - 1 })
            end
          end
        end
      end

      self:request('scopes', { frameId = current_frame.id }, function(_, scopes_resp)
        if not scopes_resp or not scopes_resp.scopes then return end

        current_frame.scopes = {}
        local remaining = #scopes_resp.scopes
        for _, scope in pairs(scopes_resp.scopes) do

          table.insert(current_frame.scopes, scope)
          if not scope.expensive then
            self:request('variables', { variablesReference = scope.variablesReference }, function(_, variables_resp)
              if not variables_resp then return end

              scope.variables = variables_resp.variables
              vim.schedule(function()
                remaining = remaining - 1
                if remaining == 0 then
                  -- TODO:
                  -- ui.threads_render(threads)
                end
              end)
            end)
          end
        end
      end)
    end)
  end)
end


function Session:event_terminated()
  self:close()
  session = nil
  ui.threads_clear()
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
    threads = {};
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
  self.threads = {}
  self.message_callbacks = nil
  self.client:shutdown()
  self.client:close()
  require('dap.repl').set_session(nil)
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


function Session:evaluate(expression, fn)
  self:request('evaluate', {
    expression = expression;
    context = 'repl';
    frameId = (self.threads.current_frame or {}).id;
  }, fn)
end


function Session:_reset_stopped()
  local thread_id = self.stopped_thread_id
  self.stopped_thread_id = nil
  vim.fn.sign_unplace(ns_pos)
  return thread_id
end


function Session:continue()
  if not self.stopped_thread_id then
    print('No stopped thread. Cannot continue')
    return
  end
  local thread_id = self:_reset_stopped()
  self:request('continue', { threadId = thread_id; }, function(err0, _)
    if err0 then
      print("Error continueing: " .. err0.message)
    end
  end)
end

function Session:next()
  if not self.stopped_thread_id then
    print('No stopped thread. Cannot move')
    return
  end
  local thread_id = self:_reset_stopped()
  session:request('next', { threadId = thread_id; })
end


function M.step_over()
  if not session then return end
  session:next()
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
  session:continue()
end


function M.repl()
  require('dap.repl').open()
end


local function completions_to_items(completions, prefix)
  local candidates = vim.tbl_filter(
    function(item) return vim.startswith(item.text or item.label, prefix) end,
    completions
  )
  if #candidates == 0 then
    return {}
  end

  if candidates[1].sortText then
    table.sort(candidates, function(a, b) return (a.sortText or 0) < (b.sortText or 0) end)
  end

  local items = {}
  for _, candidate in pairs(candidates) do
    table.insert(items, {
      word = candidate.text or candidate.label;
      abbr = candidate.label;
      dup = 0;
      icase = 1;
    })
  end
  return items
end


function dap.omnifunc(findstart, base) -- luacheck: ignore 112
  local supportsCompletionsRequest = ((session or {}).capabilities or {}).supportsCompletionsRequest;
  local _ = log.debug() and log.debug('omnifunc.findstart', {
    findstart = findstart;
    base = base;
    supportsCompletionsRequest = supportsCompletionsRequest;
  })
  if not supportsCompletionsRequest then
    if findstart == 1 then
      return -1
    else
      return {}
    end
  end
  local col = api.nvim_win_get_cursor(0)[2]
  local line = api.nvim_get_current_line()
  local offset = vim.startswith(line, 'dap> ') and 5 or 0
  local line_to_cursor = line:sub(offset + 1, col)
  local text_match = vim.fn.match(line_to_cursor, '\\k*$')
  local prefix = line_to_cursor:sub(text_match + 1)

  local _ = log.debug() and log.debug('omnifunc.line', {
    line = line;
    col = col - offset;
    line_to_cursor = line_to_cursor;
    text_match = text_match + offset;
    prefix = prefix;
  })

  session:request('completions', {
    frameId = (session.threads.current_frame or {}).id;
    text = line_to_cursor;
    column = col - offset;
  }, function(err, response)
    if err then
      local _ = log.error() and log.error('completions.callback', err.message)
      return
    end

    local items = completions_to_items(response.targets, prefix)
    vim.fn.complete(offset + text_match + 1, items)
  end)

  -- cancel but stay in completion mode for completion via `completions` callback
  return -2
end


function M.attach(config)
  if session then
    session:close()
  end
  session = Session:connect(config)
  require('dap.repl').set_session(session)
  session:request('initialize', {
    clientId = 'neovim';
    clientname = 'neovim';
    adapterID = 'nvim-dap';
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
  return session
end


function M.set_log_level(level)
  log.set_level(level)
end


return M
