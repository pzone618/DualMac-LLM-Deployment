#!/bin/bash
# Central model actions from M4. Source switching: --source official|mirror|auto.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/common/common.sh"
REMOTE="${M6_USER}@${M6_IP}"
PYTHON="$AI_ROOT/.venv/bin/python"
require_exec "$PYTHON"

usage() {
  cat >&2 <<'EOF'
Usage:
  model-manager.sh download m4|m6|both owner/repo --file FILE.gguf [--source official|mirror|auto] [--revision REF] [--engine aria2|hf]
  model-manager.sh download m4|m6|both owner/repo --pattern '*Q4_K_M*.gguf' [--source mirror]
  model-manager.sh verify m4|m6|both owner/repo FILE.gguf
  model-manager.sh sync owner/repo FILE.gguf  # verified copy from M4 to M6
  model-manager.sh inventory

Default source is HF_SOURCE from config/cluster.env (auto if unspecified).
For private/gated models: --source official --engine hf.
EOF
  exit 2
}
check_ssh() {
  [[ -n "$M6_USER" && "$M6_USER" != CHANGE_ME ]] || {
    echo "ERROR: Set M6_USER in config/cluster.env" >&2; exit 2;
  }
}
# Shell-escape each provided argument. Script path is quoted on the remote side,
# allowing $HOME expansion without fragile tilde expansion.
remote_script() {
  check_ssh
  local script="$1" quoted arg command="bash \"$M6_AI_ROOT/dual-mac-cluster/scripts/$1\""
  shift
  for arg in "$@"; do
    printf -v quoted '%q' "$arg"
    command+=" $quoted"
  done
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE" "$command"
}
remote_shell() {
  check_ssh
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE" "$1"
}
valid_repo() { [[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$1" != *..* ]]; }
valid_file() { [[ "$1" =~ ^[A-Za-z0-9_.-]+\.gguf$ ]]; }

cmd="${1:-}"
case "$cmd" in
  download)
    [[ "$#" -ge 5 ]] || usage
    node="$2" repo="$3"; shift 3
    [[ "$node" == m4 || "$node" == m6 || "$node" == both ]] || usage
    valid_repo "$repo" || { echo 'Invalid repository ID' >&2; exit 2; }
    args=("$@")
    source_choice="${HF_SOURCE:-auto}"
    revision=main
    source_set=0
    for ((i=0; i<${#args[@]}; i++)); do
      if [[ "${args[i]}" == --revision || "${args[i]}" == --source ]]; then
        (( i+1 < ${#args[@]} )) || usage
        if [[ "${args[i]}" == --source ]]; then source_choice="${args[i+1]}"; source_set=1;
        else revision="${args[i+1]}"; fi
      fi
    done
    [[ "$source_choice" == official || "$source_choice" == mirror || "$source_choice" == auto ]] || usage
    # Resolve ONCE, on M4, to an immutable git commit; both nodes use the same SHA.
    sha="$("$PYTHON" "$ROOT/scripts/hf_download.py" resolve "$repo" \
       --revision "$revision" --source "$source_choice")"
    echo "Pinned $repo revision -> $sha (source=$source_choice)"
    # Explicitly forward source to both nodes, overriding their local env defaults.
    if [[ $source_set -eq 0 ]]; then args+=(--source "$source_choice"); fi
    if [[ "$node" == m4 || "$node" == both ]]; then
      "$ROOT/scripts/download-model.sh" "$repo" "${args[@]}" --revision "$sha"
    fi
    if [[ "$node" == m6 || "$node" == both ]]; then
      remote_script download-model.sh "$repo" "${args[@]}" --revision "$sha"
    fi
    ;;
  verify)
    [[ "$#" -eq 4 ]] || usage
    node="$2" repo="$3" file="$4"
    valid_repo "$repo" && valid_file "$file" || usage
    [[ "$node" == m4 || "$node" == m6 || "$node" == both ]] || usage
    if [[ "$node" == m4 || "$node" == both ]]; then
      "$ROOT/scripts/download-model.sh" verify "$repo" "$file"
    fi
    if [[ "$node" == m6 || "$node" == both ]]; then
      remote_script download-model.sh verify "$repo" "$file"
    fi
    ;;
  sync)
    [[ "$#" -eq 3 ]] || usage
    repo="$2" file="$3"
    valid_repo "$repo" && valid_file "$file" || usage
    check_ssh
    model_dir="$MODELS_DIR/${repo}"
    local_file="$model_dir/$file"
    local_meta="$model_dir/.$file.source.json"
    "$ROOT/scripts/download-model.sh" verify "$repo" "$file"
    [[ -f "$local_meta" ]] || { echo 'Missing verified source manifest' >&2; exit 2; }
    command -v rsync >/dev/null || { echo 'brew install rsync first' >&2; exit 2; }
    # rsync --append-verify keeps partial bytes and verifies all bytes before success.
    # SHA256 is checked again on the destination after transfer.
    m6_models="$(remote_shell "echo \"$M6_MODELS_DIR\"")"
    remote_shell "mkdir -p \"$m6_models/${repo}\""
    echo '[sync] verified M4 -> M6 (partial transfer resumable)'
    rsync -av --progress --partial --append-verify \
      --rsync-path=/opt/homebrew/bin/rsync \
      "$local_file" "$local_meta" "${REMOTE}:${m6_models}/${repo}/"
    remote_script download-model.sh verify "$repo" "$file"
    ;;
  inventory)
    echo '[M4] GGUF files:'
    find "$MODELS_DIR" -type f -name '*.gguf' -print 2>/dev/null | sort
    echo '[M6] GGUF files:'
    remote_shell "find \"$M6_MODELS_DIR\" -type f -name '*.gguf' -print" || true
    ;;
  *) usage ;;
esac
