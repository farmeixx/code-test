#!/usr/bin/env bash
# Generic kernel builder: source, fragments, DTB and options are from mainline.conf.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

#------------------------------------------------------------------#

# sh/ui.sh is sourced before the conf so helpers exist even when a
# parameter check aborts the run.
source "$ROOT/sh/ui.sh"
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

#------------------------------------------------------------------#

ui_step "configuring kernel .config from ${KERNEL_BASE_CONFIG} and fragments"
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
  test -s "$resolved" || { echo "Missing config fragment: $resolved" >&2; exit 1; }
  fragments+=("$resolved")
done
if [ "${#fragments[@]}" -gt 0 ]; then
  test -f scripts/kconfig/merge_config.sh || { echo "Missing merge_config.sh" >&2; exit 1; }
  ARCH="$KERNEL_ARCH" CROSS_COMPILE="$KERNEL_CROSS_COMPILE" \
    bash scripts/kconfig/merge_config.sh -m .config "${fragments[@]}"
fi
for sym in "${KERNEL_ENABLE_Y[@]}"; do scripts/config --enable "${sym#CONFIG_}"; done
for sym in "${KERNEL_ENABLE_M[@]}"; do scripts/config --module "${sym#CONFIG_}"; done

# Release pin re-assertion lives after the merge and before the resolver
# pass: scripts/config writes the final two lines into .config directly,
# so the merged CONFIG_LOCALVERSION / CONFIG_LOCALVERSION_AUTO cannot be
# resolved by an older generated state (stale auto.conf with AUTO=y and
# an empty label yielded the git -g suffix in the shipped release). The
# exported LOCALVERSION stays deliberately empty: setlocalversion appends
# the environment value verbatim (a doubled label otherwise), so a
# set-but-empty variable disables the shallow-clone suffix paths
# (+/-g<sha>) on tagless checkouts while the one pinned label still comes
# from CONFIG_LOCALVERSION itself; the olddefconfig pass then resolves
# the asserted file.

if [ -n "${KERNEL_PIN_RELEASE:-}" ]; then
  test -n "${KERNEL_PIN_LOCALVERSION:-}" || {
    echo "KERNEL_PIN_LOCALVERSION missing while KERNEL_PIN_RELEASE is set" >&2
    exit 1
  }
  scripts/config --set-str CONFIG_LOCALVERSION "$KERNEL_PIN_LOCALVERSION"
  scripts/config --disable CONFIG_LOCALVERSION_AUTO
  export LOCALVERSION=""
fi
"${MAKE[@]}" olddefconfig

# Regenerate the generated config state from the merged .config before any
# release computation. Why this exists: run 40174836719 proved .config ends
# up correct (fragment merge + scripts/config + olddefconfig) while the
# release still resolved from the pre-merge generated state, because
# setlocalversion reads include/config/auto.conf and nothing on this path
# re-syncs it; a stale auto.conf carries CONFIG_LOCALVERSION_AUTO=y with an
# empty label, which is exactly the git -g971cba1cb8dd suffix that shipped.
# Deleting the generated files forces syncconfig to rebuild them from the
# current .config on fresh clones and on reused workspaces alike, and the
# greps below refuse to continue when the generated state still misses the
# pin, so a bad release can never reach the compile step again.
rm -f include/config/auto.conf include/config/auto.conf.cmd include/config/kernel.release
"${MAKE[@]}" syncconfig
if grep -q '^CONFIG_LOCALVERSION_AUTO=y$' include/config/auto.conf; then
  echo "auto.conf still enables CONFIG_LOCALVERSION_AUTO after syncconfig" >&2
  exit 1
fi
if [ -n "${KERNEL_PIN_RELEASE:-}" ]; then
  # Quote-tolerant form check: auto.conf stores string symbols in make
  # assignment syntax, which has been observed both ways across kernel
  # releases; accept the quoted and the bare forms and, when the pinned
  # label is missing, print the real lines from both files so the next
  # run's log needs no forensic trip to diagnose itself.
  if ! grep -Fqx "CONFIG_LOCALVERSION=\"$KERNEL_PIN_LOCALVERSION\"" include/config/auto.conf \
     && ! grep -Fqx "CONFIG_LOCALVERSION=$KERNEL_PIN_LOCALVERSION" include/config/auto.conf; then
    { grep -n 'CONFIG_LOCALVERSION' include/config/auto.conf || echo "(auto.conf carries no CONFIG_LOCALVERSION line)"; } >&2
    { grep -n 'CONFIG_LOCALVERSION' .config || echo "(.config carries no CONFIG_LOCALVERSION line)"; } >&2
    echo "auto.conf misses the pinned CONFIG_LOCALVERSION label after syncconfig" >&2
    exit 1
  fi
fi

# Preserve explicit DWC3 gadget/dual-role check from the older builder.
if ! grep -qx 'CONFIG_USB_DWC3_DUAL_ROLE=y' .config &&
   ! grep -qx 'CONFIG_USB_DWC3_GADGET=y' .config; then
  echo "DWC3 has neither gadget nor dual-role mode enabled" >&2
  exit 1
