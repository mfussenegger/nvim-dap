local helpers = require("spec.helpers")
local wait = helpers.wait
local run_and_wait_until_initialized = helpers.run_and_wait_until_initialized

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
  local messages = {}
  local orig_append
  before_each(function()
    orig_append = require("dap.repl").append

    ---@diagnostic disable-next-line: duplicate-set-field
    require("dap.repl").append = function(line)
      local msg = line:gsub('port=%d+', 'port=12345')
      table.insert(messages, msg)
    end
  end)
  after_each(function()
    dap.terminate()
    vim.wait(100, function()
      return dap.session() == nil
    end)
    assert.are.same(nil, dap.session())
    require("dap.repl").append = orig_append
    messages = {}
  end)

  it('Starts adapter executable and connects', function()
    local config = {
      type = 'dummy',
      request = 'launch',
      name = 'Launch',
    }
    local session = run_and_wait_until_initialized(config)
    local adapter = session.adapter --[[@as dap.ServerAdapter]]
    assert.are.same(adapter.port, tonumber(adapter.executable.args[8]:match("(%d+)$")))
    assert.are.same(true, session.initialized, "initialized must be true")

    local expected_msg = "[debug-adapter stderr] Listening on port=12345\n"
    assert.is_true(vim.tbl_contains(messages, expected_msg))
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
