#!/usr/bin/env bash
# Common LOCAL-only helpers. No GitHub Actions, workflow runs, dispatches, or cloud jobs.
# Aligned with the CURRENT repository logic: sh/run.sh orchestration, conf/*.conf
# device configuration and the distros/ recipe layout on the rootfs branch.
set -Eeuo pipefail
DEVICE="channel"
REPO="farmeixx/${DEVICE}-rootfs"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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

prepare_repo_branch() {
  local branch="$1" dest="$SOURCES/recipes/$1" origin="https://github.com/$REPO.git"
  mkdir -p "$SOURCES/recipes"
  if [ -d "$dest/.git" ]; then
    local got
    got="$(git -C "$dest" remote get-url origin)"
    [ "$got" = "$origin" ] || die "Unexpected git origin in $dest: $got"
    [ "$(git -C "$dest" branch --show-current)" = "$branch" ] || die "Wrong branch in $dest"
  elif [ -e "$dest" ]; then
    die "Source directory exists but is not a git checkout: $dest"
  else
    say "Fetching current $DEVICE $branch scripts into sources/ (first time only)"
    GIT_TERMINAL_PROMPT=0 git clone --depth=1 --single-branch --branch "$branch" "$origin" "$dest"
  fi
  case "$branch" in
    main)
      [ -s "$dest/sh/run.sh" ] && [ -s "$dest/sh/build.sh" ] || die 'Incomplete kernel builder sources (sh/run.sh, sh/build.sh).'
      [ -s "$dest/sh/bootimg.sh" ] && [ -s "$dest/sh/validate.sh" ] || die 'Kernel boot image helper or checkpoint validator missing.'
      [ -s "$dest/sh/deps.sh" ] || die 'Kernel host dependency script missing (sh/deps.sh).'
      [ -s "$dest/conf/mainline.conf" ] || die 'Missing conf/mainline.conf (new device configuration).'
      ;;
    rootfs)
      local distro
      for distro in alpine debian ubuntu; do
        [ -s "$dest/distros/$distro/build.sh" ] || die "Missing $distro builder (distros/$distro/build.sh in the rootfs branch)."
      done
      [ -s "$dest/sh/run.sh" ] && [ -s "$dest/sh/validate.sh" ] && [ -s "$dest/sh/deps.sh" ] || die 'Rootfs orchestration scripts missing.'
      [ -s "$dest/sh/firmware.sh" ] && [ -s "$dest/conf/firmware.conf" ] && [ -s "$dest/conf/usb.conf" ] || die 'Device firmware/USB configuration missing (sh/firmware.sh, conf/*.conf).'
      ;;
    *) die "Unexpected recipe branch: $branch";;
  esac
  printf '%s\n' "$(git -C "$dest" rev-parse HEAD)" > "$dest/.local-builder-revision"
}

refresh_repo_branch() {
  local branch="$1" dest="$SOURCES/recipes/$1"
  prepare_repo_branch "$branch"
  [ -z "$(git -C "$dest" status --porcelain --untracked-files=no)" ] || die "Tracked edits in $dest; refusing to overwrite them."
  say "Fast-forwarding local $branch scripts explicitly"
  git -C "$dest" pull --ff-only
  printf '%s\n' "$(git -C "$dest" rev-parse HEAD)" > "$dest/.local-builder-revision"
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
