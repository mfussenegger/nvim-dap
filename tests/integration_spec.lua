local dap = require('dap')
local api = vim.api

local config = {
  type = 'dummy',
  request = 'launch',
  name = 'Launch file',
}
local function run_and_wait_until_initialized(conf)
  dap.run(conf)
  vim.wait(1000, function()
    local session = dap.session()
    return (session and session.initialized == true)
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
    local session = run_and_wait_until_initialized(config)
    assert.are_not.same(session, nil)
    assert.are.same(true, session.initialized)

    -- initialize and launch requests
    vim.wait(1000, function() return #server.spy.requests == 2 end, 100)
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
    local session = run_and_wait_until_initialized(config)
    session:event_stopped({
      allThreadsStopped = true,
      reason = 'unknown',
    })
  end)

  it('resets session if connection disconnects without terminate event', function()
    local session = run_and_wait_until_initialized(config)
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
  end)

  it('Can call close on session after session has already closed', function()
    local session = run_and_wait_until_initialized(config)
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
    run_and_wait_until_initialized(config)
    vim.wait(1000, function() return #server.spy.requests == 2 end, 100)
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
end)
