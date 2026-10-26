#!/usr/bin/env bash
# LOCAL rootfs builder for one distro, using the cached kernel checkpoint.
# Sizes and free minimums come from conf/rootfs.conf (consumed by the raw
# ext4 generator below); firmware/USB/SSH/etc. data comes from the mirror confs.
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
DISTRO="${1:-}"
usage(){ cat <<EOF
Usage: bash sh/rootfs/build.sh <alpine|debian|ubuntu>
Uses the kernel and modules from cache/mainline/; never recompiles the kernel.
Creates build/rootfs/<distro>/<distro>-YYYYMMDDHHMMSS.ext4 (raw, not compressed).
EOF
}
case "$DISTRO" in alpine|debian|ubuntu) ;; *) usage; exit 2;; esac

bootstrap_tools
acquire_lock
KREL="$(cat "$CHECKPOINT/kernel-release.txt")"
MODULES="$(cat "$MODULE_CACHE/current.txt")"
ROOTFS_SRC="$RECIPES/rootfs"

source "$ROOTFS_SRC/sh/deps.sh"
install_host_deps "$DISTRO"

# Image policy from conf/rootfs.conf, consumed by the raw generator.
case "$DISTRO" in
  alpine) export IMAGE_FREE_MIN="${IMAGE_FREE_MIN_ALPINE:-32}";;
  *)      export IMAGE_FREE_MIN="${IMAGE_FREE_MIN_DEBIAN_UBUNTU:-64}";;
esac
export IMAGE_SIZE_MB="${IMAGE_SIZE_MB:-1024}"

OUT_DIR="$CACHE/rootfs/$DISTRO/out"
WORK_DIR="$CACHE/rootfs/$DISTRO/work"
BUILDER="$CACHE/rootfs/$DISTRO/raw/.local-raw-build.sh"
mkdir -p "$OUT_DIR" "$WORK_DIR" "$(dirname "$BUILDER")" "$BUILDS/rootfs/$DISTRO"
rm -f "$OUT_DIR"/*
python3 "$ROOT/sh/lib/raw-rootfs-builder.py" "$ROOTFS_SRC/distros/$DISTRO/build.sh" "$BUILDER" "$DISTRO" "$DEVICE"

export DISTRO ROOTFS_LABEL="$DISTRO" KERNEL_RELEASE="$KREL" WORK_DIR OUT_DIR
export KERNEL_MODULES_ARCHIVE="$MODULES"
export KERNEL_CONFIG_FILE="$CHECKPOINT/kernel.config" KERNEL_SYSTEM_MAP_FILE="$CHECKPOINT/System.map"
say "Building $DEVICE $DISTRO from cached kernel modules; no kernel compile."
bash "$BUILDER"

# Date the raw image into build/ and carry its metadata along.
RAW="$OUT_DIR/$DISTRO-$DEVICE-rootfs.ext4"
STAMP="$(new_stamp)"
NAME="$DISTRO-$STAMP"
DEST="$BUILDS/rootfs/$DISTRO"
mv "$RAW" "$DEST/$NAME.ext4"
cp "$OUT_DIR/build-info.txt" "$DEST/$NAME.build-info.txt"
cp "$CHECKPOINT/boot-$DEVICE.img" "$DEST/$NAME.boot.img"
printf 'device=%s\ndistribution=%s\nbuild_utc=%s\nkernel_release=%s\nmodules_archive=%s\n' \
  "$DEVICE" "$DISTRO" "$STAMP" "$KREL" "${MODULES#"$ROOT/"}" > "$DEST/$NAME.local-build.txt"
# Checksum the dated set itself (the distro builder's SHA256SUMS refers to
# the pre-dating filenames in OUT_DIR, so it is not published as-is).
(cd "$DEST" && sha256sum "$NAME.ext4" "$NAME.build-info.txt" "$NAME.boot.img" "$NAME.local-build.txt" > "$NAME.SHA256SUMS")
say "Finished: $DEST/$NAME.ext4"
say "Matching boot image: $DEST/$NAME.boot.img"
