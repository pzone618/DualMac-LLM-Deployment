#!/bin/bash
# Both nodes: verified, resumable GGUF download from official HF or hf-mirror.com.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
# Download-only use does not require cluster configuration or llama.cpp.
if [[ -f "$ROOT/config/cluster.env" ]]; then source "$ROOT/config/cluster.env"; fi
AI_ROOT="${AI_ROOT:-$HOME/AI}"
MODELS_DIR="${MODELS_DIR:-$AI_ROOT/models}"
PYTHON="${DOWNLOAD_PYTHON:-$ROOT/.venv-download/bin/python}"
if [[ ! -x "$PYTHON" && -x "$AI_ROOT/.venv/bin/python" ]]; then
  PYTHON="$AI_ROOT/.venv/bin/python"
fi
if [[ ! -x "$PYTHON" ]]; then
  echo 'Run: bash scripts/setup-download.sh' >&2
  exit 2
fi
if [[ "${1:-}" == verify ]]; then
  shift
  exec "$PYTHON" "$ROOT/scripts/hf_download.py" verify "$@" --root "$MODELS_DIR"
fi
args=("$@")
source_set=0
for ((i=0; i<${#args[@]}; i++)); do
  if [[ "${args[i]}" == --source || "${args[i]}" == --source=* ]]; then source_set=1; break; fi
done
if [[ $source_set -eq 0 ]]; then args+=(--source "${HF_SOURCE:-mirror}"); fi
exec "$PYTHON" "$ROOT/scripts/hf_download.py" download "${args[@]}" --root "$MODELS_DIR"
