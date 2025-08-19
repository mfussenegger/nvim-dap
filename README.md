# DAP (Debug Adapter Protocol)

`nvim-dap` is a Debug Adapter Protocol client implementation for [Neovim][1].
`nvim-dap` allows you to:

- Launch an application to debug
- Attach to running applications and debug them
- Set breakpoints and step through code
- Inspect the state of the application

![demo][demo]

## Installation

[![LuaRocks](https://img.shields.io/luarocks/v/mfussenegger/nvim-dap?logo=lua&color=purple)](https://luarocks.org/modules/mfussenegger/nvim-dap)

- Install nvim-dap like any other Neovim plugin:
  - `git clone https://codeberg.org/mfussenegger/nvim-dap.git ~/.config/nvim/pack/plugins/start/nvim-dap`
  - Or with [vim-plug][11]: `Plug 'mfussenegger/nvim-dap'`
  - Or with [packer.nvim][12]: `use 'mfussenegger/nvim-dap'`
- Generate the documentation for nvim-dap using `:helptags ALL` or
  `:helptags <PATH-TO-PLUGIN/doc/>`

Supported Neovim versions:

- Latest nightly
- 0.11.x (Recommended)
- 0.10.4

You'll need to install and configure a debug adapter per language. See

- [:help dap.txt](doc/dap.txt)
- the [Debug-Adapter Installation][5] wiki
- `:help dap-adapter`
- `:help dap-configuration`

## Usage

A typical debug flow consists of:

- Setting breakpoints via `:DapToggleBreakpoint` or `:lua
  require'dap'.toggle_breakpoint()`.
- Launching debug sessions and resuming execution via `:DapNew` and
  `:DapContinue` or `:lua require'dap'.continue()`.
- Stepping through code via `:DapStepOver`, `:DapStepInto` or the corresponding
  functions `:lua require'dap'.step_over()` and `:lua
  require'dap'.step_into()`.
- Inspecting the state:
  - Via the built-in REPL: `:lua require'dap'.repl.open()`
    - Try typing an expression followed by ENTER to evaluate it.
    - Try commands like `.help`, `.frames`, `.threads`.
    - Variables with structure can be expanded and collapsed with ENTER on the
      corresponding line.
  - Via the widget UI (`:help dap-widgets`). Typically you'd inspect values,
    threads, stacktrace ad-hoc when needed instead of showing the information
    all the time, but you can also create sidebars for a permanent display
  - Via UI extensions:
    - IDE like: [nvim-dap-ui][15]
    - Middle ground between the IDE like nvim-dap-ui and the built-in widgets: [nvim-dap-view][nvim-dap-view]
    - Show inline values: [nvim-dap-virtual-text][7]

See [:help dap.txt](doc/dap.txt), `:help dap-mapping` and `:help dap-api`.

**Tip:**

The arrow keys are good candidates for keymaps to step through code as their
direction resembles the direction you'll step to.

- Down: Step over
- Right: Step into
- Left: Step out
- Up: Restart frame

You can setup keymaps temporary during a debug session using event listeners.
See `:help dap-listeners`.

## Supported languages

In theory all of the languages for which a debug adapter exists should be
supported.

- [Available debug adapters][13]
- [nvim-dap Debug-Adapter Installation & Configuration][5]

The Wiki is community maintained. If you got an adapter working that isn't
listed yet, please extend the Wiki.

Some debug adapters have [language specific
extensions](https://codeberg.org/mfussenegger/nvim-dap/wiki/Extensions#language-specific-extensions).
Using them over a manual configuration is recommended, as they're
usually better maintained.

If the instructions in the wiki for a debug adapter are not working, consider
that debug adapters may have made changes since the instructions were written.
You may want to read the release notes of the debug adapters or try with an
older version. Please update the wiki if you discover outdated examples.

## Goals

- Have a basic debugger in Neovim.
- Extensibility and double as a DAP client library. This allows other plugins
  to extend the debugging experience. Either by improving the UI or by making
  it easier to debug parts of an application.

  All known extensions are listed in the [Wiki][10]. The wiki is community
  maintained. Please add new extensions if you built one or if you discovered
  one that's not listed.

## Non-Goals

- Debug adapter installations are out of scope. It's not the business of an
  editor plugin to re-invent a package manager. Use your system package
  manager. Use Nix. Use Ansible.

- [nvim-dapconfig](https://github.com/nvim-lua/wishlist/issues/37#issuecomment-1023363686)

- Vim support. It's not going to happen. Use [vimspector][2] instead.

## Alternatives

- [vimspector][2]


## Contributing

Contributions are welcome:

- Give concrete feedback about usability.
- Triage issues. Many of the problems people encounter are debug
  adapter specific.
- Improve upstream debug adapter documentation to make them more editor
  agnostic.
- Improve the Wiki. But please refrain from turning it into comprehensive debug
  adapter documentation that should go upstream.
- Write extensions.

Before making direct code contributions, please create a discussion or issue to
clarify whether the change is in scope of the nvim-dap core.

Please keep pull requests focused and don't change multiple things at the same
time.

## Features

- [x] launch debug adapter
- [x] attach to debug adapter
- [x] toggle breakpoints
- [x] breakpoints with conditions
- [x] logpoints
- [x] set exception breakpoints
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
[5]: https://codeberg.org/mfussenegger/nvim-dap/wiki/Debug-Adapter-installation
[7]: https://github.com/theHamsta/nvim-dap-virtual-text
[10]: https://codeberg.org/mfussenegger/nvim-dap/wiki/Extensions
[11]: https://github.com/junegunn/vim-plug
[12]: https://github.com/wbthomason/packer.nvim
[13]: https://microsoft.github.io/debug-adapter-protocol/implementors/adapters/
[15]: https://github.com/rcarriga/nvim-dap-ui
[demo]: https://user-images.githubusercontent.com/38700/124292938-669a7100-db56-11eb-93b8-77b66994fc8a.gif
[nvim-dap-view]: https://github.com/igorlfs/nvim-dap-view
