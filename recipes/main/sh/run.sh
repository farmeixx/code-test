#!/usr/bin/env bash
# Generic source checkout / kernel build / boot image / checkpoint pipeline.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF="${KERNEL_MAINLINE_CONF:-$ROOT/conf/mainline.conf}"
test -s "$CONF" || { echo "Missing mainline.conf: $CONF" >&2; exit 1; }
export KERNEL_MAINLINE_CONF="$CONF"
source "$CONF"
: "${KERNEL_URL:?set KERNEL_URL}"
: "${KERNEL_REF:?set KERNEL_REF}"
: "${KERNEL_CLONE_DIR:?set KERNEL_CLONE_DIR}"
: "${KERNEL_MKBOOTIMG_URL:?set KERNEL_MKBOOTIMG_URL}"
: "${KERNEL_MKBOOTIMG_REF:?set KERNEL_MKBOOTIMG_REF}"

#------------------------------------------------------------------#

# Log presentation stays outside the build logic: sh/ui.sh only prints the
# phase banner, step subtitles and result banners. The EXIT trap keeps the
# real status: on failure it prints B U I L D F A I L E D and exits.
source "$ROOT/sh/ui.sh"
trap 'rc=$?; if [ "$rc" -ne 0 ]; then ui_failed; fi; exit "$rc"' EXIT

ui_banner "BUILDING MAINLINE KERNEL"

#------------------------------------------------------------------#

ui_step "installing build host dependencies for the kernel profile"
source "$ROOT/sh/deps.sh"
install_host_deps kernel
WORK="$ROOT/.work/kernel"
KERNEL_DIR="$(realpath -m "$ROOT/$KERNEL_CLONE_DIR")"
# Clone location is configurable, but never allow rm -rf outside .work.
case "$KERNEL_DIR" in "$ROOT/.work/"*) ;; *) echo "KERNEL_CLONE_DIR must be under .work/" >&2; exit 1 ;; esac
MKBOOT_DIR="$WORK/aosp-mkbootimg"
STAGING="$ROOT/out/kernel/.checkpoint-staging"
CHECKPOINT="$ROOT/out/kernel/checkpoint"
IMAGES="$ROOT/out/kernel/images"
mkdir -p "$WORK" "$ROOT/out/kernel"
CCACHE_BIN_DIR="$WORK/ccache-bin"
mkdir -p "$CCACHE_BIN_DIR"
ln -sfn "$(command -v ccache)" "$CCACHE_BIN_DIR/${KERNEL_CROSS_COMPILE}gcc"
export PATH="$CCACHE_BIN_DIR:$PATH"
echo "ccache active for ${KERNEL_CROSS_COMPILE}gcc"
rm -rf "$KERNEL_DIR" "$STAGING"
mkdir -p "$STAGING"

#------------------------------------------------------------------#

# Source checkout: resolve the requested head first so the clone can be
# proven to point exactly at that commit; a shifted ref aborts the build.
ui_step "checking $KERNEL_REF head of $KERNEL_URL"
SOURCE_SHA="$(git ls-remote "$KERNEL_URL" "refs/heads/$KERNEL_REF" | awk 'NR==1 {print $1}')"
test -n "$SOURCE_SHA" || { echo "Kernel ref unavailable: $KERNEL_REF" >&2; exit 1; }
ui_step "cloning into $KERNEL_DIR at depth 1"
git clone --depth=1 --branch "$KERNEL_REF" "$KERNEL_URL" "$KERNEL_DIR"
test "$(git -C "$KERNEL_DIR" rev-parse HEAD)" = "$SOURCE_SHA" || {
  echo 'Kernel ref advanced while cloning; retry the build' >&2; exit 1;
}
printf 'kernel_url=%s\nkernel_ref=%s\nkernel_source_sha=%s\n' \
  "$KERNEL_URL" "$KERNEL_REF" "$SOURCE_SHA" > "$STAGING/source-report.txt"
export KERNEL_DIR OUT_DIR="$STAGING"
ui_step "building the kernel artifact set"
bash "$ROOT/sh/build.sh"
KREL="$(cat "$STAGING/kernel-release.txt")"
DTB_NAME="${KERNEL_DTB##*/}"
{
  printf 'kernel_config_1=%s\nkernel_config_2=%s\n' "${KERNEL_CONFIG_1:-}" "${KERNEL_CONFIG_2:-}"
  for f in "$STAGING"/config-fragment-*.config; do
    [ -f "$f" ] || continue
    printf '%s_sha256=%s\n' "${f##*/}" "$(sha256sum "$f" | cut -d' ' -f1)"
  done
} >> "$STAGING/source-report.txt"

#------------------------------------------------------------------#

