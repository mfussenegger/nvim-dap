local luassert = require('luassert')
local spy = require('luassert.spy')
local venv_dir = os.tmpname()
local dap = require('dap')

describe('dap with debugpy', function()
  os.remove(venv_dir)
  os.execute('python -m venv "' .. venv_dir .. '"')
  os.execute(venv_dir .. '/bin/python -m pip install debugpy')
  after_each(function()
    dap.terminate()
    require('dap.breakpoints').clear()
  end)

  it('Basic debugging flow', function()
    local breakpoints = require('dap.breakpoints')
    dap.adapters.python = {
      type = 'executable',
      command = venv_dir .. '/bin/python',
      args = {'-m', 'debugpy.adapter'},
      options = {
        cwd = venv_dir,
      }
    }
    local program = vim.fn.expand('%:p:h') .. '/tests/example.py'
    local config = {
      type = 'python',
      request = 'launch',
      name = 'Launch file',
      program = program,
      dummy_payload = {
        cwd = '${workspaceFolder}',
        ['key_with_${workspaceFolder}'] = 'value',
        numbers = {1, 2, 3, 4},
        strings = {'a', 'b', 'c'},
      }
    }
    local bp_lnum = 8
    local bufnr = vim.fn.bufadd(program)
    breakpoints.set({}, bufnr, bp_lnum)
    local events = {}
    local dummy_payload = nil
    dap.listeners.after.event_initialized['dap.tests'] = function(session)
      events.initialized = true
      dummy_payload = session.config.dummy_payload
    end
    dap.listeners.after.setBreakpoints['dap.tests'] = function(_, _, resp)
      events.setBreakpoints = resp
    end
    dap.listeners.after.event_stopped['dap.tests'] = function()
      vim.wait(1000, function()
        local session = dap.session()
        return session.stopped_thread_id ~= nil
      end)
      dap.continue()
      events.stopped = true
    end

    local launch = spy.on(dap, 'launch')
    dap.run(config, { filetype = 'python' })
    vim.wait(1000, function() return dap.session() == nil end, 100)
    assert.are.same({
      initialized = true,
      setBreakpoints = {
        breakpoints = {
          {
            id = 0,
            line = bp_lnum,
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

    -- variable must expand to concrete value
    assert.are_not.equals(dummy_payload.cwd, '${workspaceFolder}')
    assert.are.same(dummy_payload.numbers, {1, 2, 3, 4})
    assert.are.same(dummy_payload.strings, {'a', 'b', 'c'})
    assert.are.equals(dummy_payload['key_with_' .. vim.fn.getcwd()], 'value')

    -- ensure `called_with` below passes
    config.dummy_payload = dummy_payload

    luassert.spy(launch).was.called_with(dap.adapters.python, config, { cwd = venv_dir, filetype = 'python' })
  end)
end)
vim.fn.delete(venv_dir, 'rf')
