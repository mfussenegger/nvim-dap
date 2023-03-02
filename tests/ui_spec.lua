local api = vim.api
local ui = require('dap.ui')

describe('ui', function()
  it('layered buf', function()

    -- note that test cases build on each other
    local render_item = function(x) return x.label end
    local buf = api.nvim_create_buf(true, true)
    local layer = ui.layer(buf)

    it('can append items to empty buffer', function()
      local items = {
        { label = "aa", x = 1 },
        { label = "", x = 3 },
        { label = "dd", x = 4 },
      }
      layer.render(items, render_item)
      local lines = api.nvim_buf_get_lines(buf, 0, -1, true)
      assert.are.same({
        'aa',
        '',
        'dd',
      }, lines)

      assert.are.same(3, vim.tbl_count(layer.__marks))
      for i = 1, #items do
        assert.are.same(items[i], layer.get(i - 1).item)
      end
    end)

    it('can append at arbitrary position', function()
      layer.render({{ label = "bb", x = 2 },}, render_item, nil, 1)
      local lines = api.nvim_buf_get_lines(buf, 0, -1, true)
      assert.are.same({
        'aa',
        'bb',
        '',
        'dd',
      }, lines)
      assert.are.same('aa', layer.get(0).item.label)
      assert.are.same('bb', layer.get(1).item.label)
      assert.are.same('', layer.get(2).item.label)
    end)

    it('can override a region', function()
      local items = {
        { label = "bbb", x = 22 },
        { label = "bbbb", x = 222 },
      }
      layer.render(items, render_item, nil, 1, 2)
      local lines = api.nvim_buf_get_lines(buf, 0, -1, true)
      assert.are.same({
        'aa',
        'bbb',
        'bbbb',
        '',
        'dd',
      }, lines)
      assert.are.same('aa', layer.get(0).item.label)
      assert.are.same('bbb', layer.get(1).item.label)
      assert.are.same('bbbb', layer.get(2).item.label)
      assert.are.same('', layer.get(3).item.label)
    end)

    it('can append at the end', function()
      layer.render({{ label = "e" }}, render_item, nil, nil, nil)
      local lines = api.nvim_buf_get_lines(buf, 0, -1, true)
      assert.are.same({
        'aa',
        'bbb',
        'bbbb',
        '',
        'dd',
        'e',
      }, lines)
      assert.are.same('dd', layer.get(4).item.label)
      assert.are.same('e', layer.get(5).item.label)
    end)
  end)

  local opts = {
    get_key = function(val) return val.name end,
    render_parent = function(val) return val.name end,
    has_children = function(val) return val.children end,
    get_children = function(val) return val.children end
  }

  it('tree can render a tree structure', function()
    local tree = ui.new_tree(opts)
    local buf = api.nvim_create_buf(true, true)
    local layer = ui.layer(buf)
    local d = { name = 'd' }
    local c = { name = 'c', children = { d, } }
    local b = { name = 'b', children = { c, } }
    local a = { name = 'a' }
    local root = {
      name = 'root',
      children = { a, b }
    }
    local root_copy = vim.deepcopy(root)
    tree.render(layer, root)
    local lines = api.nvim_buf_get_lines(buf, 0, -1, true)
    assert.are.same({
      'root',
      '  a',
      '  b',
    }, lines)

    it('can expand an element with children', function()
      local lnum = 2
      local info = layer.get(lnum)
      info.context.actions[1].fn(layer, info.item, lnum, info.context)
      lines = api.nvim_buf_get_lines(buf, 0, -1, true)
      assert.are.same({
        'root',
        '  a',
        '  b',
        '    c',
      }, lines)

      lnum = 3
      info = layer.get(lnum)
      info.context.actions[1].fn(layer, info.item, lnum, info.context)
      lines = api.nvim_buf_get_lines(buf, 0, -1, true)
      assert.are.same({
        'root',
        '  a',
        '  b',
        '    c',
        '      d',
      }, lines)
    end)

    it('can render with new data and previously expanded elements are still expanded', function()
      layer.render({}, tostring, nil, 0, -1)
      lines = api.nvim_buf_get_lines(buf, 0, -1, true)
      assert.are.same({''}, lines)
      tree.render(layer, root_copy)
      lines = api.nvim_buf_get_lines(buf, 0, -1, true)
      assert.are.same({
        'root',
        '  a',
        '  b',
        '    c',
        '      d',
      }, lines)
    end)

    it('can collapse an expanded item', function()
      local lnum = 2
      local info = layer.get(lnum)
      info.context.actions[1].fn(layer, info.item, lnum, info.context)
      lines = api.nvim_buf_get_lines(buf, 0, -1, true)
      assert.are.same({
        'root',
        '  a',
        '  b',
      }, lines)
    end)

    it('can re-use a subnode in a different tree', function()
      local lnum = 2
      local info = layer.get(lnum)
      info.context.actions[1].fn(layer, info.item, lnum, info.context)
      lines = api.nvim_buf_get_lines(buf, 0, -1, true)
      assert.are.same({
        'root',
        '  a',
        '  b',
        '    c',
      }, lines)
      layer.render({}, tostring, nil, 0, -1)
      local subtree = ui.new_tree(opts)
      subtree.render(layer, b)
      lines = api.nvim_buf_get_lines(buf, 0, -1, true)
      assert.are.same({
        'b',
        '  c',
      }, lines)
    end)
  end)
end)
