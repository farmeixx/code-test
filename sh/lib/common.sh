#!/usr/bin/env bash
# Common LOCAL-only helpers. No GitHub Actions, workflow runs, dispatches, or cloud jobs.
# The upstream builders ARE VENDORED in recipes/ (main + rootfs trees of
# farmeixx/channel-rootfs, see recipes/.vendored-from): the build steps never
# fetch scripts at runtime, so there is no stale-checkout hazard; updates go
# through sh/sources/vendor.sh, an explicit-only maintenance command.
set -Eeuo pipefail
DEVICE="channel"
VENDOR_REPO="farmeixx/${DEVICE}-rootfs"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RECIPES="$ROOT/recipes"
SOURCES="$ROOT/sources"
CACHE="$ROOT/cache"
BUILDS="$ROOT/build"
CHECKPOINT="$CACHE/mainline/checkpoint"
MODULE_CACHE="$CACHE/mainline/modules"
export LC_ALL=C

say() { printf '\n[%s] %s\n' "$DEVICE" "$*"; }
die() { printf '\nERROR [%s]: %s\n' "$DEVICE" "$*" >&2; exit 1; }

# Release identity and the module extraction contract are shipped conf files
# in conf/: every consumer (kernel checkpoint, rootfs drivers, status) sources
# them ONCE here, so no stage can start from a different release name and any
# missing or empty pin dies at startup, before touching the cache.
RELEASE_CONF="$ROOT/conf/release.conf"
MODULES_CONF="$ROOT/conf/modules.conf"
[ -s "$RELEASE_CONF" ] || die "Missing kernel release pin: $RELEASE_CONF"
[ -s "$MODULES_CONF" ] || die "Missing module extraction contract: $MODULES_CONF"
source "$RELEASE_CONF"
source "$MODULES_CONF"
: "${KERNEL_RELEASE:?conf/release.conf must set KERNEL_RELEASE}"
: "${KERNEL_SUFFIX:?conf/release.conf must set KERNEL_SUFFIX}"
: "${MODULES_ARCHIVE:?conf/modules.conf must set MODULES_ARCHIVE}"
: "${MODULES_TARGET:?conf/modules.conf must set MODULES_TARGET}"
: "${MODULES_SHA_MANIFEST:?conf/modules.conf must set MODULES_SHA_MANIFEST}"
[ "${#MODULES_REQUIRED[@]}" -gt 0 ] || die 'conf/modules.conf must declare at least one required module.'
case "$KERNEL_SUFFIX" in -*) ;; *) die "conf/release.conf KERNEL_SUFFIX ($KERNEL_SUFFIX) must start with a dash.";; esac
case "$KERNEL_RELEASE" in *"$KERNEL_SUFFIX") ;; *) die "conf/release.conf KERNEL_RELEASE ($KERNEL_RELEASE) must end with KERNEL_SUFFIX.";; esac

# Root container without a sudo binary (minimal images): run apt directly.
# Normal users always go through sudo. Upstream scripts call sudo directly,
# so bootstrap_tools also installs sudo for the missing-binary case.
run_root() {
  if [ "$(id -u)" -eq 0 ] && ! command -v sudo >/dev/null; then
    "$@"
  else
    sudo "$@"
  fi
}

