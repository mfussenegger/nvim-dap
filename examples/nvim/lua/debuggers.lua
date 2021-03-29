local M = {}

M.docker_attach_python_example = function()
    local dap = require"dap"
    local host = "127.0.0.1"
    -- Same port as exposed in the Python example docker-compose.yml
    local port = 51469
    coroutine.create(function()
        vim.fn.system("docker exec test-python_example_python_1 ./start_debugger.sh")
    end)
    local config = {
        type = "python";
        request = "attach";
        connect = {
            host = host;
            port = port;
        };
        mode = "remote";
        name = "Remote Attached Debugger";
        cwd = vim.fn.getcwd();
        pathMappings = {
            {
                localRoot = vim.fn.getcwd();
                -- Same as WORKDIR in the Dockerfile.
                -- Or wherever your sourcecode lives in the container.
                remoteRoot = "/usr/src/app";
            };
        };
    }
    -- The adapter has been started.
    -- Connect to it.
    local session = dap.attach(host, port, config)
    if session == nil then
        io.write("Error connecting to adapter");
    end
    dap.repl.open({}, 'vsplit')
end

return M
