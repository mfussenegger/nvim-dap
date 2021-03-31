# DAP (Debug Adapter Protocol)

`nvim-dap` is a Debug Adapter Protocol client implementation for [Neovim][1]
(>= 0.5). `nvim-dap` allows you to:

- Launch an application to debug
- Attach to running applications and debug them
- Set breakpoints and step through code
- Inspect the state of the application

**Warning**: This is in an early stage. It targets Neovim HEAD and therefore
things may break.

![screenshot](images/screenshot.png)

## Installation

- Requires [Neovim HEAD/nightly][6]
- nvim-dap is a plugin. Install it like any other Neovim plugin.
  - If using [vim-plug][11]: `Plug 'mfussenegger/nvim-dap'`
  - If using [packer.nvim][12]: `use 'mfussenegger/nvim-dap'`
- Generate the documentation for nvim-dap using `:helptags ALL` or
  `:helptags <PATH-TO-PLUGIN/doc/>`

You'll need to install and configure a debug adapter per language. See

- [:help dap.txt](doc/dap.txt)
- the [Debug-Adapter Installation][5] wiki
- `:help dap-adapter`
- `:help dap-configuration`

## Usage

A typical debug flow consists of:

- Setting breakpoints via `:lua require'dap'.toggle_breakpoint()`.
- Launching debug sessions and resuming execution via `:lua require'dap'.continue()`.
- Stepping through code via `:lua require'dap'.step_over()` and `:lua require'dap'.step_into()`.
- Inspecting the state via the built-in REPL: `:lua require'dap'.repl.open()`.

See [:help dap.txt](doc/dap.txt), `:help dap-mapping` and `:help dap-api`.

## Supported languages

In theory all of the languages for which a debug adapter exists should be
supported.

- [Available debug adapters][13]
- [nvim-dap Debug-Adapter Installation & Configuration][5]

The Wiki is community maintained. If you got an adapter working that isn't
listed yet, please extend the Wiki. If you struggle getting an adapter working,
please create an issue.


## Goals

- Have a basic debugger in Neovim.
- Extensibility and double as a DAP client library. This allows other plugins
  to extend the debugging experience. Either by improving the UI or by making
  it easier to debug parts of an application.

  - An example UI/UX extension is [nvim-dap-virtual-text][7]
  - Examples for language specific extensions include [nvim-jdtls][8] and [nvim-dap-python][9]

## Extensions

All known extensions are listed in the [Wiki][10]. The wiki is community
maintained. Please add new extensions if you built one or if you discovered one
that's not listed.

## Non-Goals

- Debug adapter installations are out of scope. It's not the business of an
  editor plugin to re-invent a package manager. Use your system package
  manager. Use Nix. Use Ansible.

- Vim support. It's not going to happen. Use [vimspector][2] instead.

## Alternatives

- [vimspector][2]


## Features

- [x] launch debug adapter
- [x] attach to debug adapter
- [x] toggle breakpoints
- [x] breakpoints with conditions
- [x] logpoints
- [x] set exception breakpoints
- [x] set data breakpoints
- [x] step over, step into, step out
- [x] step back, reverse continue
- [x] Goto
- [x] restart
- [x] stop
- [x] pause
- [x] evaluate expressions
- [x] REPL (incl. commands to show threads, frames and scopes)


[1]: https://neovim.io/
[2]: https://github.com/puremourning/vimspector
[3]: https://github.com/neovim/nvim-lsp
[4]: https://github.com/microsoft/debugpy
[5]: https://github.com/mfussenegger/nvim-dap/wiki/Debug-Adapter-installation
[6]: https://github.com/neovim/neovim/releases/tag/nightly
[7]: https://github.com/theHamsta/nvim-dap-virtual-text
[8]: https://github.com/mfussenegger/nvim-jdtls
[9]: https://github.com/mfussenegger/nvim-dap-python
[10]: https://github.com/mfussenegger/nvim-dap/wiki/Extensions
[11]: https://github.com/junegunn/vim-plug
[12]: https://github.com/wbthomason/packer.nvim
[13]: https://microsoft.github.io/debug-adapter-protocol/implementors/adapters/
