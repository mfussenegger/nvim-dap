local dap = require("dap")
local api = vim.api
local helpers = require("spec.helpers")

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



---@param replline string
---@param completion_results dap.CompletionItem[]
local function prepare_session(server, replline, completion_results)
  server.client.initialize = function(self, request)
    self:send_response(request, {
      supportsCompletionsRequest = true,
    })
    self:send_event("initialized", {})
  end
  server.client.completions = function(self, request)
    self:send_response(request, {
      targets = completion_results
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
  api.nvim_buf_set_lines(bufnr, 0, -1, true, {replline})
  api.nvim_win_set_cursor(win, {1, #replline})
end


local function getcompletion_results(server)
  local captured_startcol = nil
  local captured_items = nil

  ---@diagnostic disable-next-line, duplicate-set-field: 211
  function vim.fn.complete(startcol, items)
    captured_startcol = startcol
    captured_items = items
  end

  local repl = require("dap.repl")
  repl.omnifunc(1, "")

  helpers.wait_for_response(server, "completions")
  helpers.wait(function() return captured_startcol ~= nil end)
  return captured_startcol, captured_items
end


describe("dap.repl completion", function()
  local server
  before_each(function()
    server = require("spec.server").spawn()
    dap.adapters.dummy = server.adapter
  end)
  after_each(function()
    server.stop()
    dap.close()
    require('dap.breakpoints').clear()
    helpers.wait(function() return dap.session() == nil end, "session should become nil")
  end)
  it("Uses start position from completion response", function()
    prepare_session(server, "dap> com. ", {
        {
          label = "com.sun.org.apache.xpath",
          number = 0,
          sortText = "999999183",
          start = 0,
          text = "sun.org.apache.xpath",
          type = "module"
        }
    })

    local startcol, items = getcompletion_results(server)
    assert.are.same(#"dap> com." + 1, startcol)
    local expected_items = {
      {
        abbr = "com.sun.org.apache.xpath",
        dup = 0,
        icase = 1,
        word = "sun.org.apache.xpath"
      }
    }
    assert.are.same(expected_items, items)
  end)

  it("Can handle responses without explicit start column and prefix overlap", function()
    prepare_session(server, "dap> info b", {
        {
          label = "info b",
          length = 6,
        },
        {
          label = "info bookmarks",
          length = 14,
        },
        {
          label = "info breakpoints",
          length = 16,
        }
    })

    local startcol, items = getcompletion_results(server)
    assert.are.same(#"dap> " + 1 , startcol)
    local expected_items = {
      {
        abbr = 'info b',
        dup = 0,
        icase = 1,
        word = 'info b',
      },
      {
        abbr = 'info bookmarks',
        dup = 0,
        icase = 1,
        word = 'info bookmarks',
      },
      {
        abbr = 'info breakpoints',
        dup = 0,
        icase = 1,
        word = 'info breakpoints',
      }
    }
    assert.are.same(expected_items, items)
  end)

  it("Can handle responses with explicit start column and prefix overlap", function()
    prepare_session(server, "dap> `info b", {
      {
        label = "`info bookmarks",
        length = 15,
        start = 0,
        type = "text"
      },
      {
        label = "`info breakpoints",
        length = 17,
        start = 0,
        type = "text"
      }
    })

    local startcol, items = getcompletion_results(server)
    assert.are.same(#"dap> " + 1, startcol)
    local expected_items = {
      {
        abbr = '`info bookmarks',
        dup = 0,
        icase = 1,
        word = '`info bookmarks',
      },
      {
        abbr = '`info breakpoints',
        dup = 0,
        icase = 1,
        word = '`info breakpoints',
      }
    }
    assert.are.same(expected_items, items)
  end)
end)
