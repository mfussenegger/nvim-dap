local dap = require('dap')

describe('server executable', function()
  before_each(function()
    dap.adapters.dummy = {
      type = 'server',
      port = '${port}',
      executable = {
        command = vim.v.progpath,
        args = {
          '-Es',
          '-u', 'NONE',
          '--headless',
          '-c', 'lua DAP_PORT=${port}',
          '-c', 'luafile tests/run_server.lua'
        },
      }
    }
  end)
  after_each(function()
    dap.terminate()
    dap.close()
    vim.wait(100, function()
      return dap.session() == nil
    end)
  end)
  it('Starts adapter executable and connects', function()
    local messages = {}
    require('dap.repl').append = function(line)
      local msg = line:gsub('port=%d+', 'port=12345')
      table.insert(messages, msg)
    end
    dap.run({
      type = 'dummy',
      request = 'launch',
      name = 'Launch',
    })
    vim.wait(2000, function()
      local session = dap.session()
      return (session and session.initialized)
    end)
    local session = dap.session()
    assert.are_not.same(nil, session)
    local expected_msg = "[debug-adapter stderr] Listening on port=12345\n"
    assert.are.same({expected_msg}, messages)
    assert.are.same(true, session.initialized, "initialized must be true")

    dap.terminate()
    vim.wait(100, function()
      return dap.session() == nil
    end)
    assert.are.same(nil, dap.session())
  end)
  it('Clears session after closing', function()
    dap.run({
      type = 'dummy',
      request = 'launch',
      name = 'Launch',
    })
    vim.wait(2000, function()
      local session = dap.session()
      return (session and session.initialized)
    end)
    local session = dap.session()
    assert.are_not.same(nil, session)
    assert.are.same(true, session.initialized, "initialized must be true")
    dap.close()
    vim.wait(100, function()
      return dap.session() == nil
    end)
    assert.are.same(nil, dap.session())
  end)
end)
