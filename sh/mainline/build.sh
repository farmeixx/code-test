#!/usr/bin/env bash
# LOCAL kernel builder: persistent sources, modules and checkpoint; ccache.
# Everything configurable lives in conf/*.conf and the mirror confs.
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
usage(){ cat <<EOF
Usage: bash sh/mainline/build.sh [--reuse|--force|--help]

Default: build kernel from local sources (clone on first use); ccache enabled.
--force: explicit alias for a regular build (always recompiles, like the default).
--reuse: report the existing kernel checkpoint; do not compile.
To update kernel SOURCE: git -C sources/linux pull --ff-only (then build again).
Outputs: build/mainline/<device>-mainline-YYYYMMDDHHMMSS.img + DTB, config,
modules, hashes. Kernel cache: cache/mainline/{checkpoint,modules,ccache}.
EOF
}
mode="${1:-build}"
case "$mode" in build|--force|--reuse) ;; -h|--help|help) usage; exit 0;; *) usage; exit 2;; esac

bootstrap_tools
acquire_lock
if [ "$mode" = --reuse ]; then
  krel="$(cat "$CHECKPOINT/kernel-release.txt" 2>/dev/null || true)"
  if [ -n "$krel" ]; then
    say "Kernel checkpoint already available: $krel. No compilation performed."
    say "Modules: $(cat "$MODULE_CACHE/current.txt" 2>/dev/null)"
  else
    say 'No kernel checkpoint yet. Run a regular build first.'
  fi
  exit 0
fi

MAIN="$RECIPES/main"
source "$MAIN/sh/deps.sh"
install_host_deps kernel

# Device configuration comes from the mirror conf (KERNEL_MAINLINE_CONF may
# point to a local override file, e.g. conf/mainline-local.conf).
CONF_PATH="${KERNEL_MAINLINE_CONF:-$MAIN/conf/mainline.conf}"
export KERNEL_MAINLINE_CONF="$CONF_PATH"
source "$CONF_PATH"

# Persistent compiler cache, shared between every rebuild.
export CCACHE_DIR="$CACHE/mainline/ccache" \
  CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-2G}" \
  CCACHE_COMPRESS="${CCACHE_COMPRESS:-true}"
mkdir -p "$CCACHE_DIR" "$MODULE_CACHE" "$BUILDS/mainline" "$CACHE/mainline"
ccache --max-size "$CCACHE_MAXSIZE"
BIN="$CACHE/mainline/ccache-bin"
mkdir -p "$BIN"
ln -sfn "$(command -v ccache)" "$BIN/${KERNEL_CROSS_COMPILE}gcc"
export PATH="$BIN:$PATH"

# Persistent kernel source checkout: cloned once, then kept between builds.
# Updating it is a manual step: git -C sources/linux pull --ff-only
KERNEL_DIR="$SOURCES/linux"
if [ ! -d "$KERNEL_DIR/.git" ]; then
  say "Cloning kernel sources once; next builds keep the checkout."
  GIT_TERMINAL_PROMPT=0 git clone --depth=1 --single-branch --branch "$KERNEL_REF" "$KERNEL_URL" "$KERNEL_DIR"
fi
SOURCE_SHA="$(git -C "$KERNEL_DIR" rev-parse HEAD)"

# Pinned AOSP mkbootimg checkout: fetched once at the configured commit.
MKBOOT_DIR="$SOURCES/mkbootimg"
if [ ! -s "$MKBOOT_DIR/mkbootimg.py" ]; then
  rm -rf "$MKBOOT_DIR"
  mkdir -p "$MKBOOT_DIR"
  git -C "$MKBOOT_DIR" init -q
  git -C "$MKBOOT_DIR" remote add origin "$KERNEL_MKBOOTIMG_URL"
  GIT_TERMINAL_PROMPT=0 git -C "$MKBOOT_DIR" fetch --depth=1 origin "$KERNEL_MKBOOTIMG_REF"
  git -C "$MKBOOT_DIR" checkout --detach -q FETCH_HEAD
fi

