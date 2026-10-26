#!/usr/bin/env bash
# Generic firmware importer: install-only. The firmware repository is cloned
# (or a local tree is reused); device data lives in conf/firmware.conf.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "$#" -lt 2 ] || [ "$1" != install ] || [ ! -d "$2" ] || [ "$2" = / ]; then
  echo "Usage: firmware.sh install EXISTING_ROOTFS" >&2
  exit 2
fi

CONF="${FIRMWARE_CONFIG:-$ROOT/conf/firmware.conf}"
source "$CONF"
: "${FIRMWARE_URL:?set FIRMWARE_URL in firmware.conf}"
: "${FIRMWARE_DEST:?set FIRMWARE_DEST in firmware.conf}"

WORK="$ROOT/.work/firmware"
mkdir -p "$WORK"
if [ -n "${FIRMWARE_SOURCE_DIR:-}" ]; then
  SOURCE="$(realpath "$FIRMWARE_SOURCE_DIR")"
else
  command -v git >/dev/null || { echo 'git required to fetch firmware' >&2; exit 1; }
  SOURCE="$WORK/source"
  rm -rf "$SOURCE"
  if [ -n "${FIRMWARE_REF:-}" ]; then
    git clone --depth=1 --branch "$FIRMWARE_REF" "$FIRMWARE_URL" "$SOURCE"
  else
    git clone --depth=1 "$FIRMWARE_URL" "$SOURCE"
  fi
  echo "Firmware commit: $(git -C "$SOURCE" rev-parse HEAD)"
fi

# Install directories and aliases straight from the source tree.
TARGET="$(realpath "$2")"
DEST="$TARGET$FIRMWARE_DEST"
sudo install -d -m 0755 "$DEST"
for pair in "${FIRMWARE_DIRS[@]}"; do
  IFS='|' read -r from to <<< "$pair"
  [ "$from" != /* ] && [ "$to" != /* ] || exit 1
  sudo install -d -m 0755 "$DEST/$to"
  sudo cp -a "$SOURCE/$from/." "$DEST/$to/"
done
for pair in "${FIRMWARE_ALIASES[@]}"; do
  IFS='|' read -r from to <<< "$pair"
  [ "$from" != /* ] && [ "$to" != /* ] || exit 1
  sudo install -D -m 0644 "$SOURCE/$from" "$DEST/$to"
done
