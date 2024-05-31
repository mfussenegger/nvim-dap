describe('progress', function()
  local progress = require('dap.progress')

  after_each(progress.reset)

  it('Polling on empty buffer returns nil, report and poll after', function()
    assert.are.same(nil, progress.poll_msg())
    assert.are.same(nil, progress.poll_msg())

    progress.report('hello')
    assert.are.same('hello', progress.poll_msg())
  end)

  it('Interleave report and poll', function()
    progress.report('one')
    progress.report('two')
    assert.are.same('one', progress.poll_msg())
    progress.report('three')
    assert.are.same('two', progress.poll_msg())
    assert.are.same('three', progress.poll_msg())
  end)
  it('Oldest messages are overridden once size limit is reached', function()
    for i = 1, 11 do
      progress.report(tostring(i))
    end
    assert.are.same('2', progress.poll_msg())
    assert.are.same('3', progress.poll_msg())
    progress.report('a')
    assert.are.same('4', progress.poll_msg())
  end)
end)
