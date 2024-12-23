local helpers = require("spec.helpers")
local wait = helpers.wait
local run_and_wait_until_initialized = helpers.run_and_wait_until_initialized
local uv = vim.uv or vim.loop

local spec_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:match("@?(.*/)"), ":h:p")

local dap = require('dap')
dap.adapters.dummy = {
  type = 'server',
  port = '${port}',
  executable = {
    command = vim.v.progpath,
    args = {
      '-Es',
      '-u', 'NONE',
      '--headless',
      '-c', 'set rtp+=.',
      '-c', 'lua DAP_PORT=${port}',
      '-c', ('luafile %s/run_server.lua'):format(spec_root)
    },
  }
}

describe('server executable', function()
  before_each(function()
  end)
  after_each(function()
    dap.terminate()
    vim.wait(100, function()
      return dap.session() == nil
    end)
    assert.are.same(nil, dap.session())
  end)

  it('Starts adapter executable and connects', function()
    local config = {
      type = 'dummy',
      request = 'launch',
      name = 'Launch',
    }
    local log = require("dap.log").create_logger("dap-dummy-stderr.log")
    local session = run_and_wait_until_initialized(config)
    local adapter = session.adapter --[[@as dap.ServerAdapter]]
    assert.are.same(adapter.port, tonumber(adapter.executable.args[8]:match("(%d+)$")))
    assert.are.same(true, session.initialized, "initialized must be true")

    local expected_msg = "Listening on port=" .. adapter.port .. "\n"
    log._file:flush()
    local f = io.open(log._path, "r")
    assert(f)
    local content = f:read("*a")
    f:close()
    assert.are.same(expected_msg, content)

    dap.terminate()
    wait(function() return dap.session() == nil end, "Must remove session")
    wait(function() return uv.fs_stat(log._path) == nil end)
    assert.is_nil(dap.session())
    assert.is_nil(uv.fs_stat(log._path))
  end)

  it('Clears session after closing', function()
    local config = {
      type = 'dummy',
      request = 'launch',
      name = 'Launch',
    }
    local session = run_and_wait_until_initialized(config)
    assert.are.same(true, session.initialized, "initialized must be true")
    dap.close()
    wait(function() return dap.session() == nil end, "Must remove session")
    assert.are.same(nil, dap.session())
  end)
end)
