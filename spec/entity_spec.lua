local dap = require('dap')
local helpers = require("spec.helpers")

local config = {
  type = 'dummy',
  request = 'launch',
  name = 'Launch file',
}


describe("variable entity", function()
  local server
  before_each(function()
    server = require('spec.server').spawn()
    dap.adapters.dummy = server.adapter
  end)
  after_each(function()
    server.stop()
    dap.close()
    helpers.wait(function() return dap.session() == nil end, "session should become nil")
  end)

  it("fetch_children triggers callback on empty variables", function()
    server.client.variables = function(self, request)
      self:send_response(request, {
        variables = {}
      })
    end
    helpers.run_and_wait_until_initialized(config, server)
    local variable = require("dap.entity").variable

    local var = {
      name = "x",
      value = 1,
      variablesReference = 1,
    }
    local variables = nil
    variable.fetch_children(var, function (vars)
      variables = vars
    end)

    helpers.wait(function() return variables ~= nil end, "must call callback with variables")
    assert.are.same({}, variables)
  end)
end)
