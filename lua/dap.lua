dap = {} -- luacheck: ignore 111 - to support v:lua.dap... uses


local uv = vim.loop
local api = vim.api
local log = require('dap.log').create_logger('vim-dap.log')
local ui = require('dap.ui')
local repl = require('dap.repl')
local M = {}
local ns_breakpoints = 'dap_breakpoints'
local ns_pos = 'dap_pos'
local Session = {}
local session = nil

--- For extension of language specific debug adapters.
--
-- `adapters.<type>` where <type> is specified in a configuration.
--
-- For example:
--
-- require('dap').adapters.python = {
--    type = 'executable';
--    command = '/path/to/python';
--    args = {'-m', 'debugpy.adapter' };
-- }
--
-- TODO:
--  Support functions like:
--
--    require('dap').adapters.java = function(callback) ... end
--
M.adapters = {}


--- Configurations for languages
--
-- Example:
--
-- require('dap').configurations.python = {
--  {
--    type = 'python';
--    request = 'launch';
--    name = "Launch file";
--
--    -- ${file} and ${workspaceFolder} variables are supported
--    program = "${file}";
--
--    -- values other than type, request and name can be functions, they'll be evaluated when the configuration is used
--    pythonPath = function()
--      local cwd = vim.fn.getcwd()
--      if vim.fn.executable(cwd .. '/venv/bin/python') then
--        return cwd .. '/venv/bin/python'
--      elseif vim.fn.executable(cwd .. '/.venv/bin/python') then
--        return cwd .. '/.venv/bin/python'
--      else
--        return '/usr/bin/python'
--      end
--    end;
--  }
-- }
--
-- TODO:
--  - config file support (like .vscode/launch.json)
--  - dynamic configurations (In java you could have a mainclass discovery that creates launch configurations)
M.configurations = {}


vim.fn.sign_define('DapBreakpoint', {text='B', texthl='', linehl='', numhl=''})
vim.fn.sign_define('DapStopped', {text='→', texthl='', linehl='debugPC', numhl=''})


local function expand_config_variables(option)
  if type(option) == 'function' then
    option = option()
  end
  if type(option) ~= "string" then
    return option
  end
  local variables = {
    file = vim.fn.expand("%");
    workspaceFolder = vim.fn.getcwd();
  }
  local ret = option
  for key, val in pairs(variables) do
    ret = ret:gsub('${' .. key .. '}', val)
  end
  return ret
end


local function handle_adapter(adapter, configuration)
  assert(type(adapter) == 'table', 'adapter must be a table, not' .. vim.inspect(adapter))
  if adapter.type == 'executable' then
    M.launch(adapter, configuration)
  elseif adapter.type == 'server' then
    M.attach(adapter.host, adapter.port, configuration)
  else
    print(string.format('Invalid adapter type %s, expected `executable` or `server`', adapter.type))
  end
end


local function launch_debug_adapter()
  local filetype = api.nvim_buf_get_option(0, 'filetype')
  local configurations = M.configurations[filetype] or {}
  local configuration = ui.pick_one(configurations, "Configuration: ", function(i) return i.name end)
  if not configuration then
    print('No configuration found for ' .. filetype)
    return
  end

  configuration = vim.tbl_map(expand_config_variables, configuration)
  local adapter = M.adapters[configuration.type]
  if type(adapter) == 'table' then
    handle_adapter(adapter, configuration)
  elseif type(adapter) == 'function' then
    adapter(function(resolved_adapter)
      handle_adapter(resolved_adapter, configuration)
    end)
  else
    print(string.format('Invalid adapter: %q', adapter))
  end
end


function Session:run_in_terminal(request)
  local body = request.arguments
  -- env option is ignored without https://github.com/neovim/neovim/pull/11839
  local opts = {
    clear_env = false;
    env = body.env;
  }
  local _ = log.debug() and log.debug('run_in_terminal', body.args, opts)
  local win = api.nvim_get_current_win()
  api.nvim_command('belowright new')
  local jobid = vim.fn.termopen(body.args, opts)
  api.nvim_set_current_win(win)
  if jobid == 0 or jobid == -1 then
    local _ = log.error() and log.error('Could not spawn terminal', jobid, request)
    self:response(request, {
      success = false;
      message = 'Could not spawn terminal';
    })
  else
    self:response(request, {
      success = true;
      body = {
        processId = vim.fn.jobpid(jobid);
      };
    })
  end
