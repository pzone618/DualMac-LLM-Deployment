#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/common.sh"
require_exec "$BIN/ggml-rpc-server"
# TB4/TB5 mixed pairing: intentionally TCP only; see Apple TN3205.
export GGML_RPC_NO_RDMA=1
exec "$BIN/ggml-rpc-server" -H "$M6_IP" -p "$RPC_PORT" -c
