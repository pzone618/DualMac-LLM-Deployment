#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
CONF="$ROOT/config/cluster.env"
if [ ! -f "$CONF" ]; then
  echo "ERROR: missing $CONF. Copy config/cluster.env.example and edit it." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONF"
AI_ROOT="$HOME/AI"
LLAMA_ROOT="$AI_ROOT/llama.cpp"
BIN="$LLAMA_ROOT/build/bin"
LOG_DIR="$AI_ROOT/logs"
mkdir -p "$AI_ROOT/models" "$LOG_DIR"
model_path() {
  local repo="$1" file="$2"
  printf '%s/models/%s/%s\n' "$AI_ROOT" "${repo//\//__}" "$file"
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