end


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
  self:set_breakpoints('', function()
    if self.capabilities.supportsConfigurationDoneRequest then
      self:request('configurationDone', nil, function(err1, _)
        if err1 then
          print(err1.message)
        end
        self.initialized = true
      end)
    else
      self.initialized = true
    end
  end)
end


local function jump_to_frame(frame, preserve_focus_hint)
  if not frame.source then
    return
  end
  local bufnr = vim.uri_to_bufnr(vim.uri_from_fname(frame.source.path))
  vim.fn.sign_unplace(ns_pos, { buffer = bufnr })
  vim.fn.sign_place(0, ns_pos, 'DapStopped', bufnr, { lnum = frame.line; priority = 11 })
  if preserve_focus_hint then
    return
  end
  for _, win in pairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(win) == bufnr then
      api.nvim_win_set_cursor(win, { frame.line, frame.column - 1 })
      return
    end
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
      self.current_frame = nil
      threads[stopped.threadId].frames = frames
      for _, frame in pairs(frames_resp.stackFrames) do
        if not current_frame then
          current_frame = frame
          self.current_frame = frame
        end
        frames[frame.id] = frame
      end
      if not current_frame then
        return
      end
      jump_to_frame(current_frame, stopped.preserveFocusHint)

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

function Session.event_exited()
end

function Session.event_module()
end

function Session.event_process()
end

function Session.event_thread()
end

function Session.event_continued()
end

function Session.event_output(_, body)
  -- No output window yet, log for now.
  if body.category == 'stderr' then
    local _ = log.error() and log.error("output", body.output)
  else
    local _ = log.info() and log.info("output", body.output)
  end
end


function Session:set_breakpoints(bufexpr, on_done)
  local bp_signs = vim.fn.sign_getplaced(bufexpr, {group = ns_breakpoints})
  local num_bufs = #bp_signs
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
        num_bufs = num_bufs - 1
        if err1 then
          print("Error setting breakpoints: " .. err1.message)
          return
        end
        if num_bufs == 0 and on_done then
          on_done()
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
    else
      local _ = log.warn() and log.warn('No event handler for ', decoded)
    end
  elseif decoded.type == 'request' and decoded.command == 'runInTerminal' then
    self:run_in_terminal(decoded)
  else
    local _ = log.warn() and log.warn('Received unexpected message', decoded)
  end
end


local function session_defaults()
  return {
    message_callbacks = {};
    initialized = false;
    seq = 0;
    stopped_thread_id = nil;
    current_frame = nil;
    threads = {};
  }
end


local function create_read_loop(handle_body)
  local parse_chunk = coroutine.wrap(parse_chunk_loop)
  parse_chunk()
  return function (err, chunk)
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
          handle_body(body)
        end)
        chunk = ''
      else
        break
      end
    end
  end
end


function Session:connect(host, port)
  local o = session_defaults()
  setmetatable(o, self)
  self.__index = self

  local client = uv.new_tcp()
  o.client = {
    write = function(line) client:write(line) end;
    close = function()
      client:shutdown()
      client:close()
    end;
  }
  client:connect(host or '127.0.0.1', tonumber(port), function(err)
    if (err) then print(err) end
  end)
  client:read_start(create_read_loop(function(body) session:handle_body(body) end))
  return o
end


function Session:spawn(adapter)
  local o = session_defaults()
  setmetatable(o, self)
  self.__index = self

  local stdin = uv.new_pipe(false)
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)
  local handle
  local function onexit()
    stdin:close()
    stdout:close()
    stderr:close()
    handle:close()
  end
  local options = adapter.options or {}
  handle = uv.spawn(adapter.command, {
    args = adapter.args;
    stdio = {stdin, stdout, stderr};
    cwd = options.cwd;
    env = options.env;
  }, onexit)[1]
  o.client = {
    write = function(line) stdin:write(line) end;
    close = function()
      if handle then
        handle:close()
      end
    end;
  }
  stdout:read_start(create_read_loop(function(body) session:handle_body(body) end))
  stderr:read_start(function(err, chunk)
    assert(not err, err)
    if chunk then
      local _ = log.error() and log.error("stderr", adapter, chunk)
    end
  end)
  return o
