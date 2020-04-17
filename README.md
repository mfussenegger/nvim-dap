# DAP (Debug Adapter Protocol)

`nvim-dap` is a Debug Adapter Protocol client implementation for [Neovim][1] (>= 0.5)

**Warning**: This is in an early stage and not really usable yet.


## Features

- [ ] launch debug adapter
- [x] attach to debug adapter
- [x] toggle breakpoints
- [ ] breakpoints with conditions
- [ ] set function breakpoints
- [ ] set exception breakpoints
- [x] step over, step into, step out
- [ ] step back, reverse continue
- [ ] Goto
- [x] restart
- [x] stop
- [x] evaluate expressions
- [x] REPL
- [x] threads, scopes and variables ui (bare minimum, in desperate need of improvements)


![screenshot](images/screenshot.png)


## Motivation

Why another DAP implementation for Neovim if there is already [Vimspector][2]?

This project makes some different choices:

- Uses the Lua API of Neovim, and therefore targets only Neovim instead of both Vim and Neovim.
- Tries to follow a similar design as the LSP implementation within Neovim. The idea is to have an extendable core.


## Out of scope

Debug adapter installations are out of scope of this project.

There may be a `nvim-dap-configs` project at some point, similar to [nvim-lsp][3].

## Installation

Don't, there is nothing usable here yet. Use [Vimspector][2] instead.


## Usage

Setup some mappings:

```
has('nvim-0.5')
    packadd nvim-dap
    nnoremap <silent> <F3> :lua require'dap'.stop()<CR>
    nnoremap <silent> <F4> :lua require'dap'.restart()<CR>
    nnoremap <silent> <F5> :lua require'dap'.continue()<CR>
    nnoremap <silent> <F10> :lua require'dap'.step_over()<CR>
    nnoremap <silent> <F11> :lua require'dap'.step_into()<CR>
    nnoremap <silent> <F12> :lua require'dap'.step_out()<CR>
    nnoremap <silent> <leader>b :lua require'dap'.toggle_breakpoint()<CR>
endif
```

Launch a debug adapter, for example [debugpy][4]:

```
python -m debugpy --listen localhost:5678 --wait-for-client ./foo.py
```


To attach to the debug adapter, within neovim:


```
:lua require'dap'.attach({port=5678})
```


[1]: https://neovim.io/
[2]: https://github.com/puremourning/vimspector
[3]: https://github.com/neovim/nvim-lsp
[4]: https://github.com/microsoft/debugpy
