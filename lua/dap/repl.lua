local api = vim.api
local ui = require('dap.ui')
local utils = require('dap.utils')
local M = {}

local history = {
  last = nil,
  entries = {},
  idx = 1,
  max_size = 100,
}

local autoscroll = vim.fn.has('nvim-0.7') == 1

local function get_session()
  return require('dap').session()
end

local execute  -- required for forward reference


local function new_buf()
  local prev_buf = api.nvim_get_current_buf()
  local buf = api.nvim_create_buf(true, true)
  api.nvim_buf_set_name(buf, '[dap-repl]')
  vim.bo[buf].buftype = "prompt"
  vim.bo[buf].omnifunc = "v:lua.require'dap.repl'.omnifunc"
  vim.bo[buf].buflisted = false
  local path = vim.bo[prev_buf].path
  if path and path ~= "" then
    vim.bo[buf].path = path
  end
  api.nvim_buf_set_keymap(buf, 'n', '<CR>', "<Cmd>lua require('dap.ui').trigger_actions({ mode = 'first' })<CR>", {})
  api.nvim_buf_set_keymap(buf, 'n', 'o', "<Cmd>lua require('dap.ui').trigger_actions()<CR>", {})
  api.nvim_buf_set_keymap(buf, 'i', '<up>', "<Cmd>lua require('dap.repl').on_up()<CR>", {})
  api.nvim_buf_set_keymap(buf, 'i', '<down>', "<Cmd>lua require('dap.repl').on_down()<CR>", {})
  vim.fn.prompt_setprompt(buf, 'dap> ')
  vim.fn.prompt_setcallback(buf, execute)
  if vim.fn.has('nvim-0.7') == 1 then
    vim.keymap.set('n', 'G', function()
      autoscroll = vim.v.count == 0
      vim.cmd(string.format('normal! %dG', vim.v.count))
    end, { silent = true, buffer = buf })
    api.nvim_create_autocmd({'InsertEnter', 'CursorMoved'}, {
      group = api.nvim_create_augroup('dap-repl-au', {clear = true}),
      buffer = buf,
      callback = function()
        local active_buf = api.nvim_win_get_buf(0)
        if active_buf == buf then
          local lnum = api.nvim_win_get_cursor(0)[1]
          autoscroll = lnum == api.nvim_buf_line_count(buf)
        end
      end
    })
  end
  vim.bo[buf].filetype = "dap-repl"
  return buf
end


local function new_win(buf, winopts, wincmd)
  assert(not wincmd or type(wincmd) == 'string', 'wincmd must be nil or a string')
  api.nvim_command(wincmd or 'belowright split')
  local win = api.nvim_get_current_win()
  api.nvim_win_set_buf(win, buf)
  if vim.fn.has("nvim-0.11") == 1 then
    vim.wo[win][0].wrap = false
  else
    vim.wo[win].wrap = false
  end
  ui.apply_winopts(win, winopts)
  return win
end

local repl = ui.new_view(
  new_buf,
  new_win, {
    before_open = function()
      return api.nvim_get_current_win()
    end,
    after_open = function(_, prev_win)
      api.nvim_set_current_win(prev_win)
    end
  }
)


M.commands = {
  continue = {'.continue', '.c'},
  next_ = {'.next', '.n'},
  step_back = {'.back', '.b'},
  reverse_continue = {'.reverse-continue', '.rc'},
  into = {'.into'},
  into_targets = {'.into-targets'},
  out = {'.out'},
  scopes = {'.scopes'},
  threads = {'.threads'},
  frames = {'.frames'},
  exit = {'exit', '.exit'},
  up = {'.up'},
  down = {'.down'},
  goto_ = {'.goto'},
  pause = {'.pause', '.p'},
  clear = {'.clear'},
  capabilities = {'.capabilities'},
  help = {'help', '.help', '.h'},
  custom_commands = {}
}


