local ext_utils = require('dap.ext.utils')
local M = {}

---@param bufnr integer
---@return dap.Configuration[]
function M.getconfigs(bufnr)
  local ok, neoconf = pcall(require, "neoconf")
  if not ok then
    return {}
  end

  local data = neoconf.get("dap", nil, { buffer = bufnr }) or {}
  return ext_utils.load_configs(data)
end

function M.register()
  if not pcall(require, "neoconf") then
    return
  end

  require("neoconf.plugins").register({
    name = "dap",
    on_schema = function(schema)
      schema:set("dap", {
        description = "nvim-dap settings",
        type = "object",
        properties = {
          configurations = {
            description = "List of debug configurations",
            type = "array",
            items = {
              type = "object",
              properties = {
                -- required properties
                name = {
                  description = "A user-readable name for the configuration",
                  type = "string",
                },
                type = {
                  description = "Which debug adapter to use",
                  type = "string",
                },
                request = {
                  description = "Indicates whether the debug adapter should launch a debugee or attach to one that is already running",
                  type = "string",
                  enum = { "launch", "attach" },
                },
                -- extra properties, supported by many debuggers
                -- https://code.visualstudio.com/docs/editor/debugging#_launchjson-attributes
                -- types are omitted to be safe
                program = {
                  description = "Path to the program to be debugged",
                },
                args = {
                  description = "Arguments passed to the program to debug",
                },
                env = {
                  description = "Environment variables to set for the program being debugged",
                },
                envFile = {
                  description = "Path to a file containing environment variable definitions",
                },
                cwd = {
                  description = "The working directory of the program being debugged",
                },
                host = {
                  description = "Host to use when attaching to a running process",
                },
                port = {
                  description = "Port to use when attaching to a running process",
                },
                stopOnEntry = {
                  description = "Break immediately when the program launches",
                },
                console = {
                  description = "What kind of console to use, valid values are usually `internalConsole`, `integratedTerminal` and `externalTerminal`",
                },
              },
              required = { "name", "type", "request" },
            },
          },
          inputs = {
            description = "List of custom input prompts",
            type = "array",
            items = {
              type = "object",
              properties = {
                id = {
                  description = "A unique identifier for the input",
                  type = "string",
                },
                type = {
                  description = "The input type - `pickString` to choose from a list of options, or `promptString` to input arbitrary text",
                  type = "string",
                  enum = { "pickString", "promptString" },
                },
                description = {
                  description = "Descriptive text shown to the user",
                  type = "string",
                },
                default = {
                  description = "The default value for the input",
                  type = "string",
                  default = "",
                },
              },
              ["if"] = {
                properties = {
                  type = {
                    const = "pickString",
                  },
                },
              },
              ["then"] = {
                properties = {
                  options = {
                    description = "The list of options shown to the user",
                    type = "array",
                    items = {
                      type = { "string", "object" },
                      properties = {
                        label = {
                          description = "The label shown for the option",
                          type = "string",
                        },
                        value = {
                          description = "The value of the option",
                          type = "string",
                        },
                      },
                      required = { "label", "value" },
                    },
                  },
                },
                required = { "options" },
              },
            },
            required = { "id", "type" },
          },
        },
      })
    end,
  })
end

return M
