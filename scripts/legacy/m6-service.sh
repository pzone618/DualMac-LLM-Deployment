#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/common/common.sh"
command -v tmux >/dev/null || { echo 'Install tmux via bootstrap.sh' >&2; exit 1; }
stop_one() { tmux kill-session -t "$1" 2>/dev/null || true; }
start_one() {
  local name="$1" runner="$2" logfile="$3"
  if tmux has-session -t "$name" 2>/dev/null; then echo "Already running: $name"; return; fi
  tmux new-session -d -s "$name" "exec '$ROOT/scripts/legacy/$runner' >> '$LOG_DIR/$logfile' 2>&1"
  echo "Started: $name (log: $LOG_DIR/$logfile)"
}
case "${1:-}" in
  local) stop_one ai-m6-rpc; start_one ai-m6-local run-m6-local.sh m6-local.log ;;
  rpc)   stop_one ai-m6-local; start_one ai-m6-rpc ../worker/run-rpc.sh m6-rpc.log ;;
  stop)  stop_one ai-m6-rpc; stop_one ai-m6-local; echo 'M6 services stopped' ;;
  status) tmux ls 2>/dev/null | grep 'ai-m6-' || echo 'No M6 service session' ;;
  *) echo "Usage: $0 local|rpc|stop|status" >&2; exit 2 ;;
esac
