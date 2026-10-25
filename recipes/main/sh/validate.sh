#!/usr/bin/env bash
# Generic kernel checkpoint validation. Per-device checks live in mainline.conf.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${KERNEL_MAINLINE_CONF:-$ROOT/conf/mainline.conf}"
DIR="${KERNEL_CHECKPOINT_DIR:-$ROOT/out/kernel/checkpoint}"
MODE="${1:---full}"
[ "$MODE" = --full ] || [ "$MODE" = --basic ] || { echo 'Usage: validate.sh --full|--basic' >&2; exit 2; }
DTB_NAME="${KERNEL_DTB##*/}"
for name in Image.gz "$DTB_NAME" kernel.config System.map kernel-release.txt "$KERNEL_BOOT_NAME" SHA256SUMS; do
  test -s "$DIR/$name" || { echo "Missing checkpoint file: $name" >&2; exit 1; }
done

#------------------------------------------------------------------#

KREL="$(cat "$DIR/kernel-release.txt")"
[[ "$KREL" =~ ^[-A-Za-z0-9._+]+$ && "$KREL" != *-dirty ]] || { echo "Invalid kernel release: $KREL" >&2; exit 1; }
MOD="$DIR/kernel-modules-$KREL.tar.zst"
test -s "$MOD"
if [ "$MODE" = --basic ]; then
  echo "Kernel checkpoint found: $KREL"
  exit 0
fi
(
  cd "$DIR"
  sed 's@  out/@  @' SHA256SUMS | sha256sum --check --status -
) || { echo 'Checkpoint checksums failed' >&2; exit 1; }
if [ -n "${KERNEL_DTB_CHECK_NODE:-}" ]; then
  test "$(fdtget -t s "$DIR/$DTB_NAME" "$KERNEL_DTB_CHECK_NODE" "$KERNEL_DTB_CHECK_PROPERTY")" = "$KERNEL_DTB_CHECK_VALUE" || {
    echo 'DTB compatible check failed' >&2; exit 1;
  }
fi

#------------------------------------------------------------------#

for sym in "${KERNEL_REQUIRE_Y[@]}"; do
  grep -qx "CONFIG_${sym#CONFIG_}=y" "$DIR/kernel.config" || {
    echo "Missing required built-in config: $sym" >&2; exit 1;
  }
done
for sym in "${KERNEL_REQUIRE_M[@]}"; do
  grep -qx "CONFIG_${sym#CONFIG_}=m" "$DIR/kernel.config" || {
    echo "Missing required kernel module config: $sym" >&2; exit 1;
  }
done
bash "$ROOT/sh/check-kernel-release.sh" "$DIR/Image.gz" "$KREL"
bash "$ROOT/sh/check-modules.sh" "$MOD" "$KREL"
echo "Validated kernel checkpoint: $KREL"
