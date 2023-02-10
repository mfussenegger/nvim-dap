local _MODREV, _SPECREV = 'scm', '-1'
rockspec_format = "3.0"
package = 'nvim-dap'
version = _MODREV .. _SPECREV

description = {
  summary = 'Debug Adapter Protocol client implementation for Neovim.',
  detailed = [[
  nvim-dap allows you to:

  * Launch an application to debug
  * Attach to running applications and debug them
  * Set breakpoints and step through code
  * Inspect the state of the application
  ]],
  labels = {
    'neovim',
    'plugin',
    'debug-adapter-protocol',
    'debugger',
  },
  homepage = 'https://github.com/mfussenegger/nvim-dap',
  license = 'GPL-3.0',
}

dependencies = {
  'lua >= 5.1, < 5.4',
}

source = {
   url = 'git://github.com/mfussenegger/nvim-dap',
}

build = {
   type = 'builtin',
   copy_directories = {
     'doc',
     'plugin',
   },
}
