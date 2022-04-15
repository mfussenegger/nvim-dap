local dap = require('dap')
local api = vim.api

local config = {
  type = 'dummy',
  request = 'launch',
  name = 'Launch file',
}
local function run_and_wait_until_initialized(conf, server)
  dap.run(conf)
  vim.wait(1000, function()
    local session = dap.session()
    -- wait for initialize and launch requests
    return (session and session.initialized and #server.spy.requests == 2)
  end, 100)
  return dap.session()
end

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

  it('resets session if connection disconnects without terminate event', function()
    local session = run_and_wait_until_initialized(config, server)
    assert.are_not.same(nil, dap.session())
    assert.are.same(session, dap.session())
    server.stop()
    vim.wait(1000, function() return dap.session() == nil end, 100)
    assert.are.same(nil, server.client.socket)
    assert.are.same(nil, dap.session())
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
    run_and_wait_until_initialized(config, server)
    assert.are_not.same(nil, dap.session())
    server.stop()
    vim.wait(1000, function() return dap.session() == nil end, 100)
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
    dap.adapters.dummy = server.adapter
  end)
  after_each(function()
    dap.close()
    server.stop()
  end)

  it('clears breakpoints from buffers, adds breakpoint for current line, continues, restores breakpoints', function()

    server.client.setBreakpoints = function(self, request)
      local breakpoints = request.arguments.breakpoints
      self:send_response(request, {
        breakpoints = vim.tbl_map(function() return { verified = true } end, breakpoints)
      })
    end

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
end)
