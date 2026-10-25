#!/usr/bin/env bash
# Run a single local distro from the REAL upstream builder, using cached kernel modules.
# The host dependencies are the user's responsibility (REQUISITOS.txt): this variant
# only VERIFIES the tools and never installs anything itself.
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
DISTRO="debian"
usage(){ cat <<EOF
Usage: bash sh/rootfs/$DISTRO.sh [--help]
Uses the kernel and modules from cache/mainline/; never recompiles the kernel.
Creates build/rootfs/$DISTRO/$DISTRO-YYYYMMDDHHMMSS.ext4 (raw, not compressed).
EOF
}
case "${1:-}" in '' ) ;; -h|--help|help) usage; exit 0;; *) usage; exit 2;; esac

acquire_lock
KREL="$(ensure_checkpoint)"
require_tools "$DISTRO"
prepare_repo_branch rootfs
ROOTFS_SRC="$SOURCES/recipes/rootfs"

KERNEL_CHECKPOINT_DIR="$CHECKPOINT" bash "$ROOTFS_SRC/sh/validate.sh" --basic
bash "$ROOTFS_SRC/sh/firmware.sh" check

KERNEL_CHECKPOINT_DIR="$CHECKPOINT" bash "$ROOTFS_SRC/sh/validate.sh" --full

[ -s "$MODULE_CACHE/current.txt" ] || die 'Separate kernel modules cache is empty; re-run kernel build.'
MODULES="$(cat "$MODULE_CACHE/current.txt")"
case "$MODULES" in "$MODULE_CACHE"/*) ;; *) die 'Modules cache path is outside cache/mainline/modules.';; esac
[ -s "$MODULES" ] || die 'Cached modules archive is missing.'
# Never combine a newer/different kernel with stale rootfs modules.
[ "$(sha256sum "$MODULES" | cut -d ' ' -f1)" = "$(sha256sum "$CHECKPOINT/$MODULES_ARCHIVE" | cut -d ' ' -f1)" ] || die 'Cached modules are not from current kernel checkpoint.'

# Extraction contract on top of the checksum: this archive must unpack into
# $MODULES_TARGET with every module from MODULES_REQUIRED present.
check_required_modules "$CHECKPOINT/$MODULES_ARCHIVE"

# Keep upstream rootfs and per-device Wi-Fi/USB/SSH/service setup intact.
# Change ONLY final zstd compression to retain the raw ext4 as the user requested.
BUILDER="$ROOTFS_SRC/distros/$DISTRO/.local-raw-build.sh"
python3 "$ROOT/sh/lib/raw-rootfs-builder.py" "$ROOTFS_SRC/distros/$DISTRO/build.sh" "$BUILDER" "$DISTRO" "$DEVICE"
OUT_DIR="$CACHE/rootfs/$DISTRO/out"
WORK_DIR="$CACHE/rootfs/$DISTRO/work"
mkdir -p "$OUT_DIR" "$WORK_DIR" "$BUILDS/rootfs/$DISTRO"
rm -f "$OUT_DIR"/*
export DISTRO ROOTFS_LABEL="$DISTRO" KERNEL_RELEASE="$KREL" WORK_DIR OUT_DIR
export KERNEL_MODULES_ARCHIVE="$MODULES"
export KERNEL_CONFIG_FILE="$CHECKPOINT/kernel.config" KERNEL_SYSTEM_MAP_FILE="$CHECKPOINT/System.map"
say "Building $DEVICE $DISTRO from cached kernel $KREL; no kernel compile."
bash "$BUILDER"
RAW="$OUT_DIR/$DISTRO-$DEVICE-rootfs.ext4"
[ -s "$RAW" ] || die "Raw ext4 output missing: $RAW"
[ -s "$OUT_DIR/build-info.txt" ] || die 'Missing rootfs build metadata.'
[ -s "$OUT_DIR/SHA256SUMS.$DISTRO" ] || die 'Missing rootfs checksums.'
(cd "$OUT_DIR" && sha256sum --check --status "SHA256SUMS.$DISTRO") || die 'Rootfs SHA256 validation failed.'
[ "$(blkid -p -o value -s TYPE "$RAW")" = ext4 ] || die 'Output is not an ext4 filesystem.'
[ "$(blkid -p -o value -s LABEL "$RAW")" = "$DISTRO" ] || die 'Unexpected ext4 label.'
[ "$(sed -n 's/^kernel_release=//p' "$OUT_DIR/build-info.txt" | head -n 1)" = "$KREL" ] || die 'Rootfs kernel release metadata mismatch.'
grep -Fxq "rootfs_label=$DISTRO" "$OUT_DIR/build-info.txt" || die 'Rootfs label metadata mismatch.'
grep -Fxq 'ssh_listen=172.16.42.1' "$OUT_DIR/build-info.txt" || die 'USB/SSH metadata mismatch (ssh_listen).'
grep -Fxq 'wifi_runtime_setup=nmcli' "$OUT_DIR/build-info.txt" || die 'Wi-Fi runtime metadata mismatch.'
REQUIRED_MB=1024
[ "$(stat -c %s "$RAW")" -eq "$((REQUIRED_MB * 1024 * 1024))" ] || die "Rootfs size != $REQUIRED_MB MiB."
grep -Fxq "image_size_mib=$REQUIRED_MB" "$OUT_DIR/build-info.txt" || die 'Rootfs size metadata mismatch.'
case "$DISTRO" in
  alpine) REQUIRED_FREE_MB=32;;
  debian|ubuntu) REQUIRED_FREE_MB=64;;
esac
grep -Fxq "image_min_free_mib=$REQUIRED_FREE_MB" "$OUT_DIR/build-info.txt" || die 'Rootfs free-space metadata mismatch.'
FREE_MB="$(sed -n 's/^image_free_mib=//p' "$OUT_DIR/build-info.txt" | head -n1)"
[[ "$FREE_MB" =~ ^[0-9]+$ ]] && [ "$FREE_MB" -ge "$REQUIRED_FREE_MB" ] || die 'Unsafe ext4 free-space metadata.'

STAMP="$(new_stamp)"
NAME="$DISTRO-$STAMP"
DEST="$BUILDS/rootfs/$DISTRO"
[ ! -e "$DEST/$NAME.ext4" ] || die 'A rootfs with this exact timestamp already exists. Retry in a second.'
# Rename on same filesystem when possible; retains uncompressed image.
mv "$RAW" "$DEST/$NAME.ext4"
cp "$OUT_DIR/build-info.txt" "$DEST/$NAME.build-info.txt"
BOOT_IMG="$(printf '%s\n' "$CHECKPOINT"/boot-*.img)"
[ -s "$BOOT_IMG" ] || die 'Boot image missing from cached checkpoint.'
cp "$BOOT_IMG" "$DEST/$NAME.boot.img"
printf 'device=%s\ndistribution=%s\nbuild_utc=%s\nkernel_release=%s\nmodules_cache=%s\n' "$DEVICE" "$DISTRO" "$STAMP" "$KREL" "${MODULES#"$ROOT/"}" > "$DEST/$NAME.local-build.txt"
(cd "$DEST" && sha256sum "$NAME.ext4" "$NAME.boot.img" "$NAME.build-info.txt" "$NAME.local-build.txt" > "$NAME.sha256")
say "Finished: $DEST/$NAME.ext4"
say "Matching boot image: $DEST/$NAME.boot.img"
say 'Kernel checkpoint, ccache and source trees were preserved.'
