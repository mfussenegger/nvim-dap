local luassert = require('luassert')
local spy = require('luassert.spy')
local venv_dir = os.tmpname()
local dap = require('dap')
local helpers = require("spec.helpers")

local function get_num_handles()
  local pid = vim.fn.getpid()
  local output = vim.fn.system({"lsof", "-p", tostring(pid)})
  local lines = vim.split(output, "\n", { plain = true })
  return #lines, output
end


describe('dap with debugpy', function()
  os.remove(venv_dir)
  if vim.fn.executable("uv") == 1 then
    os.execute(string.format("uv venv '%s'", venv_dir))
    -- tmpfile could be on tmpfs in which case uv pip spits out hard-copy not-working warnings
    -- -> use link-mode=copy
    os.execute(string.format("uv --directory '%s' pip install --link-mode=copy debugpy", venv_dir))
  else
    os.execute('python -m venv "' .. venv_dir .. '"')
    os.execute(venv_dir .. '/bin/python -m pip install debugpy')
  end
  after_each(function()
    dap.terminate()
    require('dap.breakpoints').clear()
  end)

  it('Basic debugging flow', function()
    local breakpoints = require('dap.breakpoints')
    dap.adapters.python = {
      type = 'executable',
      command = venv_dir .. '/bin/debugpy-adapter',
      options = {
        cwd = venv_dir,
      }
    }
    local program = vim.fn.expand('%:p:h') .. '/spec/example.py'
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
    vim.fn.bufload(bufnr)
    breakpoints.set({}, bufnr, bp_lnum)
    local events = {}
    local dummy_payload = nil
    dap.listeners.after.event_initialized['dap.tests'] = function(session)
      events.initialized = true
      ---@diagnostic disable-next-line: undefined-field
      dummy_payload = session.config.dummy_payload
    end
    dap.listeners.after.setBreakpoints['dap.tests'] = function(_, _, resp)
      events.setBreakpoints = resp
    end
    dap.listeners.after.event_stopped['dap.tests'] = function(session)
      vim.wait(5000, function()
        return session.stopped_thread_id ~= nil
      end)
      dap.continue()
      events.stopped = true
    end

    -- force log creation now to not interfere with handle leak check
    require("dap.session")

    local num_handles, lsof_output = get_num_handles()

    local launch = spy.on(dap, 'launch')
    dap.run(config, { filetype = 'python' })
    helpers.wait(
      function() return events.stopped end,
      function() return "Must hit breakpoints. Events: " .. vim.json.encode(events) end
    )
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
    assert(dummy_payload)
    assert.are_not.same(dummy_payload.cwd, '${workspaceFolder}')
    assert.are.same(dummy_payload.numbers, {1, 2, 3, 4})
    assert.are.same(dummy_payload.strings, {'a', 'b', 'c'})
    assert.are.same(dummy_payload['key_with_' .. vim.fn.getcwd()], 'value')

    -- ensure `called_with` below passes
    config.dummy_payload = dummy_payload

    luassert.spy(launch).was.called_with(dap.adapters.python, config, { cwd = venv_dir, filetype = 'python' })

    dap.terminate()
    vim.wait(1000, function() return dap.session() == nil end)

    helpers.wait(
      function()
        return num_handles == get_num_handles()
      end,
      function()
        local pid = vim.fn.getpid()
        local output = vim.fn.system({"lsof", "-p", tostring(pid)})
        local lines = vim.split(output, "\n", { plain = true })
        local new_num_handles = #lines
        return string.format(
          "Must not leak handles. %d should be %d\nHandles:\n%s\n\nBefore:\n%s\n\n",
          new_num_handles,
          num_handles,
          output,
          lsof_output
        )
      end
    )
    assert.are.same(num_handles, get_num_handles())
  end)
end)
vim.fn.delete(venv_dir, 'rf')
