#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
command -v aria2c >/dev/null || brew install aria2
# Use a version with prebuilt dependency wheels, rather than the newest python3.
DOWNLOAD_BOOTSTRAP_PYTHON="${DOWNLOAD_BOOTSTRAP_PYTHON:-python3.14}"
command -v "$DOWNLOAD_BOOTSTRAP_PYTHON" >/dev/null || brew install python@3.14
if [[ -x "$ROOT/.venv-download/bin/python" ]] && ! "$ROOT/.venv-download/bin/python" -c 'import sys; sys.exit(sys.version_info[:2] != (3,14))'; then
  backup="$ROOT/.venv-download.backup.$(date +%Y%m%d%H%M%S)"
  mv "$ROOT/.venv-download" "$backup"
  echo "Previous environment preserved: $backup"
fi
[[ -x "$ROOT/.venv-download/bin/python" ]] || "$DOWNLOAD_BOOTSTRAP_PYTHON" -m venv "$ROOT/.venv-download"
"$ROOT/.venv-download/bin/python" -m pip install --only-binary=:all: \
  --timeout 60 --retries 3 'huggingface_hub>=0.34,<2'
"$ROOT/.venv-download/bin/python" -c 'import huggingface_hub; print("huggingface_hub", huggingface_hub.__version__)'
aria2c --version
echo 'Download environment ready. No model downloaded.'
