
describe('variable.builtin', function()
  it('expand file', function()
    local result = require("dap").expand_config_variables("${file}")
    assert.are.same(vim.fn.expand("%:p"), result)
  end)

  it('expand file multiply', function()
    local result = require("dap").expand_config_variables("${file}-${fileBasename}-${file}")
    assert.are.same(vim.fn.expand("%:p") .. '-' .. vim.fn.expand("%:t") .. '-' .. vim.fn.expand("%:p"), result)
  end)

  it('expand workspaceFolder', function()
    local result = require("dap").expand_config_variables("--${workspaceFolder}--")
    assert.are.same('--' .. vim.fn.getcwd() .. '--', result)
  end)
end)

describe('variable.env', function()
  it('expand env:HOME', function()
    local home = require("dap").expand_config_variables("${env:HOME}")
    assert.are.same(os.getenv("HOME"), home)

    local not_home = require("dap").expand_config_variables("env:HOME")
    assert.are.same("env:HOME", not_home)
  end)

  it('expand env complex', function()
    do
      local result = require("dap").expand_config_variables("${env:HOME}--${env:PATH}")
      assert.are.same(os.getenv("HOME") .. "--" .. os.getenv("PATH"), result)
    end
    do
      local result = require("dap").expand_config_variables("${env:HOME}--${env:PATH}--${env:HOME}")
      assert.are.same(os.getenv("HOME") .. "--" .. os.getenv("PATH") .. "--" .. os.getenv("HOME"), result)
    end
  end)
end)

describe('variable.command', function()
  it('expand pickProcess', function()
    local options
    -- mock vim.ui.select
    vim.ui.select = function(options_, _, on_choice)
      options = options_
      on_choice(options_[1])
    end
    local result = require("dap").expand_config_variables("${command:pickProcess}")
    -- pid is number
    assert.are.same(tostring(options[1].pid), result)
  end)
end)

describe('variable.register', function()
  it('static handle', function()
    require("dap").register_command("test", function()
      return "value"
    end)

    local result = require("dap").expand_config_variables("${command:test}")
    assert.are.same("value", result)
  end)

  it('asynchronous handle', function()
    require("dap").register_command("coroutine", function()
      local co = coroutine.running()
      return coroutine.create(function()
        vim.defer_fn(function()
          coroutine.resume(co, "defer_value")
        end, 2000)
      end)
    end)
    local result = require("dap").expand_config_variables("${command:coroutine}")
    assert.are.same("defer_value", result)
  end)
end)
