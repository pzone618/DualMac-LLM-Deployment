#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/common.sh"
REMOTE="${M6_USER}@${M6_IP}"
if [ "$M6_USER" = CHANGE_ME ]; then echo 'ERROR: configure M6_USER' >&2; exit 2; fi
case "${1:-}" in
  download)
    if [ "$#" -ne 4 ]; then echo 'Usage: model-manager.sh download m4|m6 repo/name file.gguf' >&2; exit 2; fi
    node="$2"; repo="$3"; file="$4"
    # Validate identifiers *before* forwarding SSH args.
    [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ "$file" =~ ^[A-Za-z0-9_.-]+\.gguf$ ]] || { echo 'Invalid repo or GGUF name' >&2; exit 2; }
    if [ "$node" = m4 ]; then
      "$ROOT/scripts/download-model.sh" "$repo" "$file"
    elif [ "$node" = m6 ]; then
      ssh -o BatchMode=yes "$REMOTE" "bash ~/AI/dual-mac-cluster/scripts/download-model.sh '$repo' '$file'"
    else echo 'node must be m4 or m6' >&2; exit 2; fi
    ;;
  inventory)
    echo '[M4 models]'
    find "$AI_ROOT/models" -type f -name '*.gguf' -print 2>/dev/null | sort
    echo '[M6 models]'
    ssh -o BatchMode=yes "$REMOTE" "find ~/AI/models -type f -name '*.gguf' -print 2>/dev/null | sort"
    ;;
  *) echo 'Usage: model-manager.sh download m4|m6 repo/name file.gguf | inventory' >&2; exit 2 ;;
esac