end


function Session:close()
  vim.fn.sign_unplace(ns_pos)
  self.threads = {}
  self.message_callbacks = nil
  self.client.close()
  repl.set_session(nil)
end


function Session:request(command, arguments, callback)
  local payload = {
    seq = self.seq;
    type = 'request';
    command = command;
    arguments = arguments
  }
  local _ = log.debug() and log.debug('request', payload)
  local current_seq = self.seq
  self.seq = self.seq + 1
  vim.schedule(function()
    local msg = msg_with_content_length(vim.fn.json_encode(payload))
    self.client.write(msg)
    if callback then
      self.message_callbacks[current_seq] = vim.schedule_wrap(callback)
    end
  end)
end


function Session:response(request, payload)
  payload.seq = self.seq
  self.seq = self.seq + 1
  payload.type = 'response'
  payload.request_seq = request.seq;
  payload.command = request.command;
  local _ = log.debug() and log.debug('response', payload)
  vim.schedule(function()
    local msg = msg_with_content_length(vim.fn.json_encode(payload))
    self.client.write(msg)
  end)
end


function Session:initialize(config)
  self:request('initialize', {
    clientId = 'neovim';
    clientname = 'neovim';
    adapterID = 'nvim-dap';
    pathFormat = 'path';
    columnsStartAt1 = true;
    supportsRunInTerminalRequest = true;
    locale = os.getenv('LANG') or 'en_US';
  }, function(err0, result)
    if err0 then
      print("Could not initialize debug adapter: " .. err0.message)
      return
    end
    session.capabilities = result
    session:request(config.request, config, function(err)
      if err then
        print(string.format('Error on %s: %s', config.request, err.message))
        return
      end
      repl.set_session(session)
    end)
  end)
end


function Session:evaluate(expression, fn)
  self:request('evaluate', {
    expression = expression;
    context = 'repl';
    frameId = (self.current_frame or {}).id;
  }, fn)
end


function Session:_step(step)
  if not self.stopped_thread_id then
    print('No stopped thread. Cannot move')
    return
  end
  local thread_id = self.stopped_thread_id
  self.stopped_thread_id = nil
  vim.fn.sign_unplace(ns_pos)
  session:request(step, { threadId = thread_id; }, function(err0, _)
    if err0 then
      print('Error on '.. step .. ': ' .. err0.message)
    end
  end)
end


function M.step_over()
  if not session then return end
  session:_step('next')
end

function M.step_into()
  if not session then return end
  session:_step('stepIn')
end

function M.step_out()
  if not session then return end
  session:_step('stepOut')
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
  if not session then
    launch_debug_adapter()
  else
    session:_step('continue')
  end
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
    frameId = (session.current_frame or {}).id;
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


--- Attach to an existing debug-adapter running on host, port
--  and then initialize it with config
--
-- Configuration:         -- Specifies how the debug adapter should conenct/launch the debugee
--    request: string     -- attach or launch
--    ...                 -- debug adapter specific options
--
function M.attach(host, port, config)
  if session then
    session:close()
  end
  if not config.request then
    print('config needs the `request` property which must be one of `attach` or `launch`')
    return
  end
  session = Session:connect(host, port)
  session:initialize(config)
  return session
end


--- Launch a new debug adapter and then initialize it with config
--
-- Adapter:
--    command: string     -- command to invoke
--    args:    string[]   -- arguments for the command
--    options?: {
--      env?: {}          -- Set the environment variables for the command
--      cwd?: string      -- Set the working directory for the command
--    }
--
--
-- Configuration:         -- Specifies how the debug adapter should conenct/launch the debugee
--    request: string     -- attach or launch
--    ...                 -- debug adapter specific options
--
function M.launch(adapter, config)
  if session then
    session:close()
  end
  session = Session:spawn(adapter)
  session:initialize(config)
  return session
end


function M.set_log_level(level)
  log.set_level(level)
end


return M
