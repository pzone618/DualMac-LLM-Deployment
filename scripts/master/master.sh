#!/bin/bash
# Master node, e.g. Mac mini M4 Pro. Run this on the master only; the worker must
# already be started with worker.sh. No SSH between the Macs is required.
#   master.sh setup     install deps and build llama.cpp (bootstrap)
#   master.sh start     check worker port, then start llama-server in tmux
#   master.sh stop|status|logs
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/common/common.sh"
SESSION=ai-master
LOGFILE="$LOG_DIR/master.log"
running() { tmux has-session -t "$SESSION" 2>/dev/null; }
case "${1:-}" in
  setup) exec "$ROOT/scripts/common/bootstrap.sh" ;;
  start)
    command -v tmux >/dev/null || { echo 'tmux missing: run master.sh setup' >&2; exit 1; }
    require_exec "$BIN/llama-server"
    require_file "$(model_path "$DISTRIBUTED_MODEL_REPO" "$DISTRIBUTED_MODEL_FILE")"
    if running; then echo "Already running: $SESSION"; exit 0; fi
    if ! nc -G 3 -z "$M6_IP" "$RPC_PORT" >/dev/null 2>&1; then
      echo "ERROR: worker RPC not reachable at $M6_IP:$RPC_PORT. Run 'scripts/worker/worker.sh start' on the worker first." >&2; exit 4
    fi
    tmux new-session -d -s "$SESSION" "exec '$ROOT/scripts/master/run-distributed.sh' >> '$LOGFILE' 2>&1"
    echo "Started $SESSION (log: $LOGFILE). Loading the model can take minutes."
    echo "llama.cpp commit: $(llama_commit)   (must equal the worker's)"
    echo "API: http://127.0.0.1:$DISTRIBUTED_PORT/v1   health: /health"
    ;;
  stop) tmux kill-session -t "$SESSION" 2>/dev/null || true; echo 'Master stopped' ;;
  status)
    if running; then echo "Master: running ($SESSION)"; else echo 'Master: stopped'; fi
    nc -G 2 -z "$M6_IP" "$RPC_PORT" >/dev/null 2>&1 && echo "Worker RPC $M6_IP:$RPC_PORT: reachable" || echo "Worker RPC $M6_IP:$RPC_PORT: NOT reachable"
    echo -n 'Health: '; curl --max-time 2 -sS "http://127.0.0.1:$DISTRIBUTED_PORT/health" || echo 'down'
    echo; echo "llama.cpp commit: $(llama_commit)"
    ;;
  logs) tail -n "${2:-50}" "$LOGFILE" ;;
  *) echo 'Usage: master.sh setup|start|stop|status|logs' >&2; exit 2 ;;
esac
