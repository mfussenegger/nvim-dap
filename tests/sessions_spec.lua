local dap = require('dap')


local function wait(predicate, msg)
  vim.wait(1000, predicate)
  local result = predicate()
  assert.are_not.same(false, result, msg and vim.inspect(msg()) or nil)
  assert.are_not.same(nil, result)
end


local function run_and_wait_until_initialized(conf, server)
  dap.run(conf)
  wait(function()
    local session = dap.session()
    -- wait for initialize and launch requests
    return (session and session.initialized and #server.spy.requests == 2)
  end)
  return assert(dap.session(), "Must have session after dap.run")
end


describe('sessions', function()
  local srv1
  local srv2

  before_each(function()
    srv1 = require('tests.server').spawn()
    srv2 = require('tests.server').spawn()
    dap.adapters.dummy1 = srv1.adapter
    dap.adapters.dummy2 = srv2.adapter
  end)
  after_each(function()
    srv1.stop()
    srv2.stop()
    dap.terminate()
    dap.terminate()
  end)
  it('can run multiple sessions', function()
    local conf1 = {
      type = 'dummy1',
      request = 'launch',
      name = 'Launch file 1',
    }
    local conf2 = {
      type = 'dummy2',
      request = 'launch',
      name = 'Launch file 2',
    }
    local s1 = run_and_wait_until_initialized(conf1, srv1)
    local s2 = run_and_wait_until_initialized(conf2, srv2)
    assert.are.same(2, #dap.sessions())
    assert.are.not_same(s1.id, s2.id)

    dap.terminate()
    wait(function() return #dap.sessions() == 1 end, function() return dap.sessions() end)
    assert.are.same(true, s2.closed)
    assert.are.same(false, s1.closed)
    assert.are.same(s1, dap.session())

    dap.terminate()
    wait(function() return #dap.sessions() == 0 end, function() return dap.sessions() end)
    assert.are.same(nil, dap.session())
  end)

  it("startDebugging starts a child session", function()
    local conf1 = {
      type = 'dummy1',
      request = 'launch',
      name = 'Launch file 1',
    }
    run_and_wait_until_initialized(conf1, srv1)
    srv1.client:send_request("startDebugging", {
      request = "launch",
      configuration = {
        type = "dummy2",
        name = "Subprocess"
      }
    })
    wait(
      function() return vim.tbl_count(dap.session().children) == 1 end,
      function() return dap.session() end
    )
    local _, child = next(dap.session().children)
    assert.are.same("Subprocess", child.config.name)

    srv2.stop()
    wait(function() return vim.tbl_count(dap.session().children) == 0 end)
    assert.are.same({}, dap.session().children)
  end)

  it("startDebugging connects to root adapter if type server with executable", function()
    local conf1 = {
      type = 'dummy1',
      request = 'launch',
      name = 'Launch file 1',
    }
    local session = run_and_wait_until_initialized(conf1, srv1)
    assert.are.same(1, srv1.client.num_connected)
    dap.adapters.dummy2 = {
      type = "server",
      executable = {
        command = "echo",
        args = {"not", "used"},
      }
    }
    srv1.client:send_request("startDebugging", {
      request = "launch",
      configuration = {
        type = "dummy2",
        name = "Subprocess"
      }
    })
    wait(
      function() return vim.tbl_count(session.children) == 1 end,
      function() return dap.session() end
    )
    assert.are.same(2, srv1.client.num_connected)
    dap.terminate()
  end)
end)
