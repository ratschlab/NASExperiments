#!/bin/bash
#
# Shared helpers for run_gridion.sh, check_tools.sh, the site files and the
# setup reports. The metagraph helpers need MG_SERVER_PORT, MG_GRAPH, MG_ANNO
# and THREADS from the site file when called.
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

# mg_ready
# Returns 0 if a metagraph server answers on MG_SERVER_PORT.
mg_ready() {
    python -I -c "
import sys
from metagraph.client import GraphClient
try:
    sys.exit(0 if GraphClient('localhost', port=$MG_SERVER_PORT, api_path='').ready() else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null
}

# mg_server_start <log_file>
# Starts `metagraph server_query` on MG_GRAPH/MG_ANNO unless a server already
# answers on MG_SERVER_PORT, and waits until it is ready. Sets MG_PID to the
# started server's pid (empty if an existing server is reused).
MG_PID=""
mg_server_start() {
    local log_file="$1"
    if mg_ready; then
        echo "Using metagraph server already listening on port $MG_SERVER_PORT."
        return 0
    fi
    echo "Starting metagraph server on port $MG_SERVER_PORT ($MG_GRAPH, $MG_ANNO)"
    metagraph server_query -i "$MG_GRAPH" -a "$MG_ANNO" \
        --port "$MG_SERVER_PORT" --address 127.0.0.1 -p "$THREADS" \
        > "$log_file" 2>&1 &
    MG_PID=$!
    until mg_ready; do
        if ! kill -0 "$MG_PID" 2>/dev/null; then
            echo "Error: metagraph server exited, see $log_file" >&2
            MG_PID=""
            return 1
        fi
        sleep 2
    done
    echo "metagraph server ready."
}

# mg_server_stop
# Stops the server started by mg_server_start, if any.
mg_server_stop() {
    if [ -n "$MG_PID" ]; then
        echo "Stopping metagraph server (pid $MG_PID)"
        kill "$MG_PID" 2>/dev/null || true
        MG_PID=""
    fi
}
