#!/usr/bin/env bash
# Fetch/preserve the device's upstream builders locally; this never triggers Actions.
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
usage(){ cat <<EOF
Usage: bash sh/sources/prepare.sh [main|rootfs|all] [--update]
Downloads real upstream shell scripts/configs for $DEVICE into sources/recipes/.
Already downloaded sources are KEPT. --update explicitly fast-forwards them.
No builds and no GitHub Actions are triggered.
EOF
}
branch="${1:-all}"; mode="${2:-}"
case "$branch" in main|rootfs|all) ;; --help|-h|help) usage; exit 0;; *) usage; exit 2;; esac
case "$mode" in ''|--update) ;; *) usage; exit 2;; esac
bootstrap_tools
acquire_lock
if [ "$branch" = all ]; then branches=(main rootfs); else branches=("$branch"); fi
for b in "${branches[@]}"; do
  if [ "$mode" = --update ]; then refresh_repo_branch "$b"; else prepare_repo_branch "$b"; fi
done
say 'Sources prepared. Build locally with bash sh/mainline/build.sh, then bash sh/rootfs/debian.sh (or alpine/ubuntu).'
