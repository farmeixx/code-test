#!/usr/bin/env bash
# LOCAL kernel builder: persistent sources, modules and checkpoint; compiler cache optional.
# Drives the CURRENT upstream builder (sh/build.sh + sh/bootimg.sh, everything
# device-specific coming from the repository conf logic).
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
usage(){ cat <<EOF
Usage: bash sh/mainline/build.sh [--reuse|--force|--help]

Default: build kernel from local sources (clone on first use); ccache enabled.
--reuse: only validate/use an existing kernel checkpoint; do not compile.
--force: equivalent to regular build; explicit request to compile again.
To update kernel SOURCE: bash sh/mainline/update-source.sh
Outputs: build/mainline/<device>-mainline-YYYYMMDDHHMMSS.img + DTB, config, modules, hashes.
Kernel cache: cache/mainline/checkpoint, cache/mainline/modules, cache/mainline/ccache.
EOF
}
mode="${1:-build}"
case "$mode" in build|--force|--reuse) ;; -h|--help|help) usage; exit 0;; *) usage; exit 2;; esac

bootstrap_tools
acquire_lock
if [ "$mode" = --reuse ]; then
  krel="$(ensure_checkpoint)"
  say "Kernel checkpoint already available: $krel. No compilation performed."
  exit 0
fi

prepare_repo_branch main
MAIN="$SOURCES/recipes/main"
source "$MAIN/sh/deps.sh"
install_host_deps kernel
command -v ccache >/dev/null || die 'ccache missing after host dependency installation.'
command -v fdtget >/dev/null || die 'fdtget missing.'
command -v zstd >/dev/null || die 'zstd missing.'

# Device configuration follows the repository conf logic. A KERNEL_MAINLINE_CONF
# override may point to a local file (for example inside conf/ of this builder).
CONF_PATH="${KERNEL_MAINLINE_CONF:-$MAIN/conf/mainline.conf}"
[ -s "$CONF_PATH" ] || die "Missing mainline.conf: $CONF_PATH"
export KERNEL_MAINLINE_CONF="$CONF_PATH"
source "$CONF_PATH"
: "${KERNEL_URL:?KERNEL_URL is required in mainline.conf}"
: "${KERNEL_REF:?KERNEL_REF is required in mainline.conf}"
: "${KERNEL_CROSS_COMPILE:?KERNEL_CROSS_COMPILE is required in mainline.conf}"
: "${KERNEL_DTB:?KERNEL_DTB is required in mainline.conf}"
: "${KERNEL_BOOT_NAME:?KERNEL_BOOT_NAME is required in mainline.conf}"
: "${KERNEL_ROOT_DEVICE:?KERNEL_ROOT_DEVICE is required in mainline.conf}"
: "${KERNEL_MKBOOTIMG_URL:?KERNEL_MKBOOTIMG_URL is required in mainline.conf}"
: "${KERNEL_MKBOOTIMG_REF:?KERNEL_MKBOOTIMG_REF is required in mainline.conf}"
DTB_BASENAME="${KERNEL_DTB##*/}"

# Fullyconfigured persistent compiler cache, shared between every rebuild.
export CCACHE_DIR="$CACHE/mainline/ccache" CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-2G}" CCACHE_COMPRESS=true
mkdir -p "$CCACHE_DIR" "$MODULE_CACHE" "$BUILDS/mainline" "$CACHE/mainline"
ccache --max-size "$CCACHE_MAXSIZE"
BIN="$CACHE/mainline/ccache-bin"
mkdir -p "$BIN"
ln -sfn "$(command -v ccache)" "$BIN/${KERNEL_CROSS_COMPILE}gcc"
export PATH="$BIN:$PATH"

# Persistent kernel source checkout: cloned once, then kept between builds.
KERNEL_DIR="$SOURCES/linux"
if [ -d "$KERNEL_DIR/.git" ]; then
  got="$(git -C "$KERNEL_DIR" remote get-url origin)"
  [ "$got" = "$KERNEL_URL" ] || die "Kernel source URL changed: $got (expected $KERNEL_URL)"
