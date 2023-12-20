---@diagnostic disable: duplicate-set-field
local ui_input = vim.ui.input
local vscode = require('dap.ext.vscode')
describe('dap.ext.vscode', function()
  after_each(function()
    vim.ui.input = ui_input
  end)

  it('can load launch.json file and map adapter type to filetypes', function()
    local dap = require('dap')
    vscode.load_launchjs('tests/launch.json', { bar = { 'c', 'cpp' } })
    assert.are.same(3, vim.tbl_count(dap.configurations))
    assert.are.same({ { type = 'java', request = 'launch', name = "java test" }, }, dap.configurations.java)
    assert.are.same({ { type = 'bar', request = 'attach', name = "bar test" }, }, dap.configurations.c)
    assert.are.same({ { type = 'bar', request = 'attach', name = "bar test" }, }, dap.configurations.cpp)
  end)

  it('supports promptString input', function()
    local prompt
    local default
    vim.ui.input = function(opts, on_input)
      prompt = opts.prompt
      default = opts.default
      on_input('Fake input')
    end
    local jsonstr = [[
      {
        "configurations": [
          {
            "type": "dummy",
            "request": "launch",
            "name": "Dummy",
            "program": "${workspaceFolder}/${input:myInput}"
          }
        ],
        "inputs": [
          {
            "id": "myInput",
            "type": "promptString",
            "description": "Your input",
            "default": "the default value"
          }
        ]
      }
    ]]
    local configs = vscode._load_json(jsonstr)
    local ok = false
    local result
    coroutine.wrap(function()
      local conf = configs[1]()
      result = conf.program
      ok = true
    end)()
    vim.wait(1000, function() return ok end)
    assert.are.same("${workspaceFolder}/Fake input", result)
    assert.are.same("Your input: ", prompt)
    assert.are.same("the default value", default)
  end)

  it('supports pickString input', function()
    local options
    local opts
    local label
    vim.ui.select = function(options_, opts_, on_choice)
      options = options_
      opts = opts_
      label = opts_.format_item(options_[1])
      on_choice(options_[1])
    end
    local jsonstr = [[
      {
        "configurations": [
          {
            "type": "dummy",
            "request": "launch",
            "name": "Dummy",
            "program": "${workspaceFolder}/${input:my_input}"
          }
        ],
        "inputs": [
          {
            "id": "my_input",
            "type": "pickString",
            "options": ["one", "two", "three"],
            "description": "Select input"
          }
        ]
      }
    ]]
    local configs = vscode._load_json(jsonstr)
    local ok = false
    local result
    coroutine.wrap(function()
      local config = configs[1]()
      result = config.program
      ok = true
    end)()
    vim.wait(1000, function() return ok end)
    assert.are.same(true, ok, "coroutine must finish")
    assert.are.same("one", label)
    assert.are.same("${workspaceFolder}/one", result)
    assert.are.same("Select input", opts.prompt)
    assert.are.same({"one", "two", "three"}, options)
  end)

  it('inputs can be used in arrays or dicts', function()
    vim.fn.input = function(opts)
      return opts.default
    end
    local jsonstr = [[
      {
        "configurations": [
          {
            "type": "dummy",
            "request": "launch",
            "name": "Dummy",
            "args": ["one", "${input:myInput}", "three"]
          }
        ],
        "inputs": [
          {
            "id": "myInput",
            "type": "promptString",
            "description": "Your input",
            "default": "the default value"
          }
        ]
      }
    ]]
    local config = vscode._load_json(jsonstr)[1]
    assert.are.same(3, #config.args)
    assert.are.same("one", config.args[1])
    assert.are.same("${input:myInput}", config.args[2])
    assert.are.same("three", config.args[3])
    local ok = false
    coroutine.wrap(function()
      config = config()
      ok = true
    end)()
    vim.wait(1000, function() return ok end)
    assert.are.same("the default value", config.args[2])
  end)
  it('can use two inputs within one property', function()
    vim.fn.input = function(opts)
      return opts.default
    end
    local jsonstr = [[
      {
        "configurations": [
          {
            "type": "dummy",
            "request": "launch",
            "name": "Dummy",
            "program": "${input:input1}-${input:input2}"
          }
        ],
        "inputs": [
          {
            "id": "input1",
            "type": "promptString",
            "description": "first input",
            "default": "one"
          },
          {
            "id": "input2",
            "type": "promptString",
            "description": "second input",
            "default": "two"
          }
        ]
      }
    ]]
    local config = vscode._load_json(jsonstr)[1]
    local ok = false
    coroutine.wrap(function()
      ok, config = true, config()
    end)()
    vim.wait(1000, function() return ok end)
    assert.are.same("one-two", config.program)
  end)

  it('supports OS specific properties which are lifted to top-level', function()
    if vim.loop.os_uname().sysname == 'Linux' then
      local jsonstr = [[
      {
        "configurations": [
          {
            "type": "dummy",
            "request": "launch",
            "name": "Dummy",
            "linux": {
              "foo": "bar"
            }
          }
        ]
      }
      ]]
    local config = vscode._load_json(jsonstr)[1]
    assert.are.same("bar", config.foo)
    end
  end)

  it('supports promptString without default value', function()
    local prompt
    local default
    vim.fn.input = function(opts)
      prompt = opts.prompt
      default = opts.default
      return 'Fake input'
    end
    local jsonstr = [[
      {
        "configurations": [
          {
            "type": "dummy",
            "request": "launch",
            "name": "Dummy",
            "program": "${workspaceFolder}/${input:myInput}"
          }
        ],
        "inputs": [
          {
            "id": "myInput",
            "type": "promptString",
            "description": "Your input"
          }
        ]
      }
    ]]
    local configs = vscode._load_json(jsonstr)
    local config
    coroutine.wrap(function()
      config = configs[1]()
    end)()
    vim.wait(1000, function() return config ~= nil end)
    assert.are.same("${workspaceFolder}/Fake input", config.program)
    assert.are.same("Your input: ", prompt)
    assert.are.same("", default)
  end)

  it('supports pickString with options', function()
    local opts
    local label
    vim.ui.select = function(options_, opts_, on_choice)
      opts = opts_
      label = opts_.format_item(options_[1])
      on_choice(options_[1])
    end
    local jsonstr = [[
      {
        "configurations": [
          {
            "type": "dummy",
            "request": "launch",
            "name": "Dummy",
            "program": "${workspaceFolder}/${input:my_input}"
          }
        ],
        "inputs": [
          {
            "id": "my_input",
            "type": "pickString",
            "options": [
              { "label": "First value", "value": "one" },
              { "label": "Second value", "value": "two" }
            ],
            "description": "Select input"
          }
        ]
      }
    ]]
    local configs = vscode._load_json(jsonstr)
    local config
    coroutine.wrap(function()
      config = configs[1]()
    end)()
    vim.wait(1000, function() return config ~= nil end)
    assert(config, "coroutine must finish")
    assert.are.same("${workspaceFolder}/one", config.program)
    assert.are.same("Select input", opts.prompt)
    assert.are.same("First value", label)
  end)

  it('supports pickString with options, nothing selected', function()
    vim.ui.select = function(_, _, on_choice)
      on_choice(nil)
    end
    local jsonstr = [[
      {
        "configurations": [
          {
            "type": "dummy",
            "request": "launch",
            "name": "Dummy",
            "program": "${workspaceFolder}/${input:my_input}"
          }
        ],
        "inputs": [
          {
            "id": "my_input",
            "type": "pickString",
            "options": [
              { "label": "First value", "value": "one" },
              { "label": "Second value", "value": "two" }
            ],
            "description": "Select input"
          }
        ]
      }
    ]]
    local configs = vscode._load_json(jsonstr)
    local config
    coroutine.wrap(function()
      config = configs[1]()
    end)()
    vim.wait(1000, function() return config ~= nil end)
    assert(config, "coroutine must finish")
    -- input defaults to ''
    assert.are.same("${workspaceFolder}/", config.program)
  end)

  it("evaluates input once per config use", function()
    local prompt
    local default
    local calls = 0
    vim.fn.input = function(opts)
      prompt = opts.prompt
      default = opts.default
      calls = calls + 1
      return 'Fake input'
    end
    local jsonstr = [[
      {
        "configurations": [
          {
            "type": "dummy",
            "request": "launch",
            "name": "Dummy",
            "program": "${input:myInput}",
            "args": [
              "${input:myInput}",
              "foo",
              "${input:myInput}"
            ]
          }
        ],
        "inputs": [
          {
            "id": "myInput",
            "type": "promptString",
            "description": "Your input"
          }
        ]
      }
    ]]
    local configs = vscode._load_json(jsonstr)
    local config
    coroutine.wrap(function()
      config = configs[1]()
    end)()
    vim.wait(1000, function() return config ~= nil end)

    assert.are.same(calls, 1)
    assert.are.same("Your input: ", prompt)
    assert.are.same("", default)
  end)
end)
