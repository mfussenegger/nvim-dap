local utils = require('dap.utils')
local M = {}

---@param header string
---@return integer?
local function get_content_length(header)
  for line in header:gmatch("(.-)\r\n") do
    local key, value = line:match('^%s*(%S+)%s*:%s*(%d+)%s*$')
    if key and key:lower() == "content-length" then
      return tonumber(value)
    end
  end
end


local parse_chunk_loop
local has_strbuffer, strbuffer = pcall(require, "string.buffer")

if has_strbuffer then
  parse_chunk_loop = function()
    local buf = strbuffer.new()
    while true do
      local msg = buf:tostring()
      local header_end = msg:find('\r\n\r\n', 1, true)
      if header_end then
        local header = buf:get(header_end + 1)
        buf:skip(2) -- skip past header boundary
        local content_length = get_content_length(header)
        if not content_length then
          error("Content-Length not found in headers: " .. header)
        end
        while #buf < content_length do
          local chunk = coroutine.yield()
          buf:put(chunk)
        end
        local body = buf:get(content_length)
        coroutine.yield(body)
      else
        local chunk = coroutine.yield()
        buf:put(chunk)
      end
    end
  end
else
  parse_chunk_loop = function()
    local buffer = ''
    while true do
      local header_end, body_start = buffer:find('\r\n\r\n', 1, true)
      if header_end then
        local header = buffer:sub(1, header_end + 1)
        local content_length = get_content_length(header)
        if not content_length then
          error("Content-Length not found in headers: " .. header)
        end
        local body_chunks = {buffer:sub(body_start + 1)}
        local body_length = #body_chunks[1]
        while body_length < content_length do
          local chunk = coroutine.yield()
            or error("Expected more data for the body. The server may have died.")
          table.insert(body_chunks, chunk)
          body_length = body_length + #chunk
        end
        local last_chunk = body_chunks[#body_chunks]

        body_chunks[#body_chunks] = last_chunk:sub(1, content_length - body_length - 1)
        local rest = ''
        if body_length > content_length then
          rest = last_chunk:sub(content_length - body_length)
        end
        local body = table.concat(body_chunks)
        buffer = rest .. (coroutine.yield(body)
          or error("Expected more data for the body. The server may have died."))
      else
        buffer = buffer .. (coroutine.yield()
          or error("Expected more data for the header. The server may have died."))
      end
    end
  end
end


function M.create_read_loop(handle_body, on_no_chunk)
  local parse_chunk = coroutine.wrap(parse_chunk_loop)
  parse_chunk()
  return function (err, chunk)
    if err then
      utils.notify(err, vim.log.levels.ERROR)
      return
    end
    if not chunk then
      if on_no_chunk then
        on_no_chunk()
      end
      return
    end
    while true do
      local body = parse_chunk(chunk)
      if body then
        handle_body(body)
        chunk = ""
      else
        break
      end
    end
  end
end


function M.msg_with_content_length(msg)
  return table.concat {
    'Content-Length: ';
    tostring(#msg);
    '\r\n\r\n';
    msg
  }
end


return M
