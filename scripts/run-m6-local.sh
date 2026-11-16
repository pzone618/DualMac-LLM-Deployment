#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/common.sh"
model="$(model_path "$MODEL_REPO" "$MODEL_FILE")"
require_file "$model"
require_exec "$BIN/llama-server"
exec "$BIN/llama-server" -m "$model" -ngl 99 -c "$CTX_SIZE" \
  --host "$M6_IP" --port "$M6_LOCAL_PORT"
