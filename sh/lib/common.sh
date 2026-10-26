#!/usr/bin/env bash
# Local-only helpers. Conf-driven, zero validation layers: decisions live in
# conf/*.conf, the pipeline trusts them, failures surface in the run log.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RECIPES="$ROOT/recipes"
SOURCES="$ROOT/sources"
CACHE="$ROOT/cache"
BUILDS="$ROOT/build"
CHECKPOINT="$CACHE/mainline/checkpoint"
MODULE_CACHE="$CACHE/mainline/modules"
export LC_ALL=C

# The customization surface: exactly these four files. Nothing else reads or
# ships defaults; empty values keep the built-in runtime defaults.
for conf in device build kernel rootfs; do
  source "$ROOT/conf/$conf.conf"
done
: "${DEVICE:=channel}"
# The mirror stages run as child processes: broadcast the knobs they consume.
export JOBS KERNEL_LOCALVERSION MODULES_ARCHIVE_BASE DEVICE

say() { printf '\n[%s] %s\n' "$DEVICE" "$*"; }
die() { printf '\nERROR [%s]: %s\n' "$DEVICE" "$*" >&2; exit 1; }

# Root container without a sudo binary (minimal images): run apt directly.
# Normal users always go through sudo.
run_root() {
  if [ "$(id -u)" -eq 0 ] && ! command -v sudo >/dev/null; then
    "$@"
  else
    sudo "$@"
  fi
}

require_linux() {
  [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || die 'Requires Linux x86_64 (any apt-based distro; WSL2 works).'
  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null || die 'Requires sudo. Run as a normal sudo-enabled user.'
  fi
}

bootstrap_tools() {
  require_linux
  local missing=() cmd
  for cmd in git curl rsync python3 sha256sum flock tar zstd; do
    command -v "$cmd" >/dev/null || missing+=("$cmd")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    say "Installing essential utilities: ${missing[*]}"
    command -v sudo >/dev/null && sudo -v
    run_root apt-get update
    run_root apt-get install -y --no-install-recommends git curl rsync python3 coreutils util-linux tar zstd ca-certificates
  fi
  if [ "$(id -u)" -eq 0 ] && ! command -v sudo >/dev/null; then
    say 'Root container without sudo: installing sudo so mirror scripts keep working'
    run_root apt-get update
    run_root apt-get install -y --no-install-recommends sudo
  fi
}

acquire_lock() {
  mkdir -p "$CACHE"
  exec 9>"$CACHE/.build.lock"
  flock -x 9 || die 'Could not acquire local builder lock.'
}

new_stamp() { date -u +%Y%m%d%H%M%S; }

# Kernel modules archive name, derived from the built release and the conf base.
modules_archive_name() { printf '%s-%s.tar.zst' "${MODULES_ARCHIVE_BASE:-kernel-modules}" "$1"; }
