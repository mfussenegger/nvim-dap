local api = vim.api

describe('breakpoints', function()

  require('dap')
  local breakpoints = require('dap.breakpoints')
  after_each(breakpoints.clear)

  it('can set normal breakpoints', function()
    breakpoints.set()
    local expected = {
      [1] = {
        {
          line = 1,
        },
      },
    }
    assert.are.same(expected, breakpoints.get())
    breakpoints.set() -- still on the same line, so this replaces the previous one
    assert.are.same(expected, breakpoints.get())
  end)

  it('can set a logpoint', function()
    breakpoints.set({ log_message = 'xs={xs}' })
    local expected = {
      [1] = {
        {
          line = 1,
          logMessage = 'xs={xs}',
        },
      },
    }
    assert.are.same(expected, breakpoints.get())
  end)

  it('can remove a breakpoint', function()
    local lnum = api.nvim_win_get_cursor(0)[1]
    breakpoints.toggle({ log_message = 'xs={xs}'})
    local expected = {
      [1] = {
        {
          line = 1,
          logMessage = 'xs={xs}',
        },
      },
    }
    assert.are.same(expected, breakpoints.get())
    breakpoints.remove(api.nvim_get_current_buf(), lnum)
    assert.are.same({}, breakpoints.get())
  end)

  it('toggle adds bp if missing, otherwise removes', function()
    breakpoints.toggle()
    assert.are.same({{{line = 1}}}, breakpoints.get())
    breakpoints.toggle()
    assert.are.same({}, breakpoints.get())
  end)

  it('can convert breakpoints to qf_list items', function()
    local buf = api.nvim_get_current_buf()
    api.nvim_buf_set_lines(buf, 0, -1, true, {'Hello breakpoint'})
    breakpoints.toggle({ condition = 'x > 10' })
    assert.are.same(
      {
        {
          bufnr = 1,
          col = 0,
          lnum = 1,
          text = 'Hello breakpoint, Condition: x > 10'
        }
      },
      breakpoints.to_qf_list(breakpoints.get())
    )

    local bps = {
      [buf] = {
        {
          line = 1,
          condition = ""
        },
      }
    }
    assert.are.same(
      {
        {
          bufnr = buf,
          col = 0,
          lnum = 1,
          text = "Hello breakpoint"
        }
      },
      breakpoints.to_qf_list(bps)
    )
  end)
end)
