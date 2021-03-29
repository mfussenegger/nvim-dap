# Example Python

This directory holds examples of the required Docker files and scripts to connect
`nvim-dap` to a Python script running inside a container.

## Running

You can build the example container by running:

```sh
examples/python $ docker-compose build 
```

After building start the container by running:

```sh
examples/python $ docker-compose up -d
```

The first run of the container build may take a bit of time to succeed
because it downloads and builds [gdb](https://www.gnu.org/software/gdb/) 
from source.

Inside of `examples/nvim/lua/debuggers.lua` there is a code block for
`docker_attach_python_example`. It is referenced in `examples/nvim/init.vim`
and generates the command `:DebugExampleDockerPython`.
This command requires the example container to be up and running the test script.

Running `:DebugExampleDockerPython` will trigger execution of the
[start_debugger](./start_debugger.sh) script inside of the container, starting a
[debugpy](https://github.com/microsoft/debugpy) server that can communicate with `nvim-dap`.