require_linux() {
  [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || die 'Requires Linux x86_64 (Debian, Ubuntu, Mint or any apt-based distro; WSL2 works).'
  command -v apt-get >/dev/null && command -v dpkg >/dev/null || die 'Requires an apt-based distro (apt-get and dpkg must exist).'
  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null || die 'Requires sudo. Run as a normal sudo-enabled user.'
  fi
}

bootstrap_tools() {
  require_linux
  local missing=() cmd
  for cmd in git curl rsync python3 sha256sum flock tar; do
    command -v "$cmd" >/dev/null || missing+=("$cmd")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    say "Installing essential utilities: ${missing[*]}"
    command -v sudo >/dev/null && sudo -v
    run_root apt-get update
    run_root apt-get install -y --no-install-recommends git curl rsync python3 coreutils util-linux tar ca-certificates
  fi
  if [ "$(id -u)" -eq 0 ] && ! command -v sudo >/dev/null; then
    say 'Root container without sudo: installing sudo so the upstream scripts keep working'
    run_root apt-get update
    run_root apt-get install -y --no-install-recommends sudo
  fi
}

acquire_lock() {
  mkdir -p "$CACHE"
  exec 9>"$CACHE/.build.lock"
  flock -x 9 || die 'Could not acquire local builder lock.'
}

# The vendored upstream builders live under recipes/ as plain tracked content.
# vendor_check only asserts presence of the exact contract the runners consume
# (fail-closed: missing files abort before touching any cache). There is no git
# plumbing here on purpose: refreshing vendored content is an explicit command,
# bash sh/sources/vendor.sh, which rewrites recipes/ and recipes/.vendored-from.
vendor_check() {
  local branch="$1" dest="$RECIPES/$branch" distro
  case "$branch" in
    main)
      [ -s "$dest/sh/run.sh" ] && [ -s "$dest/sh/build.sh" ] || die 'Vendored kernel builder missing (recipes/main/sh/run.sh, sh/build.sh). Run bash sh/sources/vendor.sh.'
      [ -s "$dest/sh/bootimg.sh" ] && [ -s "$dest/sh/validate.sh" ] || die 'Vendored kernel boot image helper or checkpoint validator missing.'
      [ -s "$dest/sh/deps.sh" ] || die 'Vendored kernel host dependency script missing (sh/deps.sh).'
      [ -s "$dest/conf/mainline.conf" ] || die 'Vendored conf/mainline.conf missing (device configuration).'
      ;;
    rootfs)
      for distro in alpine debian ubuntu; do
        [ -s "$dest/distros/$distro/build.sh" ] || die "Vendored $distro builder missing (recipes/rootfs/distros/$distro/build.sh). Run bash sh/sources/vendor.sh."
      done
      [ -s "$dest/sh/run.sh" ] && [ -s "$dest/sh/validate.sh" ] && [ -s "$dest/sh/deps.sh" ] || die 'Vendored rootfs orchestration scripts missing.'
      [ -s "$dest/sh/firmware.sh" ] && [ -s "$dest/conf/firmware.conf" ] && [ -s "$dest/conf/usb.conf" ] || die 'Vendored device firmware/USB configuration missing (sh/firmware.sh, conf/*.conf).'
      ;;
    *) die "Unexpected vendored recipe: $branch";;
  esac
}

ensure_checkpoint() {
  [ -s "$CHECKPOINT/kernel-release.txt" ] || die 'No compiled kernel cache. Run bash sh/mainline/build.sh first.'
  [ -s "$CHECKPOINT/SHA256SUMS" ] || die 'Incomplete cached kernel checkpoint.'
  local krel archive boot
  krel="$(cat "$CHECKPOINT/kernel-release.txt")"
  # Choke point of the release pin: kernel AND rootfs consumers both come
  # through here, so a moved base refuses every stage in one place, before
  # anything is packed or shipped to a device.
  [ "$krel" = "$KERNEL_RELEASE" ] || die "Cached release ($krel) differs from the pinned release ($KERNEL_RELEASE). Bump conf/release.conf or rebuild."
  case "$krel" in *"$KERNEL_SUFFIX") ;; *) die "Cached release ($krel) does not carry the pinned suffix ($KERNEL_SUFFIX).";; esac
  archive="$CHECKPOINT/$MODULES_ARCHIVE"
  [ -s "$archive" ] || die "Cached kernel modules missing: $archive"
  boot="$(printf '%s\n' "$CHECKPOINT"/boot-*.img)"
  [ -s "$boot" ] || die 'Kernel boot image missing from cached checkpoint.'
  printf '%s\n' "$krel"
}

# Verify the extraction contract against a module archive by listing it: after
# the SHA comparison, the archive picked by the checkpoint must unpack into
# MODULES_TARGET carrying every module from MODULES_REQUIRED. zstd and tar
# only read; nothing is extracted at this point.
check_required_modules() {
  local archive="$1" entries entry
  [ -s "$archive" ] || die "Module archive missing: $archive"
  entries="$(tar -I zstd -tf "$archive")"
  for entry in "${MODULES_REQUIRED[@]}"; do
    printf '%s\n' "$entries" | grep -Fq "/$entry.ko" || die "Module archive $archive is missing required module '$entry' (contract: conf/modules.conf)."
  done
}

new_stamp() { date -u +%Y%m%d%H%M%S; }
