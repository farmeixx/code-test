#!/usr/bin/env bash
# Single local entry point; real stages live under sh/mainline and sh/rootfs.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage(){ cat <<EOF
LOCAL CHANNEL BUILDER (conf/*.conf decides everything)
  bash sh/build.sh kernel            Compile mainline kernel; modules + ccache persist
  bash sh/build.sh alpine|debian|ubuntu
                                     Raw ext4 rootfs from the cached kernel checkpoint
  bash sh/build.sh all               Kernel once + every distro in conf/rootfs.conf DISTROS
  bash sh/build.sh status            Local report (checkpoint, modules, ccache, images)
  bash sh/build.sh help
Or run the stages directly: bash sh/mainline/build.sh ; bash sh/rootfs/build.sh ubuntu
No GitHub Actions, no CI, no validation layers: read the run log.
EOF
}
case "${1:-help}" in
  help|-h|--help) usage;;
  status)
    source "$ROOT/sh/lib/common.sh"
    printf 'Device: %s\nRoot: %s\nKernel label: %s\n' "$DEVICE" "$ROOT" "$KERNEL_LOCALVERSION"
    [ ! -s "$CHECKPOINT/kernel-release.txt" ] || printf 'Cached kernel: %s\n' "$(cat "$CHECKPOINT/kernel-release.txt")"
    [ ! -s "$MODULE_CACHE/current.txt" ] || printf 'Cached modules: %s\n' "$(cat "$MODULE_CACHE/current.txt")"
    if command -v ccache >/dev/null && [ -d "$CACHE/mainline/ccache" ]; then
      CCACHE_DIR="$CACHE/mainline/ccache" ccache -s || true
    fi
    printf '\nCompleted images:\n'
    find "$BUILDS" -type f \( -name '*.img' -o -name '*.ext4' \) -print 2>/dev/null | sort || true
    ;;
  kernel) exec bash "$ROOT/sh/mainline/build.sh";;
  alpine|debian|ubuntu) exec bash "$ROOT/sh/rootfs/build.sh" "$1";;
  all)
    source "$ROOT/sh/lib/common.sh"
    bash "$ROOT/sh/mainline/build.sh"
    for distro in $DISTROS; do bash "$ROOT/sh/rootfs/build.sh" "$distro"; done
    ;;
  *) usage; exit 2;;
esac
