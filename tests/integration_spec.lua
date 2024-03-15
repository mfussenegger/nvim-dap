local api = vim.api
local dap = require('dap')
local helpers = require("tests.helpers")
local wait = helpers.wait
local wait_for_response= helpers.wait_for_response
local run_and_wait_until_initialized = helpers.run_and_wait_until_initialized

local config = {
  type = 'dummy',
  request = 'launch',
  name = 'Launch file',
}


describe('dap with fake server', function()
  local server
  before_each(function()
    server = require('tests.server').spawn()
    dap.adapters.dummy = server.adapter
  end)
  after_each(function()
    server.stop()
    dap.close()
    require('dap.breakpoints').clear()
    wait(function() return dap.session() == nil end)
  end)
  it('clear breakpoints clears all active breakpoints', function()
    local session = run_and_wait_until_initialized(config, server)
    assert.are_not.same(session, nil)
    assert.are.same(true, session.initialized)

    server.spy.clear()

    local buf1 = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(buf1, 0, -1, false, {'line 1'})
    api.nvim_win_set_buf(0, buf1)
    api.nvim_win_set_cursor(0, { 1, 1 })
    dap.toggle_breakpoint()
    vim.wait(1000, function() return #server.spy.requests == 1 end, 100)
    assert.are.same(1, vim.tbl_count(require('dap.breakpoints').get()))
    assert.are.same('setBreakpoints', server.spy.requests[1].command)

    local buf2 = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(buf2, 0, -1, false, {'line 1', 'line 2'})
    api.nvim_win_set_buf(0, buf2)
    api.nvim_win_set_cursor(0, { 1, 1 })
    dap.toggle_breakpoint()
    vim.wait(1000, function() return #server.spy.requests == 2 end, 100)

    assert.are.same(2, vim.tbl_count(require('dap.breakpoints').get()))

    server.spy.clear()
    dap.clear_breakpoints()
    vim.wait(1000, function() return #server.spy.requests == 2 end, 100)

    assert.are.same(0, vim.tbl_count(require('dap.breakpoints').get()))
    assert.are.same(2, vim.tbl_count(server.spy.requests))
    local setBreakpoints = server.spy.requests[1]
    assert.are.same({}, setBreakpoints.arguments.breakpoints)
  end)

  it('can handle stopped event for all threads', function()
    local session = run_and_wait_until_initialized(config, server)
    session:event_stopped({
      allThreadsStopped = true,
      reason = 'unknown',
    })
  end)

  it('Adds error diagnostic on stopped event due to exception', function()
    local buf = api.nvim_create_buf(true, false)
    local win = api.nvim_get_current_win()
    local tmpname = os.tmpname()
    os.remove(tmpname)
    api.nvim_buf_set_name(buf, tmpname)
    api.nvim_buf_set_lines(buf, 0, -1, false, {'line 1', 'line 2'})
    api.nvim_win_set_buf(win, buf)
    api.nvim_win_set_cursor(win, { 1, 0})

    local session = run_and_wait_until_initialized(config, server)
    server.spy.clear()
    server.client.threads = function(self, request)
      self:send_response(request, {
        threads = { { id = 1, name = 'thread1' }, }
      })
    end
    local path = vim.uri_from_bufnr(buf)
    server.client.stackTrace = function(self, request)
      self:send_response(request, {
        stackFrames = {
          {
            id = 1,
            name = 'stackFrame1',
            line = 1,
            column = 1,
            source = {
              path = path
            }
          },
        },
      })
    end
    session.capabilities.supportsExceptionInfoRequest = true
    server.client.exceptionInfo = function(self, request)
      self:send_response(request, {
        exceptionId = "XXX",
        breakMode = "unhandled"
      })
    end
    session:event_stopped({
      threadId = 1,
      reason = 'exception',
    })
    wait(function() return #server.spy.requests == 4 end, function()
      return {
        requests = server.spy.requests,
        responses = server.spy.responses
      }
    end)
    local diagnostics = vim.diagnostic.get(buf)
    local expected = {
      {
        bufnr = buf,
        col = 0,
        end_col = 0,
        end_lnum = 0,
        lnum = 0,
        message = 'Thread stopped due to exception (unhandled)',
        namespace = 1,
        severity = 1,
        source = 'nvim-dap',
      }
    }
    assert.are.same(expected, diagnostics)
  end)

  it('jumps to location if thread with same id is already stopped', function()
    local session = run_and_wait_until_initialized(config, server)

    -- Pretend to be stopped
    session.stopped_thread_id = 1

    server.spy.clear()
    server.client.threads = function(self, request)
      self:send_response(request, {
        threads = { { id = 1, name = 'thread1' }, }
      })
    end
    server.client.stackTrace = function(self, request)
      self:send_response(request, {
        stackFrames = {
          {
            id = 1,
            name = 'stackFrame1',
            line = 1,
          },
        },
      })
    end
    session:event_stopped({
      allThreadsStopped = false,
      threadId = 1,
      reason = 'breakpoint',
    })
    vim.wait(1000, function() return #server.spy.requests == 3 end)
    local expected_commands = {"threads", "stackTrace", "scopes"}
    assert.are.same(
      expected_commands,
      vim.tbl_map(function(x) return x.command end, server.spy.requests)
    )
  end)

  it('jumps to location on stopped with reason=pause and allThreadsStopped', function()
    local session = run_and_wait_until_initialized(config, server)
    server.spy.clear()
    server.client.threads = function(self, request)
      self:send_response(request, {
        threads = { { id = 1, name = 'thread1' }, }
      })
    end
    server.client.stackTrace = function(self, request)
      self:send_response(request, {
        stackFrames = {
          {
            id = 1,
            name = 'stackFrame1',
            line = 1,
          },
        },
      })
    end
    session:event_stopped({
      allThreadsStopped = true,
      threadId = 1,
      reason = 'pause',
    })
    -- should request threads, stackTrace and scopes on stopped event
    vim.wait(1000, function() return #server.spy.requests == 3 end)
    assert.are.same('threads', server.spy.requests[1].command)
    assert.are.same('stackTrace', server.spy.requests[2].command)
    assert.are_not.same(nil, session.current_frame)
    assert.are.same('stackFrame1', session.current_frame.name)
  end)

  it('jump to location results in nice error if location outside buffer contents', function()
    local buf = api.nvim_create_buf(true, false)
    local win = api.nvim_get_current_win()
    api.nvim_buf_set_lines(buf, 0, -1, false, {'line 1', 'line 2'})
    api.nvim_win_set_buf(win, buf)
    api.nvim_win_set_cursor(win, { 1, 0})

    local session = run_and_wait_until_initialized(config, server)
    server.spy.clear()
    server.client.threads = function(self, request)
      self:send_response(request, {
        threads = { { id = 1, name = 'thread1' }, }
      })
    end
    server.client.stackTrace = vim.schedule_wrap(function(self, request)
      self:send_response(request, {
        stackFrames = {
          {
            id = 1,
            name = 'stackFrame1',
            line = 40,
            column = 3,
            source = {
              sourceReference = 0,
              path = vim.uri_from_bufnr(buf),
            },
          },
        },
      })
    end)
    local captured_msg
    vim.notify = function(...)
      local msg = select(1, ...)
      captured_msg = msg
    end
    session:event_stopped({
      threadId = 1,
      reason = 'breakpoint',
    })
    vim.wait(1000, function() return captured_msg ~= nil end)
    assert.are.same('Debug adapter reported a frame at line 40 column 3, but: Cursor position outside buffer. Ensure executable is up2date and if using a source mapping ensure it is correct', captured_msg)
  end)

  it('Can handle frames without source/path on stopped event', function()
    run_and_wait_until_initialized(config, server)
    server.spy.clear()
    server.client.threads = function(self, request)
      self:send_response(request, {
        threads = { { id = 1, name = 'thread1' }, }
      })
    end
    server.client.stackTrace = function(self, request)
      self:send_response(request, {
        stackFrames = {
          {
            id = 1,
            name = 'stackFrame1',
            line = 1,
          },
        },
      })
    end
    server.client:send_event('stopped', {
      threadId = 1,
      reason = 'unknown',
    })
    vim.wait(1000, function() return #server.spy.requests == 3 end, 100)
  end)

  it('Deleting a buffer clears breakpoints for that buffer', function()
    local win = api.nvim_get_current_win()
    local buf1 = api.nvim_create_buf(false, true)
    api.nvim_buf_set_name(buf1, 'dummy_buf1')
    api.nvim_buf_set_lines(buf1, 0, -1, false, {'buf1: line1'})
    api.nvim_win_set_buf(win, buf1)
    api.nvim_win_set_cursor(win, { 1, 0 })
    dap.toggle_breakpoint()

    run_and_wait_until_initialized(config, server)
    -- wait for initialize, launch and one setBreakpoints request
    vim.wait(1000, function() return #server.spy.requests == 3 end, 100)
    assert.are.same(3, #server.spy.requests)
    server.spy.clear()
    api.nvim_buf_delete(buf1, { force = true })

    vim.wait(1000, function() return #server.spy.requests == 1 end, 100)
    local setBreakpoints = server.spy.requests[1]
    assert.are.same('setBreakpoints', setBreakpoints.command)
    assert.are.same('dummy_buf1', setBreakpoints.arguments.source.name)
    assert.are.same({}, setBreakpoints.arguments.breakpoints)

    assert.are.same({}, require('dap.breakpoints').get())
  end)

  it('prints formatted error on launch error', function()
    local captured_msg
    vim.notify = function(...)
      local msg = select(1, ...)
      captured_msg = msg
    end
    server.client.launch = function(self, request)
      self:send_err_response(request, 'Failure', {
        id = 1,
        format = 'Failed: {e}',
        showUser = true,
        variables = {
          e = 'Dummy'
        },
      })
    end
    run_and_wait_until_initialized(config, server)
    wait(function() return captured_msg ~= nil end)
    assert.are.same('Error on launch: Failed: Dummy', captured_msg)
  end)

  it('evaluates callable config', function()
    local callable_config = setmetatable(config, {
      __call = function(conf)
        local result = {}
        for k, v in pairs(conf) do
          result[k] = v
        end
        result.x = 1
        return result
      end,
    })
    local session = run_and_wait_until_initialized(callable_config, server)
    assert.are.same(session.config.x, 1)
  end)

  it("step does nothing if session is not stopped", function()
    local session = run_and_wait_until_initialized(config, server)
    dap.step_over()
    assert.are.same(session, dap.session())
  end)

  it("Run aborts if config value is dap.ABORT", function()
    local msg = nil
    require('dap.utils').notify = function(m)
      msg = m
    end
    dap.run({
      name = "dummy",
      type = "dummy",
      request = "launch",
      foo = function()
        return dap.ABORT
      end,
    })
    wait(function() return msg ~= nil end)
    assert.is_nil(dap.session())
    assert.are.same("Run aborted", msg)
  end)
end)

describe('session disconnect', function()
  local server
  before_each(function()
    server = require('tests.server').spawn()
    dap.adapters.dummy = server.adapter
  end)
  after_each(function()
    dap.close()
    require('dap.breakpoints').clear()
    server.stop()
    wait(function() return dap.session() == nil end)
  end)

  it('Can call close on session after session has already closed', function()
    local session = run_and_wait_until_initialized(config, server)
    assert.are.not_same(nil, session)
    local cb_called = false
    dap.disconnect(nil, function()
      cb_called = true
    end)
    vim.wait(1000, function() return cb_called end, 100)
    assert.are.same(true, cb_called)
    assert.are.same(nil, dap.session())
    session:close()
  end)

  it('Closes session on disconnect response', function()
    run_and_wait_until_initialized(config, server)
    server.spy.clear()

    local client = server.client
    -- override to not send terminate event as well
    client.disconnect = function(self, request)
      self:send_response(request, {})
    end

    local cb_called = false
    dap.disconnect(nil, function()
      cb_called = true
    end)
    vim.wait(1000, function() return cb_called end, 100)
    assert.are.same({}, server.spy.events)
    assert.are.same(1, #server.spy.responses)
    assert.are.same('disconnect', server.spy.responses[1].command)
    assert.are.same(nil, dap.session())
  end)

  it('Closes session if server closes connection', function()
    local session = run_and_wait_until_initialized(config, server)
    assert.are_not.same(nil, dap.session())
    assert.are.same(session, dap.session())
    server.stop()
    vim.wait(1000, function() return dap.session() == nil end, 100)
    assert.are.same(nil, server.client.socket)
    assert.are.same(nil, dap.session())
  end)

  it('Closes session if initialization fails', function()
    local launch_called = false
    server.client.launch = function(self, request)
      launch_called = true
      self:send_err_response(request, 'Dummy error')
    end
    local msg = nil
    require('dap.utils').notify = function(m)
      msg = m
    end
    dap.run(config)
    vim.wait(1000, function() return launch_called end, 100)
    vim.wait(1000, function() return dap.session() == nil end, 100)
    assert.are.same(nil, dap.session())
    assert.are.same('Error on launch: Dummy error', msg)
  end)

  it('Repeated disconnect after stopped server is safe and resets session', function()
    run_and_wait_until_initialized(config, server)
    server.stop()
    local cb_called = false
    for _ = 1, 10 do
      dap.disconnect()
    end
    dap.disconnect(nil, function()
      cb_called = true
    end)
    vim.wait(1000, function() return cb_called end, 100)
    assert.are.same(nil, dap.session())
  end)
end)

describe('request source', function()
  local server
  before_each(function()
    server = require('tests.server').spawn()
    dap.adapters.dummy = server.adapter
  end)
  after_each(function()
    dap.close()
    server.stop()
    wait(function() return dap.session() == nil end)
  end)

  it('can jump to frame if source needs to be fetched', function()
    server.client.source = function(self, request)
      self:send_response(request, {
        content = 'foobar',
        mimeType = 'text/x-lldb.disassembly',
      })
    end
    server.client.threads = function(self, request)
      self:send_response(request, {
        threads = { { id = 1, name = 'thread1' }, }
      })
    end
    server.client.stackTrace = function(self, request)
      self:send_response(request, {
        stackFrames = {
          {
            id = 1,
            name = 'stackFrame1',
            line = 1,
            source = {
              sourceReference = 1
            }
          },
        },
      })
    end
    run_and_wait_until_initialized(config, server)
    server.spy.clear()
    server.client:send_event('stopped', {
      threadId = 1,
      reason = 'breakpoint',
    })
    wait_for_response(server, 'source')
    assert.are.same('source', server.spy.responses[3].command)
    assert.are.same('foobar', server.spy.responses[3].body.content)
    wait(function()
      return 'foobar' == api.nvim_buf_get_lines(0, 0, -1, false)[1]
    end)
    local lines = api.nvim_buf_get_lines(0, 0, -1, false)
    assert.are.same({'foobar'}, lines)
  end)

  it('sets filetype based on mimetype if available', function()
    server.client.source = function(self, request)
      self:send_response(request, {
        content = '',
        mimeType = 'text/javascript',
      })
    end

    local session = run_and_wait_until_initialized(config, server)
    local source = {
      sourceReference = 1
    }
    local bufnr = nil
    session:source(source, function(_, buf)
      bufnr = buf
    end)
    vim.wait(1000, function() return bufnr ~= nil end, 100)
    assert.are.same('javascript', vim.bo[bufnr].filetype)
  end)

  it('sets filetype based on adapter option if available', function()
    server.client.source = function(self, request)
      self:send_response(request, {
        content = '',
      })
    end
    dap.adapters.dummy.options = {
      source_filetype = 'lua'
    }
    local session = run_and_wait_until_initialized(config, server)
    local source = {
      sourceReference = 1
    }
    local bufnr = nil
    session:source(source, function(_, buf)
      bufnr = buf
    end)
    vim.wait(1000, function() return bufnr ~= nil end, 100)
    assert.are.same('lua', vim.bo[bufnr].filetype)
  end)

  if vim.filetype then
    it('derives filetype from source.path if available', function()
      server.client.source = function(self, request)
        self:send_response(request, {
          content = '',
        })
      end
      local session = run_and_wait_until_initialized(config, server)
      local source = {
        sourceReference = 1,
        path = 'foo/bar/baz.lua',
      }
      local bufnr = nil
      session:source(source, function(_, buf)
        bufnr = buf
      end)
      vim.wait(1000, function() return bufnr ~= nil end, 100)
      assert.are.same('lua', vim.bo[bufnr].filetype)
    end)
  end
end)

describe('run_to_cursor', function()
  local server
  before_each(function()
    server = require('tests.server').spawn()
    server.client.setBreakpoints = function(self, request)
      local breakpoints = request.arguments.breakpoints
      self:send_response(request, {
        breakpoints = vim.tbl_map(function() return { verified = true } end, breakpoints)
      })
    end
    dap.adapters.dummy = server.adapter
  end)
  after_each(function()
    dap.close()
    server.stop()
    for _, buf in pairs(api.nvim_list_bufs()) do
      api.nvim_buf_delete(buf, { force = true })
    end
    wait(function() return dap.session() == nil end)
  end)

  it('clears breakpoints from buffers, adds breakpoint for current line, continues, restores breakpoints', function()
    local win = api.nvim_get_current_win()
    local buf1 = api.nvim_create_buf(false, true)
    local buf2 = api.nvim_create_buf(false, true)
    api.nvim_buf_set_name(buf1, 'dummy_buf1')
    api.nvim_buf_set_name(buf2, 'dummy_buf2')
    api.nvim_buf_set_lines(buf1, 0, -1, false, {'buf1: line1'})
    api.nvim_buf_set_lines(buf2, 0, -1, false, {'buf2: line 1', 'buf2: line2'})

    api.nvim_win_set_buf(win, buf1)
    api.nvim_win_set_cursor(win, { 1, 0 })
    dap.toggle_breakpoint()

    api.nvim_win_set_buf(win, buf2)
    api.nvim_win_set_cursor(win, { 1, 0 })
    dap.toggle_breakpoint()

    local session = run_and_wait_until_initialized(config, server)
    -- wait for initialize, launch, and setBreakpoints (two buffers, two setBreakpoints)
    vim.wait(1000, function() return #server.spy.requests == 4 end, 100)
    server.spy.clear()
    assert.are.same(2, vim.tbl_count(require('dap.breakpoints').get()))

    api.nvim_win_set_buf(win, buf2)
    api.nvim_win_set_cursor(win, { 2, 0 })

    -- Pretend to be stopped
    session.stopped_thread_id = 1

    dap.run_to_cursor()
    vim.wait(1000, function() return #server.spy.requests == 3 end, 100)

    -- sets breakpoint for current buffer to current line to run to the cursor
    local set_bps_requests = { server.spy.requests[1], server.spy.requests[2] }
    table.sort(set_bps_requests, function(a, b)
      return a.arguments.source.name > b.arguments.source.name
    end)
    local set_bps1 = set_bps_requests[1]
    assert.are.same('setBreakpoints', set_bps1.command)
    assert.are.same('dummy_buf2', set_bps1.arguments.source.name)
    assert.are.same({ { line = 2 }, }, set_bps1.arguments.breakpoints)

    -- resets breakpoints everywhere else
    local set_bps2 = set_bps_requests[2]
    assert.are.same('setBreakpoints', set_bps2.command)
    assert.are.same('dummy_buf1', set_bps2.arguments.source.name)
    assert.are.same({}, set_bps2.arguments.breakpoints)

    -- continues to run to the cursor
    local continue_req = server.spy.requests[3]
    assert.are.same('continue', continue_req.command)

    server.spy.clear()

    -- restores original breakpoints once stopped
    server.client:send_event('stopped', {
      reason = 'stopped',
      allThreadsStopped = true,
    })
    vim.wait(1000, function() return #server.spy.requests == 3 end, 100)

    set_bps_requests = { server.spy.requests[1], server.spy.requests[2] }
    table.sort(set_bps_requests, function(a, b)
      return a.arguments.source.name > b.arguments.source.name
    end)
    set_bps1 = set_bps_requests[1]
    assert.are.same('setBreakpoints', set_bps1.command)
    assert.are.same('dummy_buf2', set_bps1.arguments.source.name)
    assert.are.same({ { line = 1 }, }, set_bps1.arguments.breakpoints)

    set_bps2 = set_bps_requests[2]
    assert.are.same('setBreakpoints', set_bps2.command)
    assert.are.same('dummy_buf1', set_bps2.arguments.source.name)
    assert.are.same({ { line = 1 }, }, set_bps2.arguments.breakpoints)
  end)
  it('clears temporary run_to_cursor breakpoint if buffer contained no breakpoints before', function()
    local win = api.nvim_get_current_win()
    local buf1 = api.nvim_create_buf(false, true)
    local buf2 = api.nvim_create_buf(false, true)
    api.nvim_buf_set_name(buf1, 'dummy_buf1')
    api.nvim_buf_set_name(buf2, 'dummy_buf2')
    api.nvim_buf_set_lines(buf1, 0, -1, false, {'buf1: line1'})
    api.nvim_buf_set_lines(buf2, 0, -1, false, {'buf2: line 1', 'buf2: line2'})

    api.nvim_win_set_buf(win, buf1)
    api.nvim_win_set_cursor(win, { 1, 0 })
    dap.toggle_breakpoint()
    local session = run_and_wait_until_initialized(config, server)
    -- wait for initialize, launch, and setBreakpoints
    vim.wait(1000, function() return #server.spy.requests == 3 end, 100)
    server.spy.clear()
    assert.are.same(1, vim.tbl_count(require('dap.breakpoints').get()))

    api.nvim_win_set_buf(win, buf2)
    api.nvim_win_set_cursor(win, { 2, 0 })

    -- Pretend to be stopped
    session.stopped_thread_id = 1
    dap.run_to_cursor()
    -- sets breakpoints in two buffers
    vim.wait(1000, function() return #server.spy.requests == 2 end, 100)
    server.spy.clear()
    server.client:send_event('stopped', {
      reason = 'stopped',
      allThreadsStopped = true,
    })
    -- continues, resets breakpoints in both buffers
    vim.wait(1000, function() return #server.spy.requests == 3 end, 100)
    local set_bps_requests = { server.spy.requests[2], server.spy.requests[3] }
    table.sort(set_bps_requests, function(a, b)
      return a.arguments.source.name < b.arguments.source.name
    end)
    local set_bps1 = set_bps_requests[1]
    assert.are.same('setBreakpoints', set_bps1.command)
    assert.are.same('dummy_buf1', set_bps1.arguments.source.name)
    assert.are.same({ { line = 1 }, }, set_bps1.arguments.breakpoints)

    local set_bps2 = set_bps_requests[2]
    assert.are.same('setBreakpoints', set_bps2.command)
    assert.are.same('dummy_buf2', set_bps2.arguments.source.name)
    assert.are.same({}, set_bps2.arguments.breakpoints)
    local expected_bps = {
      [buf1] = {
        {
          line = 1,
        },
      }
    }
    assert.are.same(expected_bps, require('dap.breakpoints').get())
  end)
end)

describe('breakpoint events', function()
  local server
  before_each(function()
    server = require('tests.server').spawn()
    dap.adapters.dummy = server.adapter
  end)
  after_each(function()
    server.stop()
    dap.close()
    require('dap.breakpoints').clear()
    wait(function() return dap.session() == nil end)
  end)
  it('can change state from rejected to verified', function()
    server.client.setBreakpoints = function(self, request)
      self:send_response(request, {
        breakpoints = {
          {
            id = 1,
            verified = false,
            message = "I don't like this breakpoint",
          }
        }
      })
    end

    run_and_wait_until_initialized(config, server)
    local win = api.nvim_get_current_win()
    local buf1 = api.nvim_create_buf(false, true)
    api.nvim_buf_set_name(buf1, 'dummy_buf1')
    api.nvim_buf_set_lines(buf1, 0, -1, false, {'buf1: line1'})
    api.nvim_win_set_buf(win, buf1)
    api.nvim_win_set_cursor(win, { 1, 0 })
    dap.toggle_breakpoint()

    local breakpoints = require('dap.breakpoints')

    -- initialize, launch, setBreakpoints == 3 requests
    wait(function() return #server.spy.requests == 3 end)
    wait(function() return #server.spy.responses == 3 end)
    wait(function() return breakpoints.get()[buf1][1].state end)

    local bps = breakpoints.get()
    assert.are.same(1, vim.tbl_count(bps))
    local expected_breakpoint = {
      line = 1,
      state = {
        id = 1,
        message = "I don't like this breakpoint",
        verified = false,
      }
    }
    assert.are.same(expected_breakpoint, bps[buf1][1])
    local signs = vim.fn.sign_getplaced(buf1, { group = 'dap_breakpoints' })
    assert.are.same('DapBreakpointRejected', signs[1].signs[1].name)

    local num_events = #server.spy.events
    server.client:send_event('breakpoint', {
      reason = 'changed',
      breakpoint = {
        id = 1,
        verified = true,
        message = "I don't like this breakpoint",
      }
    })
    wait(function() return #server.spy.events == num_events + 1 end)
    wait(function() return breakpoints.get()[buf1][1].state.verified end)
    assert.are.same(num_events + 1, #server.spy.events)
    expected_breakpoint.state.verified = true
    assert.are.same(expected_breakpoint, breakpoints.get()[buf1][1])

    signs = vim.fn.sign_getplaced(buf1, { group = 'dap_breakpoints' })
    assert.are.same('DapBreakpoint', signs[1].signs[1].name)
  end)
end)

describe('restart_frame', function()
  local server
  before_each(function()
    server = require('tests.server').spawn()
    dap.adapters.dummy = server.adapter
  end)
  after_each(function()
    server.stop()
    dap.close()
    wait(function() return dap.session() == nil end)
  end)
  it('Requires restart capability', function()
    run_and_wait_until_initialized(config, server)
    local msg
    require('dap.utils').notify = function(m, _)
      msg = m
    end
    dap.restart_frame()
    assert.are.same('Debug Adapter does not support restart frame', msg)
  end)

  it('Requires to be stopped', function()
    local session = run_and_wait_until_initialized(config, server)
    assert(session)
    session.capabilities.supportsRestartFrame = true
    local msg
    require('dap.utils').notify = function(m, _)
      msg = m
    end
    dap.restart_frame()
    assert.are.same('Current frame not set. Debug adapter needs to be stopped at breakpoint to use restart frame', msg)
  end)

  it('Restarts frame if stopped at breakpoint', function()
    local session = run_and_wait_until_initialized(config, server)
    server.spy.clear()
    server.client.threads = function(self, request)
      self:send_response(request, {
        threads = { { id = 1, name = 'thread1' }, }
      })
    end
    server.client.stackTrace = function(self, request)
      self:send_response(request, {
        stackFrames = {
          {
            id = 1,
            name = 'stackFrame1',
            line = 1,
          },
        },
      })
    end
    assert(session)
    session.capabilities.supportsRestartFrame = true
    session:event_stopped({
      allThreadsStopped = false,
      threadId = 1,
      reason = 'breakpoint',
    })

    wait(function() return #server.spy.requests == 3 end)
    dap.restart_frame()
    wait(function() return #server.spy.requests == 4 end)
    assert.are.same('restartFrame', server.spy.requests[4].command)
  end)

  it('Asks for frame to restart, if current frame cannot', function()
    local session = run_and_wait_until_initialized(config, server)
    server.spy.clear()
    server.client.threads = function(self, request)
      self:send_response(request, {
        threads = { { id = 1, name = 'thread1' }, }
      })
    end
    server.client.stackTrace = function(self, request)
      self:send_response(request, {
        stackFrames = {
          {
            id = 1,
            name = 'stackFrame1',
            canRestart = false,
            line = 2,
          },
          {
            id = 2,
            name = 'stackFrame2',
            canRestart = true,
            line = 1,
          },
        },
      })
    end
    assert(session)
    session.capabilities.supportsRestartFrame = true
    session:event_stopped({
      allThreadsStopped = false,
      threadId = 1,
      reason = 'breakpoint',
    })
    local asked = false
    vim.ui.select = function(items, _, cb)
      asked = true
      cb(items[1])
    end

    wait(function() return #server.spy.requests == 3 end)
    dap.restart_frame()
    wait(function() return asked end)
    assert.are.same(true, asked)
    wait(function() return #server.spy.requests == 4 end)
    assert.are.same('restartFrame', server.spy.requests[4].command)
  end)
end)


describe('event_terminated', function()
  local server
  before_each(function()
    server = require('tests.server').spawn()
    dap.adapters.dummy = server.adapter
  end)
  after_each(function()
    server.stop()
    dap.terminate()
    wait(function() return dap.session() == nil end)
  end)
  it('can restart session', function()
    local session = run_and_wait_until_initialized(config, server)

    server.spy.clear()
    server.client:send_event('terminated', {
      restart = 'dummy_value'
    })

    -- should start new session
    -- wait for initialize and launch
    wait(function() return #server.spy.requests == 2 end)
    local request = server.spy.requests[2]
    assert.are.same('launch', request.command, 'launch')
    local expected_args = vim.deepcopy(session.config)
    expected_args.__restart = 'dummy_value'
    assert.are.same(expected_args, request.arguments)
    local new_session = dap.session()
    assert.are.not_same(nil, new_session)
    assert.are.not_same(session.id, new_session.id)

    server.client:send_event('terminated')
    dap.terminate()
    wait(function() return dap.session() == nil end)
  end)
end)


describe('progress support', function()
  local server
  before_each(function()
    server = require('tests.server').spawn()
    dap.adapters.dummy = server.adapter
  end)
  after_each(function()
    server.stop()
    dap.terminate()
    wait(function() return dap.session() == nil end)
  end)

  it('shows progress in status', function()
    run_and_wait_until_initialized(config, server)
    local progress = require('dap.progress')
    wait(function() return #server.spy.events == 1 end)

    progress.reset()
    server.spy.clear()
    server.client:send_event('progressStart', {
      progressId = '1',
      title = 'progress title',
    })
    wait(function() return #server.spy.events == 1 end)
    assert.are.same('progressStart', server.spy.events[1].event)
    wait(function() return progress.status() ~= '' end)
    assert.are.same('progress title', progress.status())

    server.client:send_event('progressEnd', {
      progressId = '1',
    })
    wait(function() return progress.status() ~= 'progress title' end)
    assert.are.same('Running: Launch file', progress.status())
  end)
end)


describe("run_last", function()
  local server
  before_each(function()
    server = require('tests.server').spawn()
    dap.adapters.dummy = server.adapter
  end)
  after_each(function()
    server.stop()
    dap.terminate()
    wait(function() return dap.session() == nil end, "Session should become nil after terminate")
    assert.are.same(0, vim.tbl_count(dap.sessions()), "Sessions should go down to 0 after terminate/stop")
  end)

  it('can repeat run_last and it always clears session', function()
    server.client.initialize = function(self, request)
      self:send_response(request, {
        supportsTerminateRequest = true,
      })
      self:send_event("initialized", {})
    end

    run_and_wait_until_initialized(config, server)
    server.spy.clear()
    dap.run_last()
    wait(function() return #server.spy.requests == 3 end)
    local commands = vim.tbl_map(function(x) return x.command end, server.spy.requests)
    assert.are.same({"terminate", "initialize", "launch"}, commands)
    assert.are.same(1, vim.tbl_count(dap.sessions()))

    dap.run_last()
    wait(function() return #server.spy.requests == 3 end)
    commands = vim.tbl_map(function(x) return x.command end, server.spy.requests)
    assert.are.same({"terminate", "initialize", "launch"}, commands)
    assert.are.same(1, vim.tbl_count(dap.sessions()))
  end)

  it("re-evaluates functions if adapter supports restart", function()
    server.client.initialize = function(self, request)
      self:send_response(request, {
        supportsRestartRequest = true,
      })
      self:send_event("initialized", {})
    end
    server.client.restart = function(self, request)
      self:send_response(request, {})
    end
    local num_called = 0
    local dummy_config = {
      type = 'dummy',
      request = 'launch',
      name = 'Launch file',
      called = function()
        num_called = num_called + 1
        return num_called
      end
    }
    run_and_wait_until_initialized(dummy_config, server)
    assert.are.same(1, num_called)
    server.spy.clear()
    dap.run_last()
    wait_for_response(server, "restart")
    local commands = vim.tbl_map(function(x) return x.command end, server.spy.requests)
    assert.are.same({"restart"}, commands)
    assert.are.same(2, num_called)
  end)
end)


describe("bad debug adapter", function()
  it("calls notify with warning", function()
    dap.adapters.bad = {
      type = "executable",
      command = "python",
      args = { vim.fn.expand("%:p:h") .. "/tests/bad_adapter.py" }
    }
    local captured_msg
    local captured_log_level
    ---@diagnostic disable-next-line: duplicate-set-field
    require("dap.utils").notify = function(msg, log_level)
      captured_msg = msg
      captured_log_level = log_level
    end
    local bad_config = {
      type = 'bad',
      request = 'launch',
      name = 'Launch file',
    }
    dap.run(bad_config)
    wait(function() return captured_msg ~= nil end)
    assert.are.same("python exited with code: 10", captured_msg)
    assert.are.same(vim.log.levels.WARN, captured_log_level)
  end)
end)


describe("on_output", function()
  local server
  before_each(function()
    server = require('tests.server').spawn()
    dap.adapters.dummy = server.adapter
  end)
  after_each(function()
    server.stop()
    dap.terminate()
    wait(function() return dap.session() == nil end, "Session should become nil after terminate")
    assert.are.same(0, vim.tbl_count(dap.sessions()), "Sessions should go down to 0 after terminate/stop")
  end)

  it("can override output handling", function()
    local captured_output = nil

    function dap.defaults.fallback.on_output(_, output)
      captured_output = output
    end

    server.client.initialize = function(self, request)
      self:send_response(request, {})
      self:send_event("initialized", {})
      self:send_event("output", {
        category = "stdout",
        output = "dummy output"
      })
    end

    run_and_wait_until_initialized(config, server)
    assert.are.same(captured_output, {
      category = "stdout",
      output = "dummy output"
    })
  end)
end)
