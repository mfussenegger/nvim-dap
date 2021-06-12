describe('dap', function()
  local venv_dir
  before_each(function()
    venv_dir = os.tmpname()
    os.remove(venv_dir)
    os.execute('python -m venv "' .. venv_dir .. '"')
    os.execute(venv_dir .. '/bin/python -m pip install debugpy')
  end)
  after_each(function()
    vim.fn.delete(venv_dir, 'rf')
  end)

  it('Basic debugging flow', function()
    local dap = require('dap')
    local breakpoints = require('dap.breakpoints')
    dap.adapters.python = {
      type = 'executable',
      command = venv_dir .. '/bin/python',
      args = {'-m', 'debugpy.adapter'}
    }
    local program = vim.fn.expand('%:p:h') .. '/tests/example.py'
    local config = {
      type = 'python',
      request = 'launch',
      name = 'Launch file',
      program = program,
    }
    local bufnr = vim.fn.bufadd(program)
    breakpoints.set({}, bufnr, 5)
    local events = {}
    dap.listeners.after.event_initialized['dap.tests'] = function()
      events.initialized = true
    end
    dap.listeners.after.setBreakpoints['dap.tests'] = function(_, _, resp)
      events.setBreakpoints = resp
    end
    dap.listeners.after.event_stopped['dap.tests'] = function()
      events.stopped = true
      dap.continue()
    end
    dap.run(config)
    vim.wait(1000, function() return dap.session() == nil end, 100)
    assert.are.same({
      initialized = true,
      setBreakpoints = {
        breakpoints = {
          {
            id = 0,
            line = 5,
            source = {
              name = 'example.py',
              path = program,
            },
            verified = true
          },
        },
      },
      stopped = true,
    }, events)
  end)
end)
