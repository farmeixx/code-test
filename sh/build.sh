#!/usr/bin/env bash
# Small local-only entry point; real stages live under sh/mainline and sh/rootfs.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage(){ cat <<'EOF'
LOCAL MAINLINE + ROOTFS BUILDER
  bash sh/build.sh kernel            Compile mainline kernel; preserve modules + ccache
  bash sh/build.sh alpine            Alpine image from existing kernel modules
  bash sh/build.sh debian            Debian image from existing kernel modules
  bash sh/build.sh ubuntu            Ubuntu image from existing kernel modules
  bash sh/build.sh all               Kernel once + all three rootfs (sequential)
  bash sh/build.sh sources           Download local recipe sources (no compilation)
  bash sh/build.sh status            List cached kernel and completed builds
  bash sh/build.sh help
Or run directly: bash sh/mainline/build.sh ; bash sh/rootfs/alpine.sh
No GitHub Actions, no workflow Run ID, no remote CI.
EOF
}
case "${1:-help}" in
  help|-h|--help) usage;;
  sources) exec bash "$ROOT/sh/sources/prepare.sh" all;;
  status) exec bash "$ROOT/sh/status.sh";;
  kernel) exec bash "$ROOT/sh/mainline/build.sh";;
  alpine|debian|ubuntu) exec bash "$ROOT/sh/rootfs/$1.sh";;
  all)
    bash "$ROOT/sh/mainline/build.sh"
    for distro in alpine debian ubuntu; do bash "$ROOT/sh/rootfs/$distro.sh"; done
    ;;
  *) usage; exit 2;;
esac