STAGE="$CACHE/mainline/.checkpoint-staging"
PREV="$CACHE/mainline/.checkpoint-previous"
rm -rf "$STAGE"
mkdir -p "$STAGE"
export OUT_DIR="$STAGE" KERNEL_DIR KERNEL_LOCALVERSION
say "Compiling $DEVICE kernel at $SOURCE_SHA with ccache (conf: $CONF_PATH)"
bash "$MAIN/sh/build.sh"
KREL="$(cat "$STAGE/kernel-release.txt")"

# Pack the Android boot image through the mirror packer (conf-driven).
export KERNEL_RELEASE="$KREL" KERNEL_IMAGE="$STAGE/Image.gz" \
  KERNEL_DTB_FILE="$STAGE/${KERNEL_DTB##*/}" MKBOOTIMG_PY="$MKBOOT_DIR/mkbootimg.py"
bash "$MAIN/sh/bootimg.sh"

# Assemble the kernel checkpoint (the packaged identity for every consumer).
cp "$CONF_PATH" "$STAGE/mainline.conf"
printf 'root_device=%s\n' "$KERNEL_ROOT_DEVICE" >> "$STAGE/kernel-info.txt"
{
  printf 'kernel_url=%s\nkernel_ref=%s\nkernel_source_sha=%s\n' "$KERNEL_URL" "$KERNEL_REF" "$SOURCE_SHA"
  printf 'kernel_config_1=%s\nkernel_config_2=%s\n' "${KERNEL_CONFIG_1:-}" "${KERNEL_CONFIG_2:-}"
} > "$STAGE/source-report.txt"

# Keep a dated build independent from the reusable cached checkpoint.
STAMP="$(new_stamp)"
BASE="$DEVICE-mainline-$STAMP"
DEST="$BUILDS/mainline"
ARCHIVE="$(modules_archive_name "$KREL")"
cp "$STAGE/$KERNEL_BOOT_NAME"      "$DEST/$BASE.img"
cp "$STAGE/${KERNEL_DTB##*/}"      "$DEST/$BASE.dtb"
cp "$STAGE/Image.gz"               "$DEST/$BASE.Image.gz"
cp "$STAGE/kernel.config"          "$DEST/$BASE.config"
cp "$STAGE/System.map"             "$DEST/$BASE.System.map"
cp "$STAGE/$ARCHIVE"               "$DEST/$BASE.modules.tar.zst"
cp "$STAGE/kernel-info.txt"        "$DEST/$BASE.kernel-info.txt"
cp "$STAGE/kernel-cmdline.txt"     "$DEST/$BASE.kernel-cmdline.txt"
cp "$STAGE/source-report.txt"      "$DEST/$BASE.source-report.txt"
(cd "$DEST" && sha256sum "$BASE.img" "$BASE.dtb" "$BASE.Image.gz" "$BASE.config" \
  "$BASE.System.map" "$BASE.modules.tar.zst" "$BASE.kernel-info.txt" \
  "$BASE.kernel-cmdline.txt" "$BASE.source-report.txt" > "$BASE.SHA256SUMS")

# Publish the module set separately, keyed by source sha and release.
MOD_PATH="$MODULE_CACHE/$SOURCE_SHA/$KREL"
mkdir -p "$MOD_PATH"
cp "$STAGE/$ARCHIVE" "$MOD_PATH/$ARCHIVE.tmp"
mv -f "$MOD_PATH/$ARCHIVE.tmp" "$MOD_PATH/$ARCHIVE"

# Publish the checkpoint.
rm -rf "$PREV"
if [ -d "$CHECKPOINT" ]; then mv "$CHECKPOINT" "$PREV"; fi
if ! mv "$STAGE" "$CHECKPOINT"; then
  if [ -d "$PREV" ]; then mv "$PREV" "$CHECKPOINT"; fi
  die 'Failed to publish the kernel checkpoint.'
fi
rm -rf "$PREV"
printf '%s\n' "$MOD_PATH/$ARCHIVE" > "$MODULE_CACHE/current.txt"

say "Kernel ready: $DEST/$BASE.img"
say "Modules: $MOD_PATH/$ARCHIVE"
say 'Cache preserved: next rootfs builds reuse modules without recompiling.'
ccache --show-stats
