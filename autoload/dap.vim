
function! dap#repl_execute(text)
  call luaeval('require("dap.repl").execute(_A)', a:text)
endfunction
