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
        { label = "cc", x = 3 },
        { label = "dd", x = 4 },
      }
      layer.render(items,render_item)
      local lines = api.nvim_buf_get_lines(buf, 0, -1, true)
      assert.are.same({
        'aa',
        'cc',
        'dd',
        ''
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
        'cc',
        'dd',
        ''
      }, lines)
      assert.are.same('aa', layer.get(0).item.label)
      assert.are.same('bb', layer.get(1).item.label)
      assert.are.same('cc', layer.get(2).item.label)
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
        'cc',
        'dd',
        ''
      }, lines)
      assert.are.same('aa', layer.get(0).item.label)
      assert.are.same('bbb', layer.get(1).item.label)
      assert.are.same('bbbb', layer.get(2).item.label)
      assert.are.same('cc', layer.get(3).item.label)
    end)
  end)
end)
