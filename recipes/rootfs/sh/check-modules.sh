#!/usr/bin/env bash
# Verify the archive layout and the embedded vermagic of every kernel module.
set -euo pipefail
ARCHIVE="${1:?Usage: check-modules.sh ARCHIVE KERNEL_RELEASE}"
KREL="${2:?Usage: check-modules.sh ARCHIVE KERNEL_RELEASE}"
[[ "$KREL" =~ ^[-A-Za-z0-9._+]+$ && "$KREL" != *-dirty ]] || { echo "Invalid kernel release: $KREL" >&2; exit 1; }
test -s "$ARCHIVE" || { echo "Missing module archive: $ARCHIVE" >&2; exit 1; }
command -v zstd >/dev/null || { echo 'zstd is required for module validation' >&2; exit 1; }

#------------------------------------------------------------------#

ENTRIES="$(tar -I zstd -tf "$ARCHIVE")" || {
  echo "Unable to read module archive: $ARCHIVE" >&2
  exit 1
}
BASE="lib/modules/$KREL"
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  case "$entry" in
    lib|lib/|lib/modules|lib/modules/|"$BASE"|"$BASE/"|"$BASE/"*) ;;
    *)
      echo "Unexpected path in module archive: $entry" >&2
      echo "Expected modules only under $BASE/" >&2
      exit 1
      ;;
  esac
done <<< "$ENTRIES"

#------------------------------------------------------------------#

TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
tar -I zstd -xf "$ARCHIVE" -C "$TEMP"
test -d "$TEMP/$BASE" || {
  echo "Module archive is missing $BASE" >&2
  exit 1
}

module_path() {
  local base="$1" suffix
  for suffix in '' .gz .xz .zst; do
    [ -s "$TEMP/$base$suffix" ] && { printf '%s\n' "$TEMP/$base$suffix"; return 0; }
  done
  return 1
}
for required in \
  "$BASE/kernel/drivers/usb/gadget/libcomposite.ko" \
  "$BASE/kernel/drivers/net/wireless/ath/wcn36xx/wcn36xx.ko"; do
  module_path "$required" >/dev/null || {
    echo "Kernel archive is missing required Channel module: $required" >&2
    exit 1
  }
done

module_vermagic() {
  local module="$1"
  case "$module" in
    *.ko) cat -- "$module" ;;
    *.ko.gz) gzip -cd -- "$module" ;;
    *.ko.xz) xz -cd -- "$module" ;;
    *.ko.zst) zstd -cd -- "$module" ;;
    *) return 2 ;;
  esac |
    LC_ALL=C tr '\000' '\n' |
    awk '
      /^vermagic=/ {
        sub(/^vermagic=/, "")
        if (!found) {
          value = $0
          found = 1
        } else if (value != $0) {
          mismatch = 1
        }
      }
      END {
        if (!found || mismatch) exit 1
        print value
      }
    '
}

#------------------------------------------------------------------#

MODULE_COUNT=0
while IFS= read -r -d '' module; do
  MODULE_COUNT=$((MODULE_COUNT + 1))
  VERMAGIC="$(module_vermagic "$module")" || {
    echo "Missing or unreadable ELF vermagic metadata: $module" >&2
    exit 1
  }
  case "$VERMAGIC" in
    "$KREL "*) ;;
    *)
      echo "KERNEL/ROOTFS RELEASE MISMATCH: $module" >&2
      echo "  checkpoint release: $KREL" >&2
      echo "  embedded vermagic: $VERMAGIC" >&2
      exit 1
      ;;
  esac
done < <(find "$TEMP/$BASE" -type f \( \
  -name '*.ko' -o -name '*.ko.gz' -o -name '*.ko.xz' -o -name '*.ko.zst' \
\) -print0)

if [ "$MODULE_COUNT" -eq 0 ]; then
  echo "No kernel modules found under $BASE" >&2
  exit 1
fi
echo "Verified $MODULE_COUNT module vermagic entries for release $KREL"
