#!/usr/bin/env bash
# Generic firmware importer: all device-specific paths live in firmware.conf.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:-check}"
case "$ACTION" in
  check|install) ;;
  *) echo "Usage: install.sh check|install [ROOTFS]" >&2; exit 2 ;;
esac
if [ "$ACTION" = install ] && { [ "$#" -lt 2 ] || [ ! -d "$2" ] || [ "$2" = / ]; }; then
  echo "Usage: install.sh install EXISTING_ROOTFS" >&2
  exit 2
fi

#------------------------------------------------------------------#
source "$ROOT/sh/ui.sh"

CONF="${FIRMWARE_CONFIG:-$ROOT/conf/firmware.conf}"
test -s "$CONF" || { echo "Missing firmware.conf: $CONF" >&2; exit 1; }
# Configuration is trusted and versioned with the project.
source "$CONF"
: "${FIRMWARE_URL:?set FIRMWARE_URL in firmware.conf}"
: "${FIRMWARE_DEST:?set FIRMWARE_DEST in firmware.conf}"
declare -p FIRMWARE_DIRS FIRMWARE_ALIASES FIRMWARE_REQUIRED >/dev/null
[[ "$FIRMWARE_DEST" == /lib/firmware || "$FIRMWARE_DEST" == /lib/firmware/* ]] || {
  echo "Firmware destination must be under /lib/firmware" >&2; exit 1;
}

WORK="$ROOT/.work/firmware"
mkdir -p "$WORK"
if [ -n "${FIRMWARE_SOURCE_DIR:-}" ]; then
  SOURCE="$(realpath "$FIRMWARE_SOURCE_DIR")"
  ui_step "reusing firmware from $SOURCE"
  test -d "$SOURCE" || { echo "Firmware directory missing: $SOURCE" >&2; exit 1; }
elif [ -n "${FIRMWARE_LOCAL_PATH:-}" ] && [ -d "$ROOT/$FIRMWARE_LOCAL_PATH" ]; then
  SOURCE="$(realpath "$ROOT/$FIRMWARE_LOCAL_PATH")"
  ui_step "reusing firmware from $SOURCE"
elif [ -n "${FIRMWARE_SOURCE_ARCHIVE:-}" ]; then
  command -v bsdtar >/dev/null || { echo "RAR input requires bsdtar (libarchive-tools)" >&2; exit 1; }
  ARCHIVE="$(realpath "$FIRMWARE_SOURCE_ARCHIVE")"
  test -s "$ARCHIVE"
  if [ -n "${FIRMWARE_ARCHIVE_SHA256:-}" ]; then
    printf '%s  %s\n' "$FIRMWARE_ARCHIVE_SHA256" "$ARCHIVE" | sha256sum -c --status -
  fi
  SOURCE="$WORK/archive"
  rm -rf "$SOURCE"
  mkdir -p "$SOURCE"
  ui_step "unpacking firmware archive $ARCHIVE"
  bsdtar -xf "$ARCHIVE" -C "$SOURCE"
else
  command -v git >/dev/null || { echo 'git required to fetch firmware' >&2; exit 1; }
  SOURCE="$WORK/source"
  rm -rf "$SOURCE"
  ui_step "cloning firmware into $SOURCE"
  if [ -n "${FIRMWARE_REF:-}" ]; then
    git clone --depth=1 --branch "$FIRMWARE_REF" "$FIRMWARE_URL" "$SOURCE"
  else
    git clone --depth=1 "$FIRMWARE_URL" "$SOURCE"
  fi
  echo "Firmware commit: $(git -C "$SOURCE" rev-parse HEAD)"
fi

#------------------------------------------------------------------#

# Verify repo/archive manifest when supplied. No hand-maintained blob list.
if [ -s "$SOURCE/SHA256SUMS" ]; then
  (cd "$SOURCE" && sha256sum -c --status SHA256SUMS) || {
    echo "Firmware SHA256SUMS validation failed" >&2; exit 1;
  }
fi
for relative in "${FIRMWARE_REQUIRED[@]}"; do
  [[ "$relative" != /* && "$relative" != *../* ]] || exit 1
  test -s "$SOURCE/$relative" || { echo "Missing firmware: $relative" >&2; exit 1; }
done
for pair in "${FIRMWARE_DIRS[@]}" "${FIRMWARE_ALIASES[@]}"; do
  IFS='|' read -r from to <<< "$pair"
  [[ -n "$from" && -n "$to" && "$from" != /* && "$from" != *../* && "$to" != /* && "$to" != *../* ]] || {
    echo "Invalid firmware path mapping: $pair" >&2; exit 1;
  }
  test -e "$SOURCE/$from" || { echo "Missing firmware source: $from" >&2; exit 1; }
done
[ "$ACTION" = check ] && { echo "Firmware configuration and files verified."; exit 0; }

TARGET="$(realpath "$2")"
DEST="$TARGET$FIRMWARE_DEST"
ui_step "installing firmware into $DEST"
sudo install -d -m 0755 "$DEST"
for pair in "${FIRMWARE_DIRS[@]}"; do
  IFS='|' read -r from to <<< "$pair"
  test -d "$SOURCE/$from" || { echo "Expected source directory: $from" >&2; exit 1; }
  sudo install -d -m 0755 "$DEST/$to"
  sudo cp -a "$SOURCE/$from/." "$DEST/$to/"
done
for pair in "${FIRMWARE_ALIASES[@]}"; do
  IFS='|' read -r from to <<< "$pair"
  sudo install -D -m 0644 "$SOURCE/$from" "$DEST/$to"
done
echo "Installed complete firmware tree from $SOURCE into $DEST"
