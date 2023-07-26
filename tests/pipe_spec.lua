local dap = require('dap')

local function wait(predicate, msg)
  vim.wait(1000, predicate)
  local result = predicate()
  assert.are_not.same(false, result, msg and vim.inspect(msg()) or nil)
  assert.are_not.same(nil, result)
end


describe('dap with fake pipe server', function()
  local server
  before_each(function()
    server = require('tests.server').spawn({ new_sock = vim.loop.new_pipe })
    dap.adapters.dummy = server.adapter
  end)
  after_each(function()
    server.stop()
    dap.close()
    require('dap.breakpoints').clear()
    wait(function() return dap.session() == nil end)
  end)
  it("can connect and terminate", function()
    local config = {
      type = 'dummy',
      request = 'launch',
      name = 'Launch file',
    }
    dap.run(config)
    wait(function()
      local session = dap.session()
      return session and session.initialized and #server.spy.requests == 2
    end)
    local session = dap.session()
    assert.is_not_nil(session)
    assert.are.same(1, server.client.num_connected)
    dap.terminate()
    wait(function()
      return (
        dap.session() == nil
        and #server.spy.events == 2
        and server.spy.events[2].event == "terminated"
        and server.client.num_connected == 0
      )
    end, function() return server.spy.events end)
    assert.is_nil(dap.session())
    assert(session)
    assert.is_true(session.closed)
    ---@diagnostic disable-next-line: invisible
    assert.is_true(session.handle:is_closing())
    assert.are.same(0, server.client.num_connected)
  end)
end)
