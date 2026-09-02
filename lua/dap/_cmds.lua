local api = vim.api
local M = {}
local mime_to_filetype = {
  ['text/javascript'] = 'javascript'
}


---@param args vim.api.keyset.create_user_command.command_args
function M.eval(args)
  local oldbuf = api.nvim_get_current_buf()
  local name = string.format("dap-eval://%s", vim.bo[oldbuf].filetype)
  if args.smods.vertical then
    vim.cmd.vsplit({name})
  elseif args.smods.tab == 1 then
    vim.cmd.tabedit(name)
  else
    local size = math.max(5, math.floor(vim.o.lines * 1/5))
    vim.cmd.split({name, mods = args.smods, range = { size }})
  end
  local newbuf = api.nvim_get_current_buf()
  if args.range ~= 0 then
    local lines = api.nvim_buf_get_lines(oldbuf, args.line1 -1 , args.line2, true)
    local indent = math.huge
    for _, line in ipairs(lines) do
      indent = math.min(line:find("[^ ]") or math.huge, indent)
    end
    if indent ~= math.huge and indent > 0 then
      for i, line in ipairs(lines) do
        lines[i] = line:sub(indent)
      end
    end
    api.nvim_buf_set_lines(newbuf, 0, -1, true, lines)
    vim.bo[newbuf].modified = false
  end
  if args.bang then
    vim.cmd.w()
  end
end


---@param args vim.api.keyset.create_user_command.command_args
function M.new(args)
  local dap = require("dap")
  local fargs = args.fargs
  if not next(fargs) then
    dap.continue({ new = true })
    return
  end
  local bufnr = api.nvim_get_current_buf()
  require("dap.async").run(function()
    for _, get_configs in pairs(dap.providers.configs) do
      local configs = get_configs(bufnr)
      for _, config in ipairs(configs) do
        if vim.tbl_contains(fargs, config.name) then
          dap.run(config)
        end
      end
    end
  end)
end


---@param sessions table<number, dap.Session>
---@param id number
---@return dap.Session?
local function rec_get_session(sessions, id)
  local session = sessions[id]
  if session then
    return session
  end
  for _, s in pairs(sessions) do
    local result = rec_get_session(s.children, id)
    if result then
      return result
    end
  end
  return nil
end


---@param buf integer
function M.source(buf)
  local fname = api.nvim_buf_get_name(buf)
  local session_id, source_ref, source_path = fname:match("dap%-src://(%d+)/(%d+)/(.*)")
  session_id = assert(tonumber(session_id), "dap-src:// uri must contain session id")
  source_ref = tonumber(source_ref)
  local dap = require("dap")
  local session = rec_get_session(dap.sessions(), session_id)
  if not session then
    return
  end
  local params = {
    source = {
      sourceReference = source_ref
    },
    sourceReference = source_ref
  }
  local response
  session:request("source", params, function (err, result)
    response = {err, result}
  end)
  vim.wait(5000, function() return response ~= nil end)
  local err = response[1]
  if err then
    require("dap.utils").notify(tostring(err), vim.log.levels.WARN)
    return
  end
  local result = response[2]
  api.nvim_buf_set_lines(buf, 0, -1, true, vim.split(result.content, "\n", { plain = true }))
  local adapter_options = session.adapter.options or {}
  local ft = mime_to_filetype[response.mimeType] or adapter_options.source_filetype
  if ft then
    vim.bo[buf].filetype = ft
  elseif source_path ~= "" and vim.filetype then
    local ok
    ok, ft = pcall(vim.filetype.match, { buf = buf, filename = source_path })
    if ok and ft then
      vim.bo[buf].filetype = ft
    end
  end
end


function M.new_complete()
  local bufnr = api.nvim_get_current_buf()
  local dap = require("dap")
  local candidates = {}
  local done = false
  require("dap.async").run(function()
    for _, get_configs in pairs(dap.providers.configs) do
      local configs = get_configs(bufnr)
      for _, config in ipairs(configs) do
        local name = config.name:gsub(" ", "\\ ")
        table.insert(candidates, name)
      end
    end
    done = true
  end)
  vim.wait(2000, function() return done == true end)
  return candidates
end


function M.bufread_eval()
  local bufnr = api.nvim_get_current_buf()
  local fname = api.nvim_buf_get_name(bufnr)
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].bufhidden = "wipe"
  local ft = fname:match("dap%-eval://(%w+)(.*)")
  if ft and ft ~= "" then
    vim.bo[bufnr].filetype = ft
  else
    local altbuf = vim.fn.bufnr("#", false)
    if altbuf then
      vim.bo[bufnr].filetype = vim.bo[altbuf].filetype
    end
  end
  api.nvim_create_autocmd("BufWriteCmd", {
    buffer = bufnr,
    callback = function(args)
      vim.bo[args.buf].modified = false
      local repl = require("dap.repl")
      local lines = api.nvim_buf_get_lines(args.buf, 0, -1, true)
      repl.execute(table.concat(lines, "\n"))
      repl.open()
    end,
  })
end


---@param args vim.api.keyset.create_autocmd.callback_args
function M.newlaunchjson(args)
  if vim.snippet then
    local text = [[{
    "\$schema": "https://raw.githubusercontent.com/mfussenegger/dapconfig-schema/master/dapconfig-schema.json",
    "version": "0.2.0",
    "configurations": [
        {
            "type": "${1:adaptername}",
            "request": "${2|launch,request|}",
            "name": "${3:run}"${0}
        }
    ]
}]]
    api.nvim_buf_call(args.buf, function()
      vim.snippet.expand(text)
    end)
  else
    local lines = {
      '{',
      '   "$schema": "https://raw.githubusercontent.com/mfussenegger/dapconfig-schema/master/dapconfig-schema.json",',
      '   "version": "0.2.0",',
      '   "configurations": [',
      '       {',
      '           "type": "<adapter-name>",',
      '           "request": "launch",',
      '           "name": "Launch"',
      '       }',
      '   ]',
      '}'
    }
    api.nvim_buf_set_lines(args.buf, 0, -1, true, lines)
  end
end


function M.yank_evalname()
  if vim.v.event.operator ~= "y" or vim.v.event.visual == true then
    return
  end
  local buf = api.nvim_get_current_buf()
  local layer = require("dap.ui").get_layer(buf)
  if not layer then
    return
  end
  local lnum = api.nvim_win_get_cursor(0)[1] - 1
  local item = (layer.get(lnum) or {}).item
  if item and item.evaluateName then
    vim.fn.setreg("e", item.evaluateName)
  end
end


function M.show_logs()
  local log = require("dap.log")
  log.create_logger("dap.log")
  for _, logger in pairs(log._loggers) do
    vim.cmd.tabnew(logger._path)
  end
end


return M
