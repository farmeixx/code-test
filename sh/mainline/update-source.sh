#!/usr/bin/env bash
# Explicit-only kernel source refresh (does NOT compile).
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
if [ "${1:-}" = --help ]; then
 echo 'Usage: bash sh/mainline/update-source.sh  (fetch new upstream kernel commit; no compilation)'; exit 0
fi
[ "$#" -eq 0 ] || die 'Usage: bash sh/mainline/update-source.sh'
bootstrap_tools
acquire_lock
KERNEL_DIR="$SOURCES/linux"
[ -d "$KERNEL_DIR/.git" ] || die 'Kernel source not cloned yet. First run sh/mainline/build.sh.'
KERNEL_REF="${KERNEL_REF:-msm8953/latest}"
[ "$(git -C "$KERNEL_DIR" branch --show-current)" = "$KERNEL_REF" ] || die 'Kernel source is on a different branch.'
say "Fast-forwarding $KERNEL_REF (does not compile the kernel)"
git -C "$KERNEL_DIR" pull --ff-only
say 'To build new kernel artifacts, run bash sh/mainline/build.sh. Old cache remains until new validation succeeds.'