fi

for sym in "${KERNEL_REQUIRE_Y[@]}" "${KERNEL_ENABLE_Y[@]}"; do
  test -n "$sym" || continue
  grep -qx "CONFIG_${sym#CONFIG_}=y" .config || {
    echo "Kernel config needs CONFIG_${sym#CONFIG_}=y" >&2; exit 1;
  }
done
for sym in "${KERNEL_REQUIRE_M[@]}" "${KERNEL_ENABLE_M[@]}"; do
  test -n "$sym" || continue
  grep -qx "CONFIG_${sym#CONFIG_}=m" .config || {
    echo "Kernel config needs CONFIG_${sym#CONFIG_}=m" >&2; exit 1;
  }
done

# Pin one release for compilation and installation. The generated header,
# compressed Image.gz and every installed module are validated against it.
KREL="$("${MAKE[@]}" -s kernelrelease)"
[[ "$KREL" =~ ^[-A-Za-z0-9._+]+$ && "$KREL" != *-dirty ]] || {
  echo "Invalid kernel release: $KREL" >&2
  exit 1
}

# Conf-pin equality assert: the packaged release, the Image/DTB partners
# and every module vermagic must equal the configured pin. Failing here
# costs ten seconds instead of a full rebuild, so validation stays cheap
# on the runner. With no pin declared, the byte-exact KREL convention
# applies as-is (the file checkpoint stays self-consistent either way).

if [ -n "${KERNEL_PIN_RELEASE:-}" ] && [ "$KREL" != "$KERNEL_PIN_RELEASE" ]; then
  echo "Kernel release '$KREL' differs from pinned release '$KERNEL_PIN_RELEASE'" >&2
  exit 1
fi

#------------------------------------------------------------------#

ui_step "compiling ${KERNEL_IMAGE_TARGET}, dtbs and modules in $JOBS jobs"
"${MAKE[@]}" -j"$JOBS" KERNELRELEASE="$KREL" "$KERNEL_IMAGE_TARGET" dtbs modules

# Unlike the old script, also prove the resulting running kernel reports
# exactly the release used to compile and install its .ko modules.

#------------------------------------------------------------------#

ui_step "verifying built outputs"
test -s include/generated/utsrelease.h || {
  echo "Kernel UTS_RELEASE header was not generated" >&2; exit 1;
}
BUILT_RELEASE="$(cut -d '"' -f2 include/generated/utsrelease.h)"
if [ "$BUILT_RELEASE" != "$KREL" ]; then
  echo "Kernel UTS_RELEASE ($BUILT_RELEASE) differs from packaged release ($KREL)" >&2
  exit 1
fi
echo "Verified compiled kernel UTS_RELEASE: $KREL"

test -s "$KERNEL_DTB" || { echo "Missing requested DTB: $KERNEL_DTB" >&2; exit 1; }
test -s "$KERNEL_IMAGE_PATH"
bash "$ROOT/sh/check-kernel-release.sh" "$KERNEL_IMAGE_PATH" "$KREL"
test -s System.map
if [ -n "${KERNEL_DTB_CHECK_NODE:-}" ]; then
  test "$(fdtget -t s "$KERNEL_DTB" "$KERNEL_DTB_CHECK_NODE" "$KERNEL_DTB_CHECK_PROPERTY")" = "$KERNEL_DTB_CHECK_VALUE" || {
    echo "DTB validation failed: $KERNEL_DTB_CHECK_NODE" >&2; exit 1;
  }
fi

#------------------------------------------------------------------#

ui_step "staging kernel files"
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
  test -s "$postprocess" || { echo "DTB postprocess script missing: $postprocess" >&2; exit 1; }
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

#------------------------------------------------------------------#

ui_step "packaging modules into kernel-modules-$KREL.tar.zst"
rm -rf "$OUT_DIR/modules-root"
mkdir -p "$OUT_DIR/modules-root"
"${MAKE[@]}" KERNELRELEASE="$KREL" INSTALL_MOD_PATH="$OUT_DIR/modules-root" modules_install
tar -I 'zstd -T0 -10' -cf "$OUT_DIR/kernel-modules-$KREL.tar.zst" \
  -C "$OUT_DIR/modules-root" lib/modules
bash "$ROOT/sh/check-modules.sh" "$OUT_DIR/kernel-modules-$KREL.tar.zst" "$KREL"
rm -rf "$OUT_DIR/modules-root"
{

#------------------------------------------------------------------#

  printf 'kernel_release=%s\nkernel_git_revision=%s\narchitecture=%s\ndtb=%s\n' \
    "$KREL" "$(git rev-parse HEAD)" "$KERNEL_ARCH" "$DTB_BASENAME"
} > "$OUT_DIR/kernel-info.txt"
if [ -n "${GITHUB_ENV:-}" ]; then
  printf 'KERNEL_RELEASE=%s\n' "$KREL" >> "$GITHUB_ENV"
fi
echo "Kernel release: $KREL"
