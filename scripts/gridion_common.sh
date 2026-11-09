#!/bin/bash
#
# Shared helpers for run_gridion.sh, check_tools.sh, the site files and the
# setup reports.
#

# dorado_address
# Prints the address of the running MinKNOW-managed dorado basecall server,
# taken from its --port argument (the socket path differs between standalone
# MinKNOW and the GridION). Prints nothing if no server is running.
dorado_address() {
    local port
    port=$(pgrep -a -f dorado_basecall_server 2>/dev/null | grep -o -- '--port [^ ]*' | head -1 | cut -d' ' -f2)
    case "$port" in
        "") ;;
        /*) echo "ipc://$port" ;;
        [0-9]*) echo "127.0.0.1:$port" ;;
        *) echo "$port" ;;
    esac
}
