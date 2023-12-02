local dap = require('dap')
local widgets = require("dap.ui.widgets")
local api = vim.api
local helpers = require("tests.helpers")

local config = {
  type = 'dummy',
  request = 'launch',
  name = 'Launch file',
}


describe("hover widget", function()

  local server
  before_each(function()
    server = require('tests.server').spawn()
    dap.adapters.dummy = server.adapter
  end)
  after_each(function()
    server.stop()
    dap.close()
    require('dap.breakpoints').clear()
    helpers.wait(function() return dap.session() == nil end, "session should become nil")
  end)

  it("evaluates expression with hover context", function()
    server.client.initialize = function(self, request)
      self:send_response(request, {
        supportsEvaluateForHovers = true,
      })
      self:send_event("initialized", {})
    end
    server.client.evaluate = function(self, request)
      self:send_response(request, {
        result = "2",
        variablesReference = 0,
      })
    end
    helpers.run_and_wait_until_initialized(config, server)
    server.spy.clear()
    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(buf, 0, -1, true, {"foo", "bar"})
    api.nvim_set_current_buf(buf)
    api.nvim_win_set_cursor(0, {1, 0})
    widgets.hover("1 + 1")
    local commands = helpers.wait_for_response(server, "evaluate")
    assert.are.same({"evaluate"}, commands)
    assert.are.same("hover", server.spy.requests[1].arguments.context)
    assert.are.same("1 + 1", server.spy.requests[1].arguments.expression)
  end)
end)