else
  [ ! -e "$KERNEL_DIR" ] || die "Cannot overwrite existing non-git kernel path: $KERNEL_DIR"
  say 'Cloning kernel sources once; next builds keep the checkout.'
  GIT_TERMINAL_PROMPT=0 git clone --depth=1 --single-branch --branch "$KERNEL_REF" "$KERNEL_URL" "$KERNEL_DIR"
fi
[ "$(git -C "$KERNEL_DIR" branch --show-current)" = "$KERNEL_REF" ] || die 'Kernel source branch differs from configured KERNEL_REF.'
SOURCE_SHA="$(git -C "$KERNEL_DIR" rev-parse HEAD)"

# Pinned AOSP mkbootimg: reuse a matching checkout; refetch when the pin moved.
MKBOOT_DIR="$SOURCES/mkbootimg"
if [ -s "$MKBOOT_DIR/mkbootimg.py" ] && \
   [ "$(git -C "$MKBOOT_DIR" rev-parse HEAD 2>/dev/null || true)" = "$KERNEL_MKBOOTIMG_REF" ]; then
  say "Reusing mkbootimg checkout at $KERNEL_MKBOOTIMG_REF"
else
  rm -rf "$MKBOOT_DIR"
  mkdir -p "$MKBOOT_DIR"
  git -C "$MKBOOT_DIR" init -q
  git -C "$MKBOOT_DIR" remote add origin "$KERNEL_MKBOOTIMG_URL"
  GIT_TERMINAL_PROMPT=0 git -C "$MKBOOT_DIR" fetch --depth=1 origin "$KERNEL_MKBOOTIMG_REF"
  git -C "$MKBOOT_DIR" checkout --detach -q FETCH_HEAD
fi
[ "$(git -C "$MKBOOT_DIR" rev-parse HEAD)" = "$KERNEL_MKBOOTIMG_REF" ] || die 'Cached AOSP mkbootimg SHA differs from pinned revision.'
[ -s "$MKBOOT_DIR/mkbootimg.py" ] || die 'AOSP mkbootimg.py not found.'
python3 "$MKBOOT_DIR/mkbootimg.py" --help >/dev/null
python3 "$MKBOOT_DIR/unpack_bootimg.py" --help >/dev/null

STAGE="$CACHE/mainline/.checkpoint-staging"
PREV="$CACHE/mainline/.checkpoint-previous"
rm -rf "$STAGE"
mkdir -p "$STAGE"
export OUT_DIR="$STAGE" KERNEL_DIR
say "Compiling $DEVICE kernel at $SOURCE_SHA with persistent ccache (conf: $CONF_PATH)"
bash "$MAIN/sh/build.sh"
KREL="$(cat "$STAGE/kernel-release.txt")"

{
  printf 'kernel_url=%s\nkernel_ref=%s\nkernel_source_sha=%s\n' "$KERNEL_URL" "$KERNEL_REF" "$SOURCE_SHA"
  printf 'kernel_config_1=%s\nkernel_config_2=%s\n' "${KERNEL_CONFIG_1:-}" "${KERNEL_CONFIG_2:-}"
  for f in "$STAGE"/config-fragment-*.config; do
    [ -f "$f" ] || continue
    printf '%s_sha256=%s\n' "${f##*/}" "$(sha256sum "$f" | cut -d' ' -f1)"
  done
} > "$STAGE/source-report.txt"

# Pack the Android boot image through the upstream packer (conf-driven).
export KERNEL_RELEASE="$KREL" KERNEL_IMAGE="$STAGE/Image.gz" \
  KERNEL_DTB_FILE="$STAGE/$DTB_BASENAME" MKBOOTIMG_PY="$MKBOOT_DIR/mkbootimg.py"
bash "$MAIN/sh/bootimg.sh"

grep -Fq "root=$KERNEL_ROOT_DEVICE" "$STAGE/kernel-cmdline.txt" || die 'Boot cmdline root does not match KERNEL_ROOT_DEVICE.'

