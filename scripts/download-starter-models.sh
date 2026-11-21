#!/bin/bash
# Re-run this command to resume. Revisions are persisted before downloading.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="$ROOT/.venv-download/bin/python"
STATE="$ROOT/.download-state"
SOURCE="${DOWNLOAD_SOURCE:-mirror}"
case "$SOURCE" in
  official|mirror|auto) ;;
  *) echo 'DOWNLOAD_SOURCE must be official, mirror or auto' >&2; exit 2 ;;
esac
mkdir -p "$STATE"
download() {
  local repo="$1" file="$2" revision state_file
  state_file="$STATE/${repo//\//__}.revision"
  if [[ ! -s "$state_file" ]]; then
    revision="$("$PYTHON" "$ROOT/scripts/hf_download.py" resolve "$repo" --source "$SOURCE" | tail -n 1)"
    [[ "$revision" =~ ^[a-f0-9]{40}$ ]] || { echo 'Invalid revision' >&2; exit 1; }
    printf '%s\n' "$revision" > "$state_file"
  fi
  revision="$(cat "$state_file")"
  bash "$ROOT/scripts/download-model.sh" "$repo" --file "$file" \
    --source "$SOURCE" --engine aria2 --revision "$revision"
}
download Qwen/Qwen3-Embedding-0.6B-GGUF Qwen3-Embedding-0.6B-Q8_0.gguf
download bartowski/Qwen_Qwen3.5-9B-GGUF Qwen_Qwen3.5-9B-Q4_K_M.gguf
download bartowski/Qwen_Qwen3.5-9B-GGUF mmproj-Qwen_Qwen3.5-9B-f16.gguf
download unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf
download ggml-org/Flint-GGUF Flint-Q4_K_M.gguf
