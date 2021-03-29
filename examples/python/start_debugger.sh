#! /bin/bash
# This file needs to be run inside the container you want to debug.
# Locate running pid.
pid=$(pgrep -nf example)
# Same port as exposed via docker compose.
# Using 0.0.0.0 is important instead of 127.0.0.1
python -m debugpy --listen "0.0.0.0:51469" --pid $pid
