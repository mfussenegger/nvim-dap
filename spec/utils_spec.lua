local utils = require('dap.utils')

describe('utils.index_of', function()
  it('returns index of first item where predicate matches', function()
    local result = require('dap.utils').index_of(
      {'a', 'b', 'c'},
      function(x) return x == 'b' end
    )
    assert.are.same(2, result)
  end)
end)

describe('utils.to_dict', function()
  it('converts a list to a dictionary', function()
    local values = { { k='a', val=1 }, { k='b', val = 2 } }
    local result = require('dap.utils').to_dict(
      values,
      function(x) return x.k end,
      function(x) return x.val end
    )
    local expected = {
      a = 1,
      b = 2
    }
    assert.are.same(expected, result)
  end)

  it('supports nil values as argument', function()
    local result = require('dap.utils').to_dict(nil, function(x) return x end)
    assert.are.same(result, {})
  end)
end)


describe('utils.non_empty', function()
  it('non_empty returns true on non-empty dicts with numeric keys', function()
    local d = {
      [20] = 'a',
      [30] = 'b',
    }
    local result = require('dap.utils').non_empty(d)
    assert.are.same(true, result)
  end)
end)

describe('utils.fmt_error', function ()
  it('interpolates message objects with variables', function ()
    assert.are.equal('Hello, John!', require('dap.utils').fmt_error({
      body = {
        error = {
          showUser = true,
          format = '{greeting}, {name}!',
          variables = {
            greeting = 'Hello',
            name = 'John',
          }
        }
      }
    }))
  end)

  it('interpolates message objects without variables', function ()
    assert.are.equal('Hello, John!', require('dap.utils').fmt_error({
      body = {
        error = {
          showUser = true,
          format = 'Hello, John!',
        }
      }
    }))
  end)

  it('return message if showUser is false', function ()
    assert.are.equal('Something went wrong.', require('dap.utils').fmt_error({
      message = 'Something went wrong.',
      body = {
        error = {
          showUser = false,
          format = 'Hello, John!',
        }
      }
    }))
  end)

  it('can handle response without body part', function()
    local result = utils.fmt_error({
      message = 'Bad things happen',
    })
    assert.are.same('Bad things happen', result)
  end)
end)

describe('utils.split_args', function ()
  it('works with standard string', function ()
    assert.are.same({'this', 'is', 'a', 'standard', 'string'}, require('dap.utils').split_args('this is a standard string'))
  end)

  it('with "double quoted" string', function ()
    assert.are.same({'with', 'double quoted', 'string'}, require('dap.utils').split_args('with "double quoted" string'))
  end)

  it("with 'single quoted' string", function ()
    assert.are.same({'with', 'single quoted', 'string'}, require('dap.utils').split_args("with 'single quoted' string"))
  end)

  it('"double \"escaped\" quoted" string', function ()
    assert.are.same({'double "escaped" quoted', 'string'}, require('dap.utils').split_args('"double \"escaped\" quoted" string'))
  end)
end)
