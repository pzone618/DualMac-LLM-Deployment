#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
CONF="$ROOT/config/cluster.env"
if [ ! -f "$CONF" ]; then
  echo "ERROR: missing $CONF. Copy config/cluster.env.example and edit it." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONF"
# Overridable from config/cluster.env or the environment; default ~/AI.
AI_ROOT="${AI_ROOT:-$HOME/AI}"
# M6 paths are expanded by the remote shell, so $HOME stays literal here.
M6_AI_ROOT="${M6_AI_ROOT:-\$HOME/AI}"
M6_MODELS_DIR="${M6_MODELS_DIR:-$M6_AI_ROOT/models}"
MODELS_DIR="${MODELS_DIR:-$AI_ROOT/models}"
LLAMA_ROOT="$AI_ROOT/llama.cpp"
BIN="$LLAMA_ROOT/build/bin"
LOG_DIR="$AI_ROOT/logs"
stop_session() {
  local session="$1" host="$2" port="$3" attempt
  command -v tmux >/dev/null || { echo "ERROR: tmux missing" >&2; return 2; }
  if tmux has-session -t "=$session" 2>/dev/null; then
    tmux kill-session -t "=$session" || return 1
  fi
  for attempt in 1 2 3 4 5; do
    nc -G 1 -z "$host" "$port" >/dev/null 2>&1 || return 0
    sleep 1
  done
  if nc -G 1 -z "$host" "$port" >/dev/null 2>&1; then
    echo "ERROR: $host:$port is still in use. Inspect its owner with lsof -iTCP:$port." >&2
    return 5
  fi
}
if [[ "$LOG_DIR" == /Volumes/* ]]; then
  volume="${LOG_DIR#/Volumes/}"
  volume="/Volumes/${volume%%/*}"
  if ! stat -f '%d' "$volume" >/dev/null 2>&1 || [[ "$(stat -f '%d' "$volume")" == "$(stat -f '%d' /Volumes)" ]]; then
    echo "ERROR: volume for LOG_DIR is not mounted: $volume" >&2
    exit 1
  fi
fi
mkdir -p "$LOG_DIR"
model_path() {
  local repo="$1" file="$2"
  printf '%s/%s/%s\n' "$MODELS_DIR" "$repo" "$file"
}
require_file() {
  if [ ! -f "$1" ]; then
    echo "ERROR: File not found: $1" >&2
    echo "Run scripts/download-model.sh 'owner/repo' --file 'filename.gguf' on the relevant Mac." >&2
    exit 2
  fi
}
require_exec() {
  if [ ! -x "$1" ]; then echo "ERROR: missing executable $1. Run bootstrap.sh." >&2; exit 2; fi
}
# Commit of the llama.cpp source: the .commit file wins (zip unpack or pinned), else git HEAD.
llama_commit() {
  if [[ -f "$LLAMA_ROOT/.commit" ]]; then cat "$LLAMA_ROOT/.commit"; else git -C "$LLAMA_ROOT" rev-parse HEAD; fi
}
