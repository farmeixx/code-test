#!/usr/bin/env bash
# Self-test for the local builder. Safe on every host: parses every script and
# exercises only printf paths (usage/help/status). Nothing builds, installs,
# clones or compiles.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail=0

echo '== 1) bash -n every script (parse only)'
for f in conf/release.conf conf/modules.conf sh/build.sh sh/status.sh \
         sh/sources/prepare.sh sh/mainline/build.sh sh/mainline/update-source.sh \
         sh/rootfs/alpine.sh sh/rootfs/debian.sh sh/rootfs/ubuntu.sh test.sh; do
  if bash -n "$HERE/$f"; then echo "syntax ok: $f"; else echo "SYNTAX FAIL: $f"; fail=$((fail + 1)); fi
done

echo '== 2) python3 parses the raw-rootfs generator (ast only, never executed)'
# The Microsoft Store python stub satisfies `command -v` but cannot execute;
# require an actual working interpreter before running the parse check.
if command -v python3 >/dev/null 2>&1 && python3 -c 'pass' >/dev/null 2>&1; then
  if python3 -c 'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$HERE/sh/lib/raw-rootfs-builder.py"; then
    echo 'python ok: sh/lib/raw-rootfs-builder.py'
  else
    echo 'PYTHON PARSE FAIL: sh/lib/raw-rootfs-builder.py'; fail=$((fail + 1))
  fi
else
  echo 'python3 not present here: skipping (the real host installs it via apt)'
fi

echo '== 3) sh/build.sh unknown command -> usage, exit 2'
set +e
out="$(bash "$HERE/sh/build.sh" banana 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -q 'LOCAL MAINLINE'; then
  echo "ok: exit=$rc with usage"
else
  echo "FAIL: exit=$rc output: $out"; fail=$((fail + 1))
fi

echo '== 4) sh/build.sh help -> usage, exit 0'
set +e
out="$(bash "$HERE/sh/build.sh" help 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'bash sh/build.sh ubuntu'; then
  echo 'ok: help printed'
else
  echo "FAIL: exit=$rc output: $out"; fail=$((fail + 1))
fi

echo '== 5) rootfs script rejects an argument -> usage, exit 2'
set +e
out="$(bash "$HERE/sh/rootfs/ubuntu.sh" banana 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -q 'Usage: bash sh/rootfs/ubuntu.sh'; then
  echo "ok: exit=$rc with usage"
else
  echo "FAIL: exit=$rc output: $out"; fail=$((fail + 1))
fi

echo '== 6) sh/mainline/build.sh --help -> usage, exit 0'
set +e
out="$(bash "$HERE/sh/mainline/build.sh" --help 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'Usage: bash sh/mainline/build.sh'; then
  echo 'ok: mainline usage printed'
else
  echo "FAIL: exit=$rc output: $out"; fail=$((fail + 1))
fi

echo '== 7) sh/sources/prepare.sh unknown branch -> usage, exit 2'
set +e
out="$(bash "$HERE/sh/sources/prepare.sh" banana 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -q 'Usage: bash sh/sources/prepare.sh'; then
  echo "ok: exit=$rc with usage"
else
  echo "FAIL: exit=$rc output: $out"; fail=$((fail + 1))
fi

echo '== 8) sh/mainline/update-source.sh refuses an argument -> exit 1'
set +e
out="$(bash "$HERE/sh/mainline/update-source.sh" banana 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q 'Usage: bash sh/mainline/update-source.sh'; then
  echo "ok: exit=$rc with usage"
else
  echo "FAIL: exit=$rc output: $out"; fail=$((fail + 1))
fi

echo '== 9) status runs on any host (host independent report)'
set +e
out="$(bash "$HERE/sh/status.sh" 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'Device: channel' && printf '%s\n' "$out" | grep -q 'Kernel pin:' && printf '%s\n' "$out" | grep -q 'Completed images:'; then
  echo 'ok: status printed'
  printf '%s\n' "$out" | head -3
else
  echo "FAIL: exit=$rc output: $out"; fail=$((fail + 1))
fi

echo '== 10) shipped confs parse and resolve one consistent contract'
set +e
out="$(bash -c '
  source "$1/conf/release.conf" || exit 3
  case "$KERNEL_RELEASE" in *"$KERNEL_SUFFIX") ;; *) exit 9;; esac
  source "$1/conf/modules.conf" || exit 4
  [ "$MODULES_ARCHIVE" = "kernel-modules-$KERNEL_RELEASE.tar.zst" ] || exit 8
  [ "$MODULES_TARGET" = "lib/modules/$KERNEL_RELEASE" ] || exit 7
  [ "${#MODULES_REQUIRED[@]}" -gt 0 ] || exit 6
  echo "ok: $KERNEL_RELEASE + $MODULES_ARCHIVE + $MODULES_TARGET + ${#MODULES_REQUIRED[@]} required"
' _ "$HERE" 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^ok: '; then
  echo "ok: $out"
else
  echo "FAIL: exit=$rc output: $out"; fail=$((fail + 1))
fi

if [ "$fail" -gt 0 ]; then
  echo "BUILDER SELF-TEST FAILED ($fail failures)"; exit 1
fi
echo 'BUILDER SELF-TEST PASSED'
