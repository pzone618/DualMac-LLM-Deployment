#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ ! -f "$ROOT/config/cluster.env" ]; then
  echo "ERROR: first copy config/cluster.env.example to config/cluster.env" >&2
  exit 1
fi
# shellcheck source=scripts/common.sh
source "$ROOT/scripts/common.sh"
if [ "$(uname -m)" != "arm64" ]; then echo "ERROR: Apple Silicon arm64 required" >&2; exit 1; fi
if ! command -v brew >/dev/null 2>&1; then
  echo 'Install Homebrew manually first: https://brew.sh/ then reopen Terminal.' >&2
  exit 1
fi
brew install cmake git tmux python
mkdir -p "$AI_ROOT/models" "$AI_ROOT/logs"
if [ ! -d "$LLAMA_ROOT/.git" ]; then
  git clone https://github.com/ggml-org/llama.cpp.git "$LLAMA_ROOT"
fi
# Caller controls the ref; git checkout may detach HEAD intentionally.
git -C "$LLAMA_ROOT" fetch origin --tags
git -C "$LLAMA_ROOT" checkout "$LLAMA_CPP_REF"
if [ "$LLAMA_CPP_REF" = master ]; then git -C "$LLAMA_ROOT" pull --ff-only origin master; fi
cmake -S "$LLAMA_ROOT" -B "$LLAMA_ROOT/build" \
  -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=ON -DGGML_RPC=ON
cmake --build "$LLAMA_ROOT/build" --config Release -j 8
python3 -m venv "$AI_ROOT/.venv"
"$AI_ROOT/.venv/bin/python" -m pip install --upgrade pip huggingface_hub
printf '\nBuilt commit: '
git -C "$LLAMA_ROOT" rev-parse HEAD
printf 'Binaries:\n'
ls -lh "$BIN/llama-server" "$BIN/ggml-rpc-server"