# mkbootimg tool checkout: always at one exact commit; a matching existing
# checkout is reused instead of being refetched.
if [ ! -s "$MKBOOT_DIR/mkbootimg.py" ] || \
   [ "$(git -C "$MKBOOT_DIR" rev-parse HEAD 2>/dev/null || true)" != "$KERNEL_MKBOOTIMG_REF" ]; then
  ui_step "cloning mkbootimg into $MKBOOT_DIR at $KERNEL_MKBOOTIMG_REF"
  rm -rf "$MKBOOT_DIR"
  git init -q "$MKBOOT_DIR"
  git -C "$MKBOOT_DIR" remote add origin "$KERNEL_MKBOOTIMG_URL"
  git -C "$MKBOOT_DIR" fetch --depth=1 origin "$KERNEL_MKBOOTIMG_REF"
  git -C "$MKBOOT_DIR" checkout -q --detach FETCH_HEAD
else
  ui_step "reusing mkbootimg checkout $MKBOOT_DIR"
fi

test "$(git -C "$MKBOOT_DIR" rev-parse HEAD)" = "$KERNEL_MKBOOTIMG_REF"
python3 "$MKBOOT_DIR/mkbootimg.py" --help >/dev/null
python3 "$MKBOOT_DIR/unpack_bootimg.py" --help >/dev/null

#------------------------------------------------------------------#

ui_step "packing $KERNEL_BOOT_NAME with Image.gz and DTB"
export KERNEL_RELEASE="$KREL" KERNEL_IMAGE="$STAGING/Image.gz" \
  KERNEL_DTB_FILE="$STAGING/$DTB_NAME" MKBOOTIMG_PY="$MKBOOT_DIR/mkbootimg.py"
bash "$ROOT/sh/bootimg.sh"

grep -Fq "root=$KERNEL_ROOT_DEVICE" "$STAGING/kernel-cmdline.txt" || {
  echo "Boot cmdline root does not match KERNEL_ROOT_DEVICE" >&2; exit 1;
}

#------------------------------------------------------------------#

# Restart of the packed image: the cmdline must contain the configured root
# device, the payload must equal Image.gz + DTB and no ramdisk may appear.
ui_step "unpacking $KERNEL_BOOT_NAME, verifying payload and cmdline"
UNPACKED="$WORK/unpacked-boot"
rm -rf "$UNPACKED"
python3 "$MKBOOT_DIR/unpack_bootimg.py" --boot_img "$STAGING/$KERNEL_BOOT_NAME" --out "$UNPACKED"
test -s "$UNPACKED/kernel"
cmp -s "$UNPACKED/kernel" "$STAGING/Image.gz-dtb" || {
  echo 'Boot image kernel payload differs from the validated Image.gz + DTB checkpoint' >&2
  exit 1
}
test ! -s "$UNPACKED/ramdisk"

#------------------------------------------------------------------#

ui_step "assembling the checkpoint files and SHA256SUMS"
printf 'root_device=%s\n' "$KERNEL_ROOT_DEVICE" >> "$STAGING/kernel-info.txt"
cp "$CONF" "$STAGING/mainline.conf"
(
  cd "$STAGING"
  files=("$KERNEL_BOOT_NAME" Image.gz Image.gz-dtb "$DTB_NAME" kernel.config \
    mainline.conf System.map kernel-release.txt kernel-modules-*.tar.zst)
  for f in config-fragment-*.config; do
    [ -f "$f" ] && files+=("$f")
  done
  sha256sum "${files[@]}" > SHA256SUMS
)
ui_step "validating the finished checkpoint"
KERNEL_CHECKPOINT_DIR="$STAGING" bash "$ROOT/sh/validate.sh" --full

#------------------------------------------------------------------#

# Publish atomically: staging only becomes the checkpoint once validation
# succeeded; the previous checkpoint is kept until the move completes.
ui_step "publishing checkpoint to out/kernel/checkpoint"
PREVIOUS="$ROOT/out/kernel/.checkpoint-previous"
rm -rf "$PREVIOUS"
if [ -d "$CHECKPOINT" ]; then mv "$CHECKPOINT" "$PREVIOUS"; fi
if ! mv "$STAGING" "$CHECKPOINT"; then
  [ ! -d "$PREVIOUS" ] || mv "$PREVIOUS" "$CHECKPOINT"
  echo 'Unable to publish kernel checkpoint' >&2
  exit 1
fi
mkdir -p "$IMAGES"
cp -f "$CHECKPOINT/$KERNEL_BOOT_NAME" "$IMAGES/boot.img"
cp -f "$CHECKPOINT/$KERNEL_BOOT_NAME" "$IMAGES/$KERNEL_BOOT_NAME"
rm -rf "$PREVIOUS"
printf '\nKernel build complete: %s\n' "$KREL"
ccache --show-stats


#------------------------------------------------------------------#

ui_success
ui_saved "boot.img" "out/kernel/images/boot.img"
ui_saved "kernel checkpoint" "out/kernel/checkpoint"
ui_saved "module archive" "out/kernel/checkpoint/kernel-modules-$KREL.tar.zst"
