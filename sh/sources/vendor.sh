#!/usr/bin/env bash
# Refresh the VENDORED upstream builders (recipes/main and recipes/rootfs).
# Explicit-only maintenance command: the runtime build steps never fetch these
# scripts from GitHub again; vendored trees are committed in THIS repository.
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
[ "$#" -eq 0 ] || die 'Usage: bash sh/sources/vendor.sh'
bootstrap_tools
acquire_lock
SRC="https://github.com/$VENDOR_REPO"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
say "Fetching current vendored state of $VENDOR_REPO (main + rootfs)"
main_sha="$(git ls-remote "$SRC" main | cut -f1)"
rootfs_sha="$(git ls-remote "$SRC" rootfs | cut -f1)"
[ -n "$main_sha" ] && [ -n "$rootfs_sha" ] || die 'Could not resolve remote SHAs.'
curl -sSLo "$TMP/main.tar.gz" "$SRC/archive/$main_sha.tar.gz"
curl -sSLo "$TMP/rootfs.tar.gz" "$SRC/archive/$rootfs_sha.tar.gz"
tar -xzf "$TMP/main.tar.gz" -C "$TMP"
tar -xzf "$TMP/rootfs.tar.gz" -C "$TMP"
old_main="$(sed -n 's/^main=//p' "$RECIPES/.vendored-from")"
old_rootfs="$(sed -n 's/^rootfs=//p' "$RECIPES/.vendored-from")"
[ -n "$old_main" ] && [ -n "$old_rootfs" ] || die 'Vendored provenance corrupted: recipes/.vendored-from'
say "Vendoring $old_main -> $main_sha and $old_rootfs -> $rootfs_sha"
rm -rf "$RECIPES/main" "$RECIPES/rootfs"
mkdir -p "$RECIPES/main"
for part in sh conf; do cp -a "$TMP/channel-rootfs-$main_sha/$part" "$RECIPES/main/"; done
mkdir -p "$RECIPES/rootfs"
for part in distros sh conf audio common firmware; do cp -a "$TMP/channel-rootfs-$rootfs_sha/$part" "$RECIPES/rootfs/"; done
rm -rf "$TMP/channel-rootfs-$main_sha" "$TMP/channel-rootfs-$rootfs_sha"
{
  printf 'repo=%s\nmain=%s\nrootfs=%s\n' "$VENDOR_REPO" "$main_sha" "$rootfs_sha"
  printf 'main-paths=sh conf\nrootfs-paths=distros sh conf audio common firmware\n'
} > "$RECIPES/.vendored-from"
vendor_check main
vendor_check rootfs
say "Vendored state updated: main=$main_sha rootfs=$rootfs_sha"
say 'Commit the refresh: git add recipes && git commit -m "chore: re-vendor channel-rootfs builders"'
