#!/usr/bin/env bash
# LOCAL-only helpers (user-supplied host tools; nothing is ever installed).
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

# The variant identity: the host is prepared by the USER (REQUISITOS.txt);
# this builder only verifies. README documents the list.
require_tools() {
  local phase="$1"
  [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || die "Requires Linux x86_64 to build; this variant never installs host dependencies."
  local missing=() cmd
  case "$phase" in
    kernel)
      for cmd in make bc bison flex ccache aarch64-linux-gnu-gcc pahole python3 gzip zstd file fdtget sha256sum curl tar git flock; do
        command -v "$cmd" >/dev/null || missing+=("$cmd")
      done
      ;;
    alpine|debian|ubuntu)
      for cmd in rsync cpio gzip xz zstd openssl e2fsck mkfs.ext4 tune2fs blkid truncate python3 file ssh update-binfmts depmod sha256sum curl tar git flock; do
        command -v "$cmd" >/dev/null || missing+=("$cmd")
      done
      if [ ! -x /usr/bin/qemu-aarch64-static ]; then missing+=('qemu-aarch64-static'); fi
      if [ "$phase" != alpine ]; then
        command -v arch-test >/dev/null || missing+=('arch-test')
      fi
      if [ "$phase" = debian ]; then
        command -v mmdebstrap >/dev/null || missing+=('mmdebstrap')
      fi
      ;;
    *) die "Unexpected tool phase: $phase";;
  esac
  if [ "${#missing[@]}" -gt 0 ]; then
    die "Missing host tools: ${missing[*]}. This variant never installs host dependencies; prepare the host with REQUISITOS.txt."
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
  archive="$CHECKPOINT/kernel-modules-$krel.tar.zst"
  [ -s "$archive" ] || die "Cached kernel modules missing: $archive"
  boot="$(printf '%s\n' "$CHECKPOINT"/boot-*.img)"
  [ -s "$boot" ] || die 'Kernel boot image missing from cached checkpoint.'
  printf '%s\n' "$krel"
}

new_stamp() { date -u +%Y%m%d%H%M%S; }
