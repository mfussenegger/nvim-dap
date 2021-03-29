" Vim Plug Package Management
set nocompatible
filetype off
call plug#begin('~/.local/share/nvim/plugged')
Plug 'neovim/neovim'

Plug 'mfussenegger/nvim-dap'

nnoremap <silent> <leader>c :lua require'dap'.continue()<CR>
nnoremap <silent> <leader>n :lua require'dap'.step_over()<CR>
nnoremap <silent> <leader>b :lua require'dap'.toggle_breakpoint()<CR>
nnoremap <silent> <leader>dr :lua require'dap'.repl.open()<CR>
nnoremap <silent> <leader>si :lua require'dap'.step_into()<CR>
nnoremap <silent> <leader>so :lua require'dap'.step_out()<CR>

command! -complete=file -nargs=* DebugExampleDockerPython lua require"debuggers".docker_attach_python_example()
