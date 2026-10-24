#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
printf 'Device: %s\nRoot: %s\n' "$DEVICE" "$ROOT"
if [ -s "$CHECKPOINT/kernel-release.txt" ]; then
  printf 'Cached kernel: %s\n' "$(cat "$CHECKPOINT/kernel-release.txt")"
  [ ! -f "$CHECKPOINT/source-report.txt" ] || grep -E '^kernel_(ref|source_sha)=' "$CHECKPOINT/source-report.txt"
else
  echo 'Cached kernel: absent (compile with bash sh/mainline/build.sh)'
fi
if [ -s "$MODULE_CACHE/current.txt" ]; then printf 'Cached modules: %s\n' "$(cat "$MODULE_CACHE/current.txt")"; fi
if command -v ccache >/dev/null && [ -d "$CACHE/mainline/ccache" ]; then
  CCACHE_DIR="$CACHE/mainline/ccache" ccache -s || true
fi
printf '\nCompleted images:\n'
find "$BUILDS" -type f \( -name '*.img' -o -name '*.ext4' \) -print 2>/dev/null | sort || true
