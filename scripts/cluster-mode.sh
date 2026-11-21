#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/common.sh"
REMOTE="${M6_USER}@${M6_IP}"
if [ "$M6_USER" = CHANGE_ME ] || [ -z "$M6_USER" ]; then
  echo 'ERROR: edit M6_USER in config/cluster.env first.' >&2; exit 2
fi
ssh_m6() { ssh -o BatchMode=yes -o ConnectTimeout=6 "$REMOTE" "bash \"$M6_AI_ROOT/dual-mac-cluster/scripts/m6-service.sh\" $1"; }
stop_m4() {
  tmux kill-session -t ai-m4-local 2>/dev/null || true
  tmux kill-session -t ai-m4-distributed 2>/dev/null || true
}
start_m4() {
  local session="$1" script="$2" log="$3"
  tmux new-session -d -s "$session" "exec '$ROOT/scripts/$script' >> '$LOG_DIR/$log' 2>&1"
  echo "Started $session (log: $LOG_DIR/$log)"
}
check_same_commit() {
  local local_commit remote_commit
  local_commit="$(llama_commit)"
  remote_commit="$(ssh -o BatchMode=yes -o ConnectTimeout=6 "$REMOTE" "r=\"$M6_AI_ROOT/llama.cpp\"; if [ -f \"\$r/.commit\" ]; then cat \"\$r/.commit\"; else git -C \"\$r\" rev-parse HEAD; fi")"
  if [ "$local_commit" != "$remote_commit" ]; then
    echo "RPC build commits differ! M4=$local_commit M6=$remote_commit" >&2
    exit 3
  fi
}
case "${1:-}" in
  local)
    ssh_m6 status >/dev/null # fail early if SSH not available
    stop_m4
    ssh_m6 local
    start_m4 ai-m4-local run-m4-local.sh m4-local.log
    echo "Mode: independent. M4 localhost:$M4_LOCAL_PORT; M6 $M6_IP:$M6_LOCAL_PORT"
    ;;
  distributed)
    ssh_m6 status >/dev/null
    check_same_commit
    stop_m4
    ssh_m6 rpc
    # Worker may need a second to bind; check via nc if present.
    for i in 1 2 3 4 5 6 7 8 9 10; do
      if nc -G 2 -z "$M6_IP" "$RPC_PORT" >/dev/null 2>&1; then break; fi
      sleep 1
    done
    if ! nc -G 2 -z "$M6_IP" "$RPC_PORT" >/dev/null 2>&1; then
      echo "ERROR: RPC worker not reachable at $M6_IP:$RPC_PORT; see M6 logs" >&2
      exit 4
    fi
    start_m4 ai-m4-distributed run-m4-distributed.sh m4-distributed.log
    echo "Mode: distributed. API http://127.0.0.1:$DISTRIBUTED_PORT/v1"
    ;;
  stop) stop_m4; ssh_m6 stop ;;
  status)
    echo 'M4 sessions:'; tmux ls 2>/dev/null | grep 'ai-m4-' || true
    echo 'M6 sessions:'; ssh_m6 status
    echo 'M4 health:'
    curl --max-time 2 -sS "http://127.0.0.1:$M4_LOCAL_PORT/health" || true
    echo; echo 'Cluster health:'
    curl --max-time 2 -sS "http://127.0.0.1:$DISTRIBUTED_PORT/health" || true
    echo
    ;;
  *) echo 'Usage: cluster-mode.sh local|distributed|stop|status' >&2; exit 2 ;;
esac
