# DAP (Debug Adapter Protocol)

`nvim-dap` is a Debug Adapter Protocol client implementation for [Neovim][1] (>= 0.5)

**Warning**: This is in an early stage and not really usable yet.


## Features

- [x] launch debug adapter
- [x] attach to debug adapter
- [x] toggle breakpoints
- [x] breakpoints with conditions
- [x] logpoints
- [ ] set function breakpoints
- [ ] set exception breakpoints
- [x] step over, step into, step out
- [ ] step back, reverse continue
- [x] Goto
- [x] restart
- [x] stop
- [x] evaluate expressions
- [x] REPL
- [x] threads, scopes and variables ui (via REPL commands)


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

- Requires [Neovim HEAD/nightly][6]
- nvim-dap is a plugin. Install it like any other Vim plugin.
- Call `:packadd nvim-dap` if you install `nvim-dap` to `'packpath'`.


## Usage

See [:help dap](doc/dap.txt) and the [Debug-Adapter Installation][5] wiki.
Keep in mind that the APIs are subject to change.



[1]: https://neovim.io/
[2]: https://github.com/puremourning/vimspector
[3]: https://github.com/neovim/nvim-lsp
[4]: https://github.com/microsoft/debugpy
[5]: https://github.com/mfussenegger/nvim-dap/wiki/Debug-Adapter-installation
[6]: https://github.com/neovim/neovim/releases/tag/nightly
