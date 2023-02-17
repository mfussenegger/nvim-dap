local api = vim.api

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
