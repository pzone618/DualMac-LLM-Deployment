#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/common/common.sh"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'ERROR: macOS Apple Silicon arm64 required' >&2; exit 1; }
command -v brew >/dev/null 2>&1 || { echo 'Install Homebrew first: https://brew.sh/ (and reopen Terminal)' >&2; exit 1; }
brew install cmake git tmux python aria2 rsync
mkdir -p "$AI_ROOT"
if [[ -f "$LLAMA_ROOT/.commit" && ! -d "$LLAMA_ROOT/.git" ]]; then
  echo "Using unpacked llama.cpp source (zip), commit $(cat "$LLAMA_ROOT/.commit")"
else
  if [[ ! -d "$LLAMA_ROOT/.git" ]]; then
    git clone https://github.com/ggml-org/llama.cpp.git "$LLAMA_ROOT"
  fi
  git -C "$LLAMA_ROOT" fetch origin --tags
  if [[ "$LLAMA_CPP_REF" == master ]]; then
    git -C "$LLAMA_ROOT" checkout master
    git -C "$LLAMA_ROOT" pull --ff-only origin master
  else
    git -C "$LLAMA_ROOT" checkout --detach "$LLAMA_CPP_REF"
  fi
fi
cmake -S "$LLAMA_ROOT" -B "$LLAMA_ROOT/build" -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=ON -DGGML_RPC=ON -DLLAMA_USE_PREBUILT_UI=OFF
cmake --build "$LLAMA_ROOT/build" --config Release -j 8
[[ -d "$AI_ROOT/.venv" ]] || python3 -m venv "$AI_ROOT/.venv"
"$AI_ROOT/.venv/bin/python" -m pip install --upgrade pip huggingface_hub
printf '\nllama.cpp commit: '
llama_commit
ls -lh "$BIN/llama-server" "$BIN/ggml-rpc-server"
