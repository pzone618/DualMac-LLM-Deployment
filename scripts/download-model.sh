#!/bin/bash
# Both nodes: verified, resumable GGUF download from official HF or hf-mirror.com.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/common.sh"
PYTHON="$AI_ROOT/.venv/bin/python"
require_exec "$PYTHON"
if [[ "${1:-}" == verify ]]; then
  shift
  exec "$PYTHON" "$ROOT/scripts/hf_download.py" verify "$@" --root "$AI_ROOT/models"
fi
args=("$@")
source_set=0
for ((i=0; i<${#args[@]}; i++)); do
  if [[ "${args[i]}" == --source ]]; then source_set=1; break; fi
done
if [[ $source_set -eq 0 ]]; then args+=(--source "${HF_SOURCE:-auto}"); fi
exec "$PYTHON" "$ROOT/scripts/hf_download.py" download "${args[@]}" --root "$AI_ROOT/models"
