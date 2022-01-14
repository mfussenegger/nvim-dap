local dap = require('dap')
local api = vim.api


describe('dap with fake server', function()
  it('clear breakpoints clears all active breakpoints', function()
    local server = require('tests.server').spawn()
    dap.adapters.dummy = server.adapter
    local config = {
      type = 'dummy',
      request = 'launch',
      name = 'Launch file',
    }
    dap.run(config)
    vim.wait(1000, function()
      local session = dap.session()
      return (session and session.initialized == true)
    end, 100)
    local session = dap.session()
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
end)
