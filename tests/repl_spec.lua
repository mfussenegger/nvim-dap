local dap = require("dap")
local api = vim.api
local helpers = require("tests.helpers")

describe('dap.repl', function()
  it("append doesn't add newline with newline = false", function()
    local repl = require('dap.repl')
    local buf = repl.open()
    repl.append('foo', nil, { newline = false })
    repl.append('bar', nil, { newline = false })
    repl.append('\nbaz\n', nil, { newline = false })

    local lines = api.nvim_buf_get_lines(buf, 0, -1, true)
    assert.are.same({'foobar', 'baz', ''}, lines)
  end)
end)


describe("dap.repl completion", function()
  local server
  before_each(function()
    server = require("tests.server").spawn()
    dap.adapters.dummy = server.adapter
  end)
  after_each(function()
    server.stop()
    dap.close()
    require('dap.breakpoints').clear()
    helpers.wait(function() return dap.session() == nil end, "session should become nil")
  end)
  it("Uses start position from completion response", function()
    server.client.initialize = function(self, request)
      self:send_response(request, {
        supportsCompletionsRequest = true,
      })
      self:send_event("initialized", {})
    end
    server.client.completions = function(self, request)
      self:send_response(request, {
        targets = {
          {
            label = "com.sun.org.apache.xpath",
            number = 0,
            sortText = "999999183",
            start = 0,
            text = "sun.org.apache.xpath",
            type = "module"
          }
        }
      })
    end
    local config = {
      type = "dummy",
      request = "launch",
      name = "Launch file",
    }
    helpers.run_and_wait_until_initialized(config, server)

    local repl = require("dap.repl")
    local bufnr, win = repl.open()
    api.nvim_set_current_buf(bufnr)
    api.nvim_set_current_win(win)

    local captured_startcol

    ---@diagnostic disable-next-line, duplicate-set-field: 211
    function vim.fn.complete(startcol, _)
      captured_startcol = startcol
    end

    api.nvim_buf_set_lines(bufnr, 0, -1, true, {"dap> com. "})
    api.nvim_win_set_cursor(win, {1, 9})
    repl.omnifunc(1, "")
    helpers.wait_for_response(server, "completions")
    helpers.wait(function() return captured_startcol ~= nil end)
    assert.are.same(#"dap> com." + 1, captured_startcol)
  end)
end)
