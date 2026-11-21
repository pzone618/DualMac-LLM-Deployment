#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/common.sh"
model="$(model_path "$DISTRIBUTED_MODEL_REPO" "$DISTRIBUTED_MODEL_FILE")"
require_file "$model"
require_exec "$BIN/llama-server"
export GGML_RPC_NO_RDMA=1
export GGML_RPC_DEBUG=1
exec "$BIN/llama-server" -m "$model" -ngl 99 -c "$CTX_SIZE" \
  --rpc "$M6_IP:$RPC_PORT" --host 127.0.0.1 --port "$DISTRIBUTED_PORT"
