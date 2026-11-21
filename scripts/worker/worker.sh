#!/bin/bash
# Worker (child) node, e.g. Mac mini M6. Run this on the worker only.
#   worker.sh setup     install deps and build llama.cpp (bootstrap)
#   worker.sh start     start ggml-rpc-server in tmux (session ai-worker-rpc)
#   worker.sh stop|status|logs
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/common/common.sh"
SESSION=ai-worker-rpc
LOGFILE="$LOG_DIR/worker-rpc.log"
running() { tmux has-session -t "=$SESSION" 2>/dev/null; }
case "${1:-}" in
  setup) exec "$ROOT/scripts/common/bootstrap.sh" ;;
  start)
    command -v tmux >/dev/null || { echo 'tmux missing: run worker.sh setup' >&2; exit 1; }
    require_exec "$BIN/ggml-rpc-server"
    if running; then echo "Already running: $SESSION"; exit 0; fi
    if ! ifconfig | awk -v ip="$M6_IP" '$1 == "inet" && $2 == ip { found=1 } END { exit !found }'; then
      echo "ERROR: M6_IP=$M6_IP is not an address of this Mac. Check config/cluster.env and the Thunderbolt Bridge." >&2; exit 2
    fi
    if nc -G 1 -z "$M6_IP" "$RPC_PORT" >/dev/null 2>&1; then
      echo "ERROR: port $RPC_PORT already in use" >&2; exit 4
    fi
    tmux new-session -d -s "$SESSION" "exec '$ROOT/scripts/worker/run-rpc.sh' >> '$LOGFILE' 2>&1"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      nc -G 1 -z "$M6_IP" "$RPC_PORT" >/dev/null 2>&1 && break; sleep 1
    done
    nc -G 2 -z "$M6_IP" "$RPC_PORT" >/dev/null 2>&1 \
      || { echo "ERROR: RPC worker not listening on $M6_IP:$RPC_PORT; see $LOGFILE" >&2; exit 4; }
    echo "Worker RPC listening on $M6_IP:$RPC_PORT"
    echo "llama.cpp commit: $(llama_commit)   (must equal the master's)"
    ;;
  stop)
    stop_session "$SESSION" "$M6_IP" "$RPC_PORT"
    echo 'Worker stopped (restart the master too: its RPC connection is gone)' ;;
  status)
    if running; then echo "Worker: running ($SESSION)"; else echo 'Worker: stopped'; fi
    nc -G 2 -z "$M6_IP" "$RPC_PORT" >/dev/null 2>&1 && echo "RPC port $M6_IP:$RPC_PORT: open" || echo "RPC port $M6_IP:$RPC_PORT: closed"
    echo "llama.cpp commit: $(llama_commit)"
    ;;
  logs) tail -n "${2:-50}" "$LOGFILE" ;;
  *) echo 'Usage: worker.sh setup|start|stop|status|logs' >&2; exit 2 ;;
esac
