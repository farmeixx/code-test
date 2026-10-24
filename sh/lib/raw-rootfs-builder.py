#!/usr/bin/env python3
"""Adapt a COPY of current device rootfs builder to a fixed local ext4 size.
Never touch the sources, kernel, firmware, USB, SSH or network configuration.
Reject unrecognized upstream versions rather than silently using old sizes.
Upstream builders on the rootfs branch already use fixed sizes and full
free-space metadata; this layer keeps them and only removes the final zstd
compression so the local result stays a raw ext4 image.
"""
from pathlib import Path
import re
import sys

if len(sys.argv) != 5:
    raise SystemExit('Usage: raw-rootfs-builder.py SOURCE DEST alpine|debian|ubuntu channel|sanders')
source, dest = Path(sys.argv[1]), Path(sys.argv[2])
distro, device = sys.argv[3:5]
if distro not in ('alpine', 'debian', 'ubuntu') or device not in ('channel', 'sanders'):
    raise SystemExit('Unknown distro/device')
body = source.read_text()

SIZE_MIB = 1024
if distro == 'alpine':
    originals = ('IMAGE_MB=1024', 'MIN_FREE_MB=32')
    free_mib, inodes, journal_mib = 32, 16384, 8
else:
    originals = ('IMAGE_MB=1024', 'MIN_FREE_MB=64')
    free_mib, inodes, journal_mib = 64, 32768, 16
for sentinel in originals:
    if body.count(sentinel) != 1:
        raise SystemExit(f'Unknown upstream image policy: {sentinel!r} in {source}')

for key in ('image_size_mib', 'image_free_mib', 'image_min_free_mib', 'staged_rootfs_mib'):
    if f'echo "{key}=$' not in body:
        raise SystemExit(f'Missing existing free-space metadata: {key}')

begin = "USED_MB=\"$(sudo du -sm \"$ROOTFS\" | awk '{print $1}')\""
compression = 'zstd -T0 -10 -f "$ROOTFS_IMG" -o "$ROOTFS_IMG.zst"\nrm -f "$ROOTFS_IMG"'
if body.count(begin) != 1 or body.count(compression) != 1:
    raise SystemExit('Cannot safely identify filesystem creation/compression section')
a = body.index(begin)
b = body.index(compression)
if b <= a:
    raise SystemExit('Unexpected rootfs builder order')

policy = '''USED_MB="$(sudo du -sm "$ROOTFS" | awk '{print $1}')"
IMAGE_MB=__SIZE__
MIN_FREE_MB=__FREE__
echo "__DISTRO__: staged ${USED_MB} MiB; target ${IMAGE_MB} MiB; required free ${MIN_FREE_MB} MiB"
ROOTFS_IMG="$OUT_DIR/__DISTRO__-__DEVICE__-rootfs.ext4"
truncate -s "${IMAGE_MB}M" "$ROOTFS_IMG"
# Fixed inode budget and journal; mkfs -d populates from the real staged rootfs.
sudo mkfs.ext4 -F -m 0 -N __INODES__ -J size=__JOURNAL__ -L "$ROOTFS_LABEL" -U random -d "$ROOTFS" "$ROOTFS_IMG"
test "$(stat -c %s "$ROOTFS_IMG")" -eq $((IMAGE_MB * 1024 * 1024))
ROOTFS_EXT4_UUID="$(blkid -p -o value -s UUID "$ROOTFS_IMG")"
test -n "$ROOTFS_EXT4_UUID"
sudo e2fsck -fn "$ROOTFS_IMG"
test "$(blkid -p -o value -s LABEL "$ROOTFS_IMG")" = "$ROOTFS_LABEL"
FS_STATS="$(sudo tune2fs -l "$ROOTFS_IMG")"
FREE_BLOCKS="$(printf '%s\\n' "$FS_STATS" | awk -F: '$1 == "Free blocks" {gsub(/[[:space:]]/, "", $2); print $2}')"
BLOCK_SIZE="$(printf '%s\\n' "$FS_STATS" | awk -F: '$1 == "Block size" {gsub(/[[:space:]]/, "", $2); print $2}')"
[[ "$FREE_BLOCKS" =~ ^[0-9]+$ && "$BLOCK_SIZE" =~ ^[0-9]+$ ]] || {
  echo 'ERROR: Cannot inspect ext4 free-space metadata' >&2
  exit 1
}
FREE_MB=$((FREE_BLOCKS * BLOCK_SIZE / 1024 / 1024))
echo "__DISTRO__: ext4 ${IMAGE_MB} MiB total, ${FREE_MB} MiB free"
if [ "$FREE_MB" -lt "$MIN_FREE_MB" ]; then
  echo "ERROR: __DISTRO__ would leave only ${FREE_MB} MiB free; need ${MIN_FREE_MB} MiB." >&2
  echo 'Refusing to publish a nearly-full filesystem.' >&2
  exit 1
fi
# Retain raw ext4; no zstd output.
test -s "$ROOTFS_IMG"
'''
for src, dst in [('__DISTRO__', distro), ('__DEVICE__', device), ('__SIZE__', str(SIZE_MIB)),
                 ('__FREE__', str(free_mib)), ('__INODES__', str(inodes)), ('__JOURNAL__', str(journal_mib))]:
    policy = policy.replace(src, dst)
body = body[:a] + policy + body[b + len(compression):]

# The fixed-size check above replaces upstream's staging/free logic; the
# existing metadata echoes downstream stay as the authority for the checks
# performed by the local rootfs runner.
old_hash = f'sha256sum {distro}-{device}-rootfs.ext4.zst build-info.txt > SHA256SUMS.{distro}'
new_hash = f'sha256sum {distro}-{device}-rootfs.ext4 build-info.txt > SHA256SUMS.{distro}'
if body.count(old_hash) != 1:
    raise SystemExit('Unexpected source SHA256SUMS layout in ' + str(source))
body = body.replace(old_hash, new_hash)
body = re.sub(r'echo "::group::Create[^\n"]*ext4[^\n"]*"',
              f'echo "::group::Create {SIZE_MIB} MiB {distro} ext4 rootfs (raw)"', body, count=1)

dest.parent.mkdir(parents=True, exist_ok=True)
dest.write_text(body)
dest.chmod(0o755)
print(f'{device}/{distro}: {SIZE_MIB} MiB raw ext4 (fixed), minimum {free_mib} MiB free')
