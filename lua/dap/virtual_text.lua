
M = {}

local hl_namespace
local api = vim.api

local require_ok, locals = pcall(require, "nvim-treesitter.locals")
local require_ok, utils = pcall(require, "nvim-treesitter.utils")

if not hl_namespace then
  hl_namespace = api.nvim_create_namespace("dap.treesitter")
end

local function is_in_node_range(node, line, col)
  local start_line, start_col, end_line, end_col = node:range()
  if line >= start_line and line <= end_line then
    if line == start_line and line == end_line then
      return col >= start_col and col < end_col
    elseif line == start_line then
      return col >= start_col
    elseif line == end_line then
      return col < end_col
    else
      return true
    end
  else
    return false
  end
end

function M.set_virtual_text(stackframe)
  if not stackframe then return end
  if not stackframe.scopes then return end
  if not require_ok then return end

  local buf = vim.uri_to_bufnr(vim.uri_from_fname(stackframe.source.path))

  local scope_nodes = locals.get_scopes(buf)
  local definition_nodes = locals.get_definitions(buf)
  local variables = {}

  for _, s in ipairs(stackframe.scopes) do
    if s.variables then
      for _, v in pairs(s.variables) do
        variables[v.name] = v
      end
    end
  end

  local virtual_text = {}
  for _, d in pairs(definition_nodes) do
    if d and d.var then -- is definition and is variable definition?
      local node = d.var.node
      local name = utils.get_node_text(node, buf)[1]
      local var_line, var_col = node:start()

      local evaluated = variables[name]
      if evaluated then -- evaluated local with same name exists

        -- is this name really the local or is it in another scope?
        local in_scope = true
        for _, scope in ipairs(scope_nodes) do
          if is_in_node_range(scope, var_line, var_col) and not is_in_node_range(scope, stackframe.line - 1, 0) then
            in_scope = false
            break
          end
        end

        if in_scope then
          virtual_text[node:start()] = (virtual_text[node:start()] and virtual_text[node:start()]..', ' or '')..name..' = '..evaluated.value
        end
      end
    end
  end

  for line, content in pairs(virtual_text) do
    api.nvim_buf_set_virtual_text(buf, hl_namespace, line, {{content, "Comment"}}, {})
  end

end

function M.clear_virtual_text(stackframe)
  if stackframe then
    local buf = vim.uri_to_bufnr(vim.uri_from_fname(stackframe.source.path))
    api.nvim_buf_clear_namespace(buf, hl_namespace, 0, -1)
  else
    for _, buf in ipairs(api.nvim_list_bufs()) do
      api.nvim_buf_clear_namespace(buf, hl_namespace, 0, -1)
    end
  end
end

return M
