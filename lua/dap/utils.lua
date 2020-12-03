local M = {}


function M.calc_kv_table_from_values(key_from_value_fn, values)
  local rtn = {}
  for _, v in pairs(values) do
    rtn[key_from_value_fn(v)] = v
  end
  return rtn
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
