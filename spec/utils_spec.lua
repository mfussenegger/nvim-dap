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

describe('utils.splitstr', function ()
  if vim.fn.has("nvim-0.10") == 0 then
    return
  end
  it('works with plain string', function ()
    assert.are.same({"hello", "world"}, utils.splitstr("hello world"))
  end)

  it('works extra whitespace', function ()
    assert.are.same({"hello", "world"}, utils.splitstr('hello  	world'))
  end)

  it('empty quoted', function ()
    assert.are.same({"hello", "", "world"}, utils.splitstr('hello "" world'))
  end)

  it('with double quoted string', function ()
    assert.are.same({'with', 'double quoted', 'string'}, utils.splitstr('with "double quoted" string'))
  end)

  it("with single quoted string", function ()
    assert.are.same({'with', 'single quoted', 'string'}, utils.splitstr("with 'single quoted' string"))
  end)

  it("with unbalanced quote", function ()
    assert.are.same({"with", "\"single", "quoted", "string"}, utils.splitstr("with \"single quoted string"))
  end)

  it("with unbalanced single quoted string", function ()
    assert.are.same({"with", "'single", "quoted", "string"}, utils.splitstr("with 'single quoted string"))
  end)

  it('escaped quote', function ()
    assert.are.same({'foo', '"bar'}, utils.splitstr('foo \"bar'))
  end)

  it("returns empty list for empty strings", function ()
    assert.are.same({}, utils.splitstr(""))
    assert.are.same({}, utils.splitstr("  "))
  end)
  it("trims leading and trailing whitespace", function ()
    assert.are.same({"a"}, utils.splitstr("a   "))
    assert.are.same({"a", "b"}, utils.splitstr("     a       b   "))
  end)
end)

describe("trim_procname", function()
  it("trims long full paths to name", function()
    local name = utils._trim_procname("/usr/bin/foobar", 10, 4)
    assert.are.same("foobar", name)
  end)

  it("drops arguments if there are too many", function()
    local name = utils._trim_procname("cmd --one --two --three", 15, 5)
    assert.are.same("cmd --one --two [‥]", name)
  end)

  it("trims long arguments", function()
    local name = utils._trim_procname("foobar --too-long-sorry", 20, 8)
    assert.are.same("foobar ‥ong-sorry", name)
  end)
end)
