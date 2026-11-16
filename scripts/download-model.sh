#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/common.sh"
repo="${1:-${MODEL_REPO}}"
file="${2:-${MODEL_FILE}}"
# Guard names sent through SSH and paths from accidental traversal.
if ! [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || \
   ! [[ "$file" =~ ^[A-Za-z0-9_.-]+\.gguf$ ]]; then
  echo 'ERROR: expected: download-model.sh owner/repository filename.gguf' >&2
  echo 'For sharded GGUF, use hf download with --include and the official model instructions.' >&2
  exit 2
fi
HF="$AI_ROOT/.venv/bin/hf"
if [ ! -x "$HF" ]; then echo "Missing $HF; run bootstrap.sh first." >&2; exit 2; fi
dest="$AI_ROOT/models/${repo//\//__}"
mkdir -p "$dest"
"$HF" download "$repo" "$file" --local-dir "$dest"
echo "Downloaded: $dest/$file"
