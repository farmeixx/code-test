#!/usr/bin/env bash
# Only fetch an existing successful, unexpired mainline kernel checkpoint.
# Never launch or build the kernel from any rootfs workflow.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISTRO="${1:?Usage: bash sh/build.sh alpine|debian|ubuntu}"
case "$DISTRO" in alpine|debian|ubuntu);; *) echo "Invalid distro: $DISTRO" >&2; exit 2;; esac

#------------------------------------------------------------------#

# Presentation helpers and failure reporting; exec replaces the process,
# and run.sh still re-arms its own trap (traps do not survive exec).
source "$ROOT/sh/ui.sh"
trap 'rc=$?; if [ "$rc" -ne 0 ]; then ui_failed; fi; exit "$rc"' EXIT

ui_banner "BUILDING ROOTFS" "${DISTRO^^}"

if [ "${GITHUB_ACTIONS:-}" = true ]; then
  bash "$ROOT/sh/fetch-kernel.sh"
fi
exec bash "$ROOT/sh/run.sh" "$DISTRO"
