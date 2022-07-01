#!/bin/bash

set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && /bin/pwd )"

docker build -t nvim-dap-tests $DIR/..

FILE=$1
# test whole package
if [[ -z "$FILE" ]]; then
  docker run -t nvim-dap-tests --headless --noplugin -u tests/minimal.vim -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal.vim'}"
else 
  docker run -t nvim-dap-tests --headless --noplugin -u tests/minimal.vim -c "PlenaryBustedFile $FILE"
fi

