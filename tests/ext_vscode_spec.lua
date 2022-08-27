describe('dap.ext.vscode', function()
  it('can load launch.json file and map adapter type to filetypes', function()
    local dap = require('dap')
    local vscode = require('dap.ext.vscode')
    vscode.load_launchjs('tests/launch.json', { bar = { 'c', 'cpp' } })
    assert.are.same(3, vim.tbl_count(dap.configurations))
    assert.are.same({ { type = 'java', request = 'launch', name = "java test" }, }, dap.configurations.java)
    assert.are.same({ { type = 'bar', request = 'attach', name = "bar test" }, }, dap.configurations.c)
    assert.are.same({ { type = 'bar', request = 'attach', name = "bar test" }, }, dap.configurations.cpp)
  end)

  it('supports promptString input', function()
    local prompt
    local default
    vim.fn.input = function(prompt_, default_)
      prompt = prompt_
      default = default_
      return 'Fake input'
    end
    local vscode = require('dap.ext.vscode')
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
      result = configs[1].program()
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
    local vscode = require('dap.ext.vscode')
    vim.ui.select = function(options_, opts_, on_choice)
      options = options_
      opts = opts_
      on_choice(options_[1])
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
      result = configs[1].program()
      ok = true
    end)()
    vim.wait(1000, function() return ok end)
    assert.are.same(true, ok, "coroutine must finish")
    assert.are.same("${workspaceFolder}/one", result)
    assert.are.same("Select input", opts.prompt)
    assert.are.same({"one", "two", "three"}, options)
  end)
end)
