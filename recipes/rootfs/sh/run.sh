#!/usr/bin/env bash
# The distro build.sh files are unchanged: only their orchestration moved here.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISTRO="${1:?Usage: bash sh/run.sh alpine|debian|ubuntu}"
case "$DISTRO" in alpine|debian|ubuntu);; *) echo 'ERROR: Unknown distribution.' >&2; exit 2;; esac

#------------------------------------------------------------------#

# Presentation for the orchestrator: build.sh printed the phase banner and
# fetched the checkpoint in its own process; everything below revalidates
# and builds. Failures exit through this trap.
source "$ROOT/sh/ui.sh"
trap 'rc=$?; if [ "$rc" -ne 0 ]; then ui_failed; fi; exit "$rc"' EXIT
CHECKPOINT="${KERNEL_CHECKPOINT_DIR:-$ROOT/out/kernel/checkpoint}"
CHECKPOINT="$(realpath -m "$CHECKPOINT")"
# Deliberately fail before installing packages or downloading a rootfs.
ui_step "validating the reused kernel checkpoint"
KERNEL_CHECKPOINT_DIR="$CHECKPOINT" bash "$ROOT/sh/validate.sh" --basic
# Check complete device firmware before installing dependencies.
ui_step "checking complete device firmware"
bash "$ROOT/sh/firmware.sh" check
source "$ROOT/sh/deps.sh"
ui_step "installing build host dependencies for $DISTRO"
install_host_deps "$DISTRO"

#------------------------------------------------------------------#

ui_step "fully validating the kernel checkpoint and module vermagic"
KERNEL_CHECKPOINT_DIR="$CHECKPOINT" bash "$ROOT/sh/validate.sh" --full
KREL="$(cat "$CHECKPOINT/kernel-release.txt")"
OUT_DIR="$ROOT/out/rootfs/$DISTRO"
WORK_DIR="$ROOT/.work/rootfs/$DISTRO"
# Keep each distro's output independent. Never delete the kernel checkpoint.
mkdir -p "$OUT_DIR" "$WORK_DIR"
rm -f "$OUT_DIR"/*
export DISTRO ROOTFS_LABEL="$DISTRO" KERNEL_RELEASE="$KREL"
export KERNEL_MODULES_ARCHIVE="$CHECKPOINT/kernel-modules-$KREL.tar.zst"
export KERNEL_CONFIG_FILE="$CHECKPOINT/kernel.config"
export KERNEL_SYSTEM_MAP_FILE="$CHECKPOINT/System.map"
export WORK_DIR OUT_DIR

#------------------------------------------------------------------#

ui_step "building the $DISTRO rootfs"
bash "$ROOT/distros/$DISTRO/build.sh"

ui_step "verifying artifacts and metadata"
SOURCE="$OUT_DIR/$DISTRO-channel-rootfs.ext4.zst"
[ -s "$SOURCE" ] || { echo "ERROR: Missing rootfs image: $SOURCE" >&2; exit 1; }
[ -s "$OUT_DIR/build-info.txt" ] || { echo 'ERROR: Missing rootfs build metadata.' >&2; exit 1; }
grep -Fxq "rootfs_label=$DISTRO" "$OUT_DIR/build-info.txt"
grep -Fxq "kernel_release=$KREL" "$OUT_DIR/build-info.txt"
grep -Fxq 'ssh_listen=172.16.42.1' "$OUT_DIR/build-info.txt"
grep -Fxq 'wifi_runtime_setup=nmcli' "$OUT_DIR/build-info.txt"
(cd "$OUT_DIR" && sha256sum -c "SHA256SUMS.$DISTRO")
# Reuse the boot image from the validated kernel checkpoint.
ui_step "reusing the checkpoint boot image from $CHECKPOINT/boot-channel.img"
cp -f "$CHECKPOINT/boot-channel.img" "$OUT_DIR/boot.img"
ui_step "expanding rootfs.ext4 for final verification"
zstd -d -f "$SOURCE" -o "$OUT_DIR/rootfs.ext4"
[ "$(blkid -p -o value -s TYPE "$OUT_DIR/rootfs.ext4")" = ext4 ] || {
  echo 'ERROR: Expanded rootfs is not ext4.' >&2; exit 1;
}
case "$DISTRO" in
  alpine) REQUIRED_IMAGE_MB=1024 ;;
  debian|ubuntu) REQUIRED_IMAGE_MB=1024 ;;
esac
grep -Fxq "image_size_mib=$REQUIRED_IMAGE_MB" "$OUT_DIR/build-info.txt"
[ "$(stat -c %s "$OUT_DIR/rootfs.ext4")" -eq $((REQUIRED_IMAGE_MB * 1024 * 1024)) ] || {
  echo "ERROR: $DISTRO rootfs is not exactly $REQUIRED_IMAGE_MB MiB." >&2
  exit 1
}
(cd "$OUT_DIR" && sha256sum boot.img rootfs.ext4 > SHA256SUMS.images)
printf '\n%s rootfs build complete.\n  Files: %s\n' "$DISTRO" "$OUT_DIR"


#------------------------------------------------------------------#

ui_success
ui_saved "$DISTRO-channel-rootfs.ext4.zst" "out/rootfs/$DISTRO/$DISTRO-channel-rootfs.ext4.zst"
ui_saved "rootfs.ext4" "out/rootfs/$DISTRO/rootfs.ext4"
ui_saved "boot.img" "out/rootfs/$DISTRO/boot.img"
ui_saved "build-info.txt" "out/rootfs/$DISTRO/build-info.txt"
ui_saved "SHA256SUMS.$DISTRO" "out/rootfs/$DISTRO/SHA256SUMS.$DISTRO"
ui_saved "SHA256SUMS.images" "out/rootfs/$DISTRO/SHA256SUMS.images"