function M.print_stackframes(frames)
  if not repl.buf then
    return
  end
  local session = get_session()
  frames = frames or (session and session.threads[session.stopped_thread_id] or {}).frames or {}
  local context = {}
  M.append('(press enter on line to jump to frame)')
  local start = api.nvim_buf_line_count(repl.buf) - 1
  local render_frame = require('dap.entity').frames.render_item
  context.actions = {
    {
      label = 'Jump to frame',
      fn = function(layer, frame)
        local s = get_session()
        if s then
          s:_frame_set(frame)
          layer.render(frames, render_frame, context, start, start + #frames)
        else
          utils.notify('Cannot navigate to frame without active session', vim.log.levels.INFO)
        end
      end,
    },
  }
  local layer = ui.layer(repl.buf)
  layer.render(frames, render_frame, context)
end


local function print_commands()
  M.append('Commands:')
  for _, commands in pairs(M.commands) do
    if #commands > 0 then
      M.append('  ' .. table.concat(commands, ', '))
    end
  end

  M.append('Custom commands:')
  for command, _ in pairs(M.commands.custom_commands or {}) do
    M.append('  ' .. command)
  end
end


local function evaluate_handler(err, resp)
  if err then
    local message = utils.fmt_error(err)
    if message then
      M.append(message, nil, { newline = false })
    end
    return
  end
  local layer = ui.layer(repl.buf)
  local attributes = (resp.presentationHint or {}).attributes or {}
  if resp.variablesReference > 0 or vim.tbl_contains(attributes, 'rawString') then
    local spec = require('dap.entity').variable.tree_spec
    local tree = ui.new_tree(spec)
    -- tree.render would "append" twice, once for the top element and once for the children
    -- Appending twice would result in a intermediate "dap> " prompt
    -- To avoid that this eagerly fetches the children; pre-renders the region
    -- and lets tree.render override it
    local lnum = api.nvim_buf_line_count(repl.buf) - 1
    if spec.has_children(resp) then
      spec.fetch_children(resp, function()
        tree.render(layer, resp, nil, lnum, -1)
      end)
    else
      tree.render(layer, resp, nil, lnum, -1)
    end
  else
    M.append(resp.result, nil, { newline = false })
  end
end


local function print_scopes(frame)
  if not frame then return end
  local tree = ui.new_tree(require('dap.entity').scope.tree_spec)
  local layer = ui.layer(repl.buf)
  for _, scope in pairs(frame.scopes or {}) do
    tree.render(layer, scope)
  end
end


local function print_threads(threads)
  if not threads then
    return
  end
  local spec = vim.deepcopy(require('dap.entity').threads.tree_spec)
  spec.extra_context = {
    refresh = function()
      local session = get_session()
      if session then
        print_threads(vim.tbl_values(session.threads))
      end
    end
  }
  local tree = ui.new_tree(spec)
  local layer = ui.layer(repl.buf)
  local root = {
    id = 0,
    name = 'Threads',
    threads = vim.tbl_values(threads)
  }
  tree.render(layer, root)
end


function execute(text)
  if text == '' then
    if history.last then
      text = history.last
    else
      return
    end
  else
    history.last = text
    if #history.entries == history.max_size then
      table.remove(history.entries, 1)
    end
    table.insert(history.entries, text)
    history.idx = #history.entries + 1
  end

  local splitted_text = vim.split(text, ' ')
  local session = get_session()
  if vim.tbl_contains(M.commands.exit, text) then
    if session then
      -- Should result in a `terminated` event which closes the session and sets it to nil
      session:disconnect()
    end
    api.nvim_command('close')
    return
  end
  if vim.tbl_contains(M.commands.help, text) then
    print_commands()
    return
  elseif vim.tbl_contains(M.commands.clear, text) then
    if repl.buf and api.nvim_buf_is_loaded(repl.buf) then
      M.clear()
    end
    return
  end
  if not session then
    M.append('No active debug session')
    return
  end
  if vim.tbl_contains(M.commands.continue, text) then
    require('dap').continue()
  elseif vim.tbl_contains(M.commands.next_, text) then
    require('dap').step_over()
  elseif vim.tbl_contains(M.commands.capabilities, text) then
    M.append(vim.inspect(session.capabilities))
  elseif vim.tbl_contains(M.commands.into, text) then
    require('dap').step_into()
  elseif vim.tbl_contains(M.commands.into_targets, text) then
    require('dap').step_into({askForTargets=true})
  elseif vim.tbl_contains(M.commands.out, text) then
    require('dap').step_out()
  elseif vim.tbl_contains(M.commands.up, text) then
    session:_frame_delta(1)
    M.print_stackframes()
  elseif vim.tbl_contains(M.commands.step_back, text) then
    require('dap').step_back()
  elseif vim.tbl_contains(M.commands.pause, text) then
    session:_pause()
  elseif vim.tbl_contains(M.commands.reverse_continue, text) then
    require('dap').reverse_continue()
  elseif vim.tbl_contains(M.commands.down, text) then
    session:_frame_delta(-1)
    M.print_stackframes()
  elseif vim.tbl_contains(M.commands.goto_, splitted_text[1]) then
    if splitted_text[2] then
      session:_goto(tonumber(splitted_text[2]))
    end
  elseif vim.tbl_contains(M.commands.scopes, text) then
    print_scopes(session.current_frame)
  elseif vim.tbl_contains(M.commands.threads, text) then
    print_threads(vim.tbl_values(session.threads))
  elseif vim.tbl_contains(M.commands.frames, text) then
    M.print_stackframes()
  elseif M.commands.custom_commands[splitted_text[1]] then
    local command = splitted_text[1]
    local args = string.sub(text, string.len(command)+2)
    M.commands.custom_commands[command](args)
  else
    session:evaluate(text, evaluate_handler)
  end
end


--- Add and execute text as if entered directly
function M.execute(text)
  M.append("dap> " .. text .. "\n", "$", { newline = true })
  execute(text)
end


--- Close the REPL if it is open.
--
-- Does not disconnect an active session.
--
-- Returns true if the REPL was open and got closed. false otherwise
M.close = repl.close

--- Open the REPL
--
--@param winopts  optional table which may include:
--                  `height` to set the window height
--                  `width` to set the window width
--
--                  Any other key/value pair, that will be treated as window
--                  option.
--
--@param wincmd command that is used to create the window for the REPL.
--              Defaults to 'belowright split'
M.open = repl.open

--- Open the REPL if it is closed, close it if it is open.
M.toggle = repl.toggle


local function select_history(delta)
  if not repl.buf then
    return
  end
  history.idx = history.idx + delta
  if history.idx < 1 then
    history.idx = #history.entries
  elseif history.idx > #history.entries then
    history.idx = 1
  end
  local text = history.entries[history.idx]
  if text then
    local lnum = vim.fn.line('$')
    api.nvim_buf_set_lines(repl.buf, lnum - 1, lnum, true, {'dap> ' .. text })
    vim.fn.setcursorcharpos({ lnum, vim.fn.col('$') })  -- move cursor to the end of line
  end
end


function M.on_up()
  select_history(-1)
end

function M.on_down()
  select_history(1)
end


---@param line string
---@param lnum (integer|string)?
---@param opts? {newline: boolean}
function M.append(line, lnum, opts)
  opts = opts or {}
  local buf = repl._init_buf()
  if api.nvim_get_current_win() == repl.win and lnum == '$' then
    lnum = nil
  end
  if vim.bo[buf].fileformat ~= "dos" then
    line = line:gsub('\r\n', '\n')
  end
  local lines = vim.split(line, '\n')
  if lnum == '$' or not lnum then
    lnum = api.nvim_buf_line_count(buf) - 1
    if opts.newline == false then
      local last_line = api.nvim_buf_get_lines(buf, -2, -1, true)[1]
      local insert_pos = #last_line
      if last_line == 'dap> ' then
        -- insert right in front of the empty prompt
        insert_pos = 0
        if lines[#lines] ~= '' then
          table.insert(lines, #lines + 1, '')
        end
      elseif vim.startswith(last_line, 'dap> ') then
        table.insert(lines, 1, '')
      end
      api.nvim_buf_set_text(buf, lnum, insert_pos, lnum, insert_pos, lines)
    else
      api.nvim_buf_set_lines(buf, -1, -1, true, lines)
    end
  else
    api.nvim_buf_set_lines(buf, lnum, lnum, true, lines)
  end
  if autoscroll and repl.win and api.nvim_win_is_valid(repl.win) then
    pcall(api.nvim_win_set_cursor, repl.win, { lnum + 2, 0 })
  end
  return lnum
end


function M.clear()
  if repl.buf and api.nvim_buf_is_loaded(repl.buf) then
    local layer = ui.layer(repl.buf)
    layer.render({}, tostring, {}, 0, - 1)
  end
end

do
  local function completions_to_items(candidates)
    table.sort(candidates, function(a, b) return (a.sortText or a.label) < (b.sortText or b.label) end)
    local items = {}
    for _, candidate in pairs(candidates) do
      table.insert(items, {
        word = candidate.text or candidate.label;
        abbr = candidate.label;
        dup = 0;
        icase = 1;
      })
    end
    return items
  end

  ---@param items dap.CompletionItem[]
  ---@return boolean mixed, integer? start
  local function get_start(items)
    local start = nil
    local mixed = false
    for _, item in ipairs(items) do
      if item.start and (item.length or 0) > 0 then
        if start and start ~= item.start then
          mixed = true
          start = math.min(start, item.start)
        else
          start = item.start
        end
      end
    end
    return mixed, start
  end

  function M.omnifunc(findstart, base)
    local session = get_session()
    local col = api.nvim_win_get_cursor(0)[2]
    local line = api.nvim_get_current_line()
    local offset = vim.startswith(line, 'dap> ') and 5 or 0
    local line_to_cursor = line:sub(offset + 1, col)
    local text_match = vim.fn.match(line_to_cursor, '\\k*$')
    if vim.startswith(line_to_cursor, '.') or base ~= '' then
      if findstart == 1 then
        return offset
      end
      local completions = {}
      for key, values in pairs(M.commands) do
        if key ~= "custom_commands" then
          for _, val in pairs(values) do
            if vim.startswith(val, base) then
              table.insert(completions, val)
            end
          end
        end
      end
      for key, _ in pairs(M.commands.custom_commands or {}) do
        if vim.startswith(key, base) then
          table.insert(completions, key)
        end
      end

      return completions
    end
    local supportsCompletionsRequest = ((session or {}).capabilities or {}).supportsCompletionsRequest;
    if not supportsCompletionsRequest then
      if findstart == 1 then
        return -1
      else
        return {}
      end
    end
    assert(session, 'Session must exist if supportsCompletionsRequest is true')
    ---@type dap.CompletionsArguments
    local args = {
      frameId = (session.current_frame or {}).id,
      text = line_to_cursor,
      column = col + 1 - offset
    }
    session:request('completions', args, function(err, response)
      if err then
        require('dap.utils').notify('completions request failed: ' .. err.message, vim.log.levels.WARN)
        return
      end
      local items = response.targets --[[@as dap.CompletionItem[]|]]
      local mixed, start = get_start(items)
      if start and not mixed then
        vim.fn.complete(offset + start + 1, completions_to_items(items))
      else
        vim.fn.complete(offset + text_match + 1, completions_to_items(items))
      end
    end)

    -- cancel but stay in completion mode for completion via `completions` callback
    return -2
  end
end


return M
