#!/usr/bin/env bash
# Generic Android boot image packer configured in mainline.conf.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${KERNEL_MAINLINE_CONF:-$ROOT/conf/mainline.conf}"
: "${KERNEL_RELEASE:?set KERNEL_RELEASE}"
: "${OUT_DIR:?set OUT_DIR}"
: "${KERNEL_BOOT_NAME:?set KERNEL_BOOT_NAME}"
DTB_FILE="${KERNEL_DTB_FILE:-$OUT_DIR/${KERNEL_DTB##*/}}"
IMAGE_FILE="${KERNEL_IMAGE:-$OUT_DIR/Image.gz}"

#------------------------------------------------------------------#

# Concatenate the validated Image.gz and DTB, then pack the boot image
KERNEL_DTB_IMAGE="$OUT_DIR/Image.gz-dtb-$KERNEL_RELEASE"
cat "$IMAGE_FILE" "$DTB_FILE" > "$KERNEL_DTB_IMAGE"
if [ -n "${MKBOOTIMG_PY:-}" ]; then
  PACKER=(python3 "$MKBOOTIMG_PY")
else
  PACKER=(mkbootimg)
fi
"${PACKER[@]}" \
  --header_version "$KERNEL_BOOT_HEADER_VERSION" \
  --kernel "$KERNEL_DTB_IMAGE" \
  --cmdline "$KERNEL_CMDLINE" \
  --base "$KERNEL_BOOT_BASE" \
  --kernel_offset "$KERNEL_BOOT_KERNEL_OFFSET" \
  --ramdisk_offset "$KERNEL_BOOT_RAMDISK_OFFSET" \
  --second_offset "$KERNEL_BOOT_SECOND_OFFSET" \
  --tags_offset "$KERNEL_BOOT_TAGS_OFFSET" \
  --pagesize "$KERNEL_BOOT_PAGE_SIZE" \
  --output "$OUT_DIR/$KERNEL_BOOT_NAME"

#------------------------------------------------------------------#

# Write the resolved commandline record next to the packed image.
printf '%s\n' "$KERNEL_CMDLINE" > "$OUT_DIR/kernel-cmdline.txt"
