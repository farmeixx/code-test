#!/usr/bin/env bash
# Generic kernel builder: source, fragments, DTB and options are from mainline.conf.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "${KERNEL_MAINLINE_CONF:-$ROOT/conf/mainline.conf}"
: "${KERNEL_DIR:?set KERNEL_DIR}"
: "${OUT_DIR:?set OUT_DIR}"
: "${KERNEL_ARCH:?set KERNEL_ARCH}"
: "${KERNEL_CROSS_COMPILE:?set KERNEL_CROSS_COMPILE}"
: "${KERNEL_BASE_CONFIG:?set KERNEL_BASE_CONFIG}"
: "${KERNEL_DTB:?set KERNEL_DTB}"
: "${KERNEL_IMAGE_TARGET:?set KERNEL_IMAGE_TARGET}"
: "${KERNEL_IMAGE_PATH:?set KERNEL_IMAGE_PATH}"

JOBS="${JOBS:-$(nproc)}"
mkdir -p "$OUT_DIR"
cd "$KERNEL_DIR"
MAKE=(make ARCH="$KERNEL_ARCH" CROSS_COMPILE="$KERNEL_CROSS_COMPILE")

"${MAKE[@]}" "$KERNEL_BASE_CONFIG"
fragments=()
for fragment in "${KERNEL_CONFIG_1:-}" "${KERNEL_CONFIG_2:-}"; do
  [ -n "$fragment" ] || continue
  if [[ "$fragment" == repo:* ]]; then
    resolved="$ROOT/${fragment#repo:}"
  elif [[ "$fragment" = /* ]]; then
    resolved="$fragment"
  else
    resolved="$KERNEL_DIR/$fragment"
  fi
  fragments+=("$resolved")
done
if [ "${#fragments[@]}" -gt 0 ]; then
  ARCH="$KERNEL_ARCH" CROSS_COMPILE="$KERNEL_CROSS_COMPILE" \
    bash scripts/kconfig/merge_config.sh -m .config "${fragments[@]}"
fi
for sym in "${KERNEL_ENABLE_Y[@]}"; do scripts/config --enable "${sym#CONFIG_}"; done
for sym in "${KERNEL_ENABLE_M[@]}"; do scripts/config --module "${sym#CONFIG_}"; done

# Label re-assertion after the merge: scripts/config writes the final two
# lines into .config, so the built release is exactly the KERNEL_LOCALVERSION
# exported by the local builder (from conf/kernel.conf), with
# CONFIG_LOCALVERSION_AUTO off and an empty LOCALVERSION env so tagless
# shallow clones can never append a git -g suffix. olddefconfig resolves it.
if [ -n "${KERNEL_LOCALVERSION:-}" ]; then
  scripts/config --set-str CONFIG_LOCALVERSION "$KERNEL_LOCALVERSION"
  scripts/config --disable CONFIG_LOCALVERSION_AUTO
  export LOCALVERSION=""
fi
"${MAKE[@]}" olddefconfig

# Regenerate the generated config state before the release computation:
# setlocalversion reads include/config/auto.conf, so a stale one could still
# carry CONFIG_LOCALVERSION_AUTO=y with an old label. Deleting the files
# forces syncconfig to rebuild them from the current .config.
rm -f include/config/auto.conf include/config/auto.conf.cmd include/config/kernel.release
"${MAKE[@]}" syncconfig

KREL="$("${MAKE[@]}" -s kernelrelease)"

"${MAKE[@]}" -j"$JOBS" KERNELRELEASE="$KREL" "$KERNEL_IMAGE_TARGET" dtbs modules

DTB_BASENAME="${KERNEL_DTB##*/}"
cp "$KERNEL_IMAGE_PATH" "$OUT_DIR/Image.gz"
cp "$KERNEL_IMAGE_PATH" "$OUT_DIR/Image.gz-$KREL"
cp "$KERNEL_DTB" "$OUT_DIR/$DTB_BASENAME"
if [ -n "${KERNEL_DTB_POSTPROCESS:-}" ]; then
  case "$KERNEL_DTB_POSTPROCESS" in
    repo:*) postprocess="$ROOT/${KERNEL_DTB_POSTPROCESS#repo:}" ;;
    /*) postprocess="$KERNEL_DTB_POSTPROCESS" ;;
    *) postprocess="$KERNEL_DIR/$KERNEL_DTB_POSTPROCESS" ;;
  esac
  bash "$postprocess" "$OUT_DIR/$DTB_BASENAME"
fi
cp .config "$OUT_DIR/kernel.config"
cp System.map "$OUT_DIR/System.map"
printf '%s\n' "$KREL" > "$OUT_DIR/kernel-release.txt"
git rev-parse HEAD > "$OUT_DIR/kernel-git-revision.txt"
cat "$OUT_DIR/Image.gz" "$OUT_DIR/$DTB_BASENAME" > "$OUT_DIR/Image.gz-dtb"

for idx in "${!fragments[@]}"; do
  cp "${fragments[$idx]}" "$OUT_DIR/config-fragment-$((idx + 1)).config"
done

rm -rf "$OUT_DIR/modules-root"
mkdir -p "$OUT_DIR/modules-root"
"${MAKE[@]}" KERNELRELEASE="$KREL" INSTALL_MOD_PATH="$OUT_DIR/modules-root" modules_install
tar -I 'zstd -T0 -10' -cf "$OUT_DIR/${MODULES_ARCHIVE_BASE:-kernel-modules}-$KREL.tar.zst" \
  -C "$OUT_DIR/modules-root" lib/modules
rm -rf "$OUT_DIR/modules-root"

{
  printf 'kernel_release=%s\nkernel_git_revision=%s\narchitecture=%s\ndtb=%s\n' \
    "$KREL" "$(git rev-parse HEAD)" "$KERNEL_ARCH" "$DTB_BASENAME"
} > "$OUT_DIR/kernel-info.txt"
if [ -n "${GITHUB_ENV:-}" ]; then
  printf 'KERNEL_RELEASE=%s\n' "$KREL" >> "$GITHUB_ENV"
fi