# Unpack verification: the payload must equal Image.gz + DTB and no ramdisk
# may appear (same contract as the upstream run.sh checkpoint pipeline).
UNPACKED="$CACHE/mainline/.unpacked-boot"
rm -rf "$UNPACKED"
python3 "$MKBOOT_DIR/unpack_bootimg.py" --boot_img "$STAGE/$KERNEL_BOOT_NAME" --out "$UNPACKED"
test -s "$UNPACKED/kernel"
cmp -s "$UNPACKED/kernel" "$STAGE/Image.gz-dtb" || die 'Boot image kernel payload differs from the validated Image.gz + DTB checkpoint'
test ! -s "$UNPACKED/ramdisk" || die 'Boot image unexpectedly carries a ramdisk.'

# Copy the trusted configuration alongside the artifact and assemble the
# checkpoint exactly like the upstream pipeline does.
cp "$CONF_PATH" "$STAGE/mainline.conf"
printf 'root_device=%s\n' "$KERNEL_ROOT_DEVICE" >> "$STAGE/kernel-info.txt"
(
  cd "$STAGE"
  files=("$KERNEL_BOOT_NAME" Image.gz Image.gz-dtb "$DTB_BASENAME" kernel.config \
    mainline.conf System.map kernel-release.txt kernel-modules-*.tar.zst)
  for f in config-fragment-*.config; do
    [ -f "$f" ] && files+=("$f")
  done
  sha256sum "${files[@]}" > SHA256SUMS
)
KERNEL_CHECKPOINT_DIR="$STAGE" bash "$MAIN/sh/validate.sh" --full

# Keep a dated build independent from the reusable cached checkpoint.
STAMP="$(new_stamp)"
BASE="$DEVICE-mainline-$STAMP"
DEST="$BUILDS/mainline"
[ ! -e "$DEST/$BASE.img" ] || die "Existing timestamp $BASE; retry in a different second."
cp "$STAGE/$KERNEL_BOOT_NAME" "$DEST/$BASE.img"
cp "$STAGE/$DTB_BASENAME" "$DEST/$BASE.dtb"
cp "$STAGE/Image.gz" "$DEST/$BASE.Image.gz"
cp "$STAGE/kernel.config" "$DEST/$BASE.config"
cp "$STAGE/System.map" "$DEST/$BASE.System.map"
cp "$STAGE/kernel-modules-$KREL.tar.zst" "$DEST/$BASE.modules.tar.zst"
cp "$STAGE/kernel-info.txt" "$DEST/$BASE.kernel-info.txt"
cp "$STAGE/kernel-cmdline.txt" "$DEST/$BASE.kernel-cmdline.txt"
cp "$STAGE/source-report.txt" "$DEST/$BASE.source-report.txt"
(
  cd "$DEST"
  sha256sum "$BASE.img" "$BASE.dtb" "$BASE.Image.gz" "$BASE.config" "$BASE.System.map" "$BASE.modules.tar.zst" > "$BASE.sha256"
)

# Publish the cached module set separately, keyed by source SHA and release.
MOD_PATH="$MODULE_CACHE/$SOURCE_SHA/$KREL"
mkdir -p "$MOD_PATH"
cp "$STAGE/kernel-modules-$KREL.tar.zst" "$MOD_PATH/kernel-modules-$KREL.tar.zst.tmp"
mv -f "$MOD_PATH/kernel-modules-$KREL.tar.zst.tmp" "$MOD_PATH/kernel-modules-$KREL.tar.zst"

# Publish the checkpoint.
rm -rf "$PREV"
if [ -d "$CHECKPOINT" ]; then mv "$CHECKPOINT" "$PREV"; fi
if ! mv "$STAGE" "$CHECKPOINT"; then
  if [ -d "$PREV" ]; then mv "$PREV" "$CHECKPOINT"; fi
  die 'Failed to publish validated kernel checkpoint.'
fi
printf '%s\n' "$MOD_PATH/kernel-modules-$KREL.tar.zst" > "$MODULE_CACHE/current.txt"
rm -rf "$PREV"
printf '%s\n' "$BASE" > "$CACHE/mainline/latest-build.txt"

say "Kernel ready: $DEST/$BASE.img"
say "Modules: $MOD_PATH/kernel-modules-$KREL.tar.zst"
say 'Future rootfs builds reuse the checkpoint and modules without recompiling.'
ccache --show-stats
