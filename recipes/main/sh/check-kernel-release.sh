#!/usr/bin/env bash
# Verify the release embedded in Image.gz, not just the checkpoint sidecar.
set -euo pipefail
IMAGE="${1:?Usage: check-kernel-release.sh IMAGE.gz EXPECTED_RELEASE}"
EXPECTED="${2:?Usage: check-kernel-release.sh IMAGE.gz EXPECTED_RELEASE}"
[[ "$EXPECTED" =~ ^[-A-Za-z0-9._+]+$ && "$EXPECTED" != *-dirty ]] || {
  echo "Invalid expected kernel release: $EXPECTED" >&2
  exit 1
}
test -s "$IMAGE" || { echo "Missing kernel image: $IMAGE" >&2; exit 1; }
command -v gzip >/dev/null || { echo "gzip is required to validate the kernel image" >&2; exit 1; }

#------------------------------------------------------------------#

ACTUAL="$(
  gzip -cd -- "$IMAGE" |
    LC_ALL=C tr '\000' '\n' |
    awk '
      $1 == "Linux" && $2 == "version" {
        if (!found) {
          release = $3
          found = 1
        } else if (release != $3) {
          mismatch = 1
        }
      }
      END {
        if (!found || mismatch) exit 1
        print release
      }
    '
)" || {
  echo "Unable to extract one consistent Linux version from $IMAGE" >&2
  exit 1
}
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "KERNEL/IMAGE RELEASE MISMATCH" >&2
  echo "  checkpoint release: $EXPECTED" >&2
  echo "  embedded image release: $ACTUAL" >&2
  exit 1
fi
echo "Verified kernel image release: $ACTUAL"
