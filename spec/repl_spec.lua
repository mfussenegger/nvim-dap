local dap = require("dap")
local api = vim.api
local helpers = require("spec.helpers")
local repl = require('dap.repl')
local config = {
  type = "dummy",
  request = "launch",
  name = "Launch file",
}


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
  helpers.run_and_wait_until_initialized(config, server)
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

  repl.omnifunc(1, "")

  helpers.wait_for_response(server, "completions")
  helpers.wait(function() return captured_startcol ~= nil end)
  return captured_startcol, captured_items
end


---@param buf integer
---@param lnum integer
local function assert_prompt_mark(buf, lnum)
  if vim.fn.has("nvim-0.12") == 1 then
    local prompt_mark = api.nvim_buf_get_mark(buf, ":")
    assert.are.same(lnum, prompt_mark[1], "prompt mark expected to be in line " .. tostring(lnum))
  end
end


describe('dap.repl', function()
  local server
  after_each(function()
    if server then
      dap.terminate()
      server.stop()
      helpers.wait(function() return dap.session() == nil end, "session should become nil")
      server = nil
      dap.adapters.dummy = nil
    end
    repl.execute(".format structured")
    local buf = repl.open()
    api.nvim_buf_delete(buf, {force = true})
  end)
  it("append doesn't add newline with newline = false", function()
    local buf = repl.open()
    repl.append('foo', nil, { newline = false })
    repl.append('bar', nil, { newline = false })
    assert_prompt_mark(buf, 1)
    repl.append('\nbaz\n', nil, { newline = false })

    local lines = api.nvim_buf_get_lines(buf, 0, -1, true)
    assert.are.same({'foobar', 'baz', ''}, lines)
    assert_prompt_mark(buf, 3)
  end)

  it("adds newline with newline = true", function()
    local buf = repl.open()
    assert_prompt_mark(buf, 1)
    repl.append("foo", nil, { newline = true })
    assert_prompt_mark(buf, 2)
    repl.append("bar", nil, { newline = true })
    assert_prompt_mark(buf, 3)
    repl.append("\nbaz\n", nil, { newline = true })
    assert_prompt_mark(buf, 6)

    local lines = api.nvim_buf_get_lines(buf, 0, -1, true)
    assert.are.same({"foo", "bar", "", "baz", "", ""}, lines)
  end)

  it("repl.execute inserts text and executes it, shows result", function()
    server = require("spec.server").spawn()
    dap.adapters.dummy = server.adapter
    server.client.evaluate = function(self, request)
      self:send_response(request, {
        result = "2",
        variablesReference = 0
      })
    end
    helpers.run_and_wait_until_initialized(config, server)
    local buf = repl.open()
    repl.execute("1 + 1")
    local commands = helpers.wait_for_response(server, "evaluate")
    assert.are.same({"initialize", "launch", "evaluate"}, commands)
    helpers.wait(
      function()
        local lines = api.nvim_buf_get_lines(buf, 0, -1, true)
        return lines[2] == "2"
      end,
      function()
        return api.nvim_buf_get_lines(buf, 0, -1, true)
      end
    )
    local lines = api.nvim_buf_get_lines(buf, 0, -1, true)
    assert.are.same({"dap> 1 + 1", "2", ""}, lines)
    assert_prompt_mark(buf, 3)
  end)
  it("repl.execute shows structured results", function()
    server = require("spec.server").spawn()
    dap.adapters.dummy = server.adapter
    server.client.evaluate = function(self, request)
      self:send_response(request, {
        result = "table xy",
        variablesReference = 1
      })
    end
    server.client.variables = function(self, request)
      self:send_response(request, {
        variables = {
          {
            name = "x",
            value = 1,
            variablesReference = 0
          },
          {
            name = "y",
            value = 2,
            variablesReference = 0
          }
        }
      })
    end
    helpers.run_and_wait_until_initialized(config, server)
    local buf = repl.open()
    repl.execute("tbl")
    local commands = helpers.wait_for_response(server, "evaluate")
    assert.are.same({"initialize", "launch", "evaluate"}, commands)
    helpers.wait(
      function()
        local lines = api.nvim_buf_get_lines(buf, 0, -1, true)
        return lines[2] == "table xy"
      end,
      function()
        return api.nvim_buf_get_lines(buf, 0, -1, true)
      end
    )
    local expected = {
      "dap> tbl",
      "table xy",
      "  x: 1",
      "  y: 2",
      "",
    }
    assert.are.same(expected, api.nvim_buf_get_lines(buf, 0, -1, true))
    assert_prompt_mark(buf, 5)

    server.spy.clear()
    repl.execute("tbl")
    commands = helpers.wait_for_response(server, "evaluate")
    assert.are.same({"evaluate"}, commands)
    helpers.wait(
      function()
        local lines = api.nvim_buf_get_lines(buf, 0, -1, true)
        return lines[6] == "table xy"
      end,
      function()
        return api.nvim_buf_get_lines(buf, 0, -1, true)
      end
    )
    expected = {
      "dap> tbl",
      "table xy",
      "  x: 1",
      "  y: 2",
      "dap> tbl",
      "table xy",
      "  x: 1",
      "  y: 2",
      "",
    }
    assert.are.same(expected, api.nvim_buf_get_lines(buf, 0, -1, true))
  end)
end)


describe("dap.repl completion", function()
  local server
  before_each(function()
    server = require("spec.server").spawn()
    dap.adapters.dummy = server.adapter
  end)
  after_each(function()
    dap.terminate()
    server.stop()
    require('dap.breakpoints').clear()
    helpers.wait(function() return dap.session() == nil end, "session should become nil")
    local repl_buf = repl.open()
    api.nvim_buf_delete(repl_buf, { force = true })
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
