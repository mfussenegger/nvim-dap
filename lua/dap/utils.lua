local M = {}


function M.calc_keys_from_values(fn, values)
  local rtn = {}
  for _, v in pairs(values) do
    rtn[fn(v)] = v
  end
  return rtn
end


-- Gets a property at path
-- @param tbl the table to access
-- @param path the '.' separated path
-- @returns the value at path or nil
function M.get_at_path(tbl, path)
  local segments = vim.split(path, '.', true)
  local result = tbl

  for _, segment in ipairs(segments) do
    if type(result) == 'table' then
      result = result[segment]
    end
  end

  return result
end


function M.non_empty_sequence(object)
  return object and #object > 0
end


function M.index_of(items, predicate)
  for i, item in ipairs(items) do
    if predicate(item) then
      return i
    end
  end
end


return M
