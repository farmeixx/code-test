#!/usr/bin/env bash
# Host-side dependencies copied from the existing Ubuntu 24.04 workflow steps.
set -euo pipefail

#------------------------------------------------------------------#

# Ubuntu on WSL may install qemu-user-static without activating its binfmt
# registration.  Register only the aarch64 interpreter; do not restart the
# global systemd-binfmt service (which can disrupt WSLInterop).
ensure_aarch64_binfmt() {
  local binfmt_dir="${BINFMT_MISC_DIR:-/proc/sys/fs/binfmt_misc}"
  local entry="$binfmt_dir/qemu-aarch64"
  test -x /usr/bin/qemu-aarch64-static || {
    echo 'ERROR: /usr/bin/qemu-aarch64-static not installed.' >&2
    return 1
  }
  if ! test -e "$binfmt_dir/register"; then
    sudo mount -t binfmt_misc binfmt_misc "$binfmt_dir" || {
      echo 'ERROR: binfmt_misc could not be mounted. WSL2 or a Linux host with binfmt_misc is required.' >&2
      return 1
    }
  fi
  if ! test -e "$entry"; then
    # Linux binfmt_misc rule: AArch64 ELF binaries, static QEMU interpreter.
    # F (fix-binary) allows transparent execution inside an arm64 chroot.
    local rule=':qemu-aarch64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-aarch64-static:F'
    printf '%s\n' "$rule" | sudo tee "$binfmt_dir/register" >/dev/null || {
      echo 'ERROR: Unable to register the AArch64 QEMU interpreter with the kernel.' >&2
      return 1
    }
  fi
  if ! grep -qx 'enabled' "$entry"; then
    printf '1\n' | sudo tee "$entry" >/dev/null || {
      echo 'ERROR: Unable to enable the AArch64 QEMU interpreter.' >&2
      return 1
    }
  fi
  grep -qx 'enabled' "$entry" || {
    echo 'ERROR: AArch64 binfmt entry is not enabled.' >&2
    return 1
  }
  grep -Fq 'interpreter /usr/bin/qemu-aarch64-static' "$entry" || {
    # A separately configured interpreter is also acceptable if already live.
    grep -Fq 'interpreter ' "$entry" || return 1
  }
  echo 'QEMU AArch64 binfmt is enabled.'
}

#------------------------------------------------------------------#

install_host_deps() {
  local profile="${1:?profile required}"
  if [ "$(uname -s)" != Linux ] || [ "$(uname -m)" != x86_64 ]; then
    echo 'ERROR: This ZIP currently supports an x86_64 Linux host (Ubuntu/Debian).' >&2
    return 1
  fi
  if ! command -v apt-get >/dev/null || ! command -v dpkg >/dev/null; then
    echo 'ERROR: apt-get/dpkg required (Ubuntu/Debian build host).' >&2
    return 1
  fi
  command -v sudo >/dev/null || { echo 'ERROR: sudo is required.' >&2; return 1; }
  # Request sudo credentials first, rather than after a long download.
  sudo -v
  local packages=(git ca-certificates curl)
  case "$profile" in
    kernel)
      # Native host gcc belongs to this profile beside the cross compiler:
      # kbuild HOSTCC compiles scripts/basic/fixdep and the kconfig host
      # tools with the native compiler before any arm64 source is touched,
      # and fresh Debian/Ubuntu hosts ship without gcc installed, which
      # made the run die at the very first HOSTCC (Error 127).
      packages+=(make bc bison flex ccache gcc gcc-aarch64-linux-gnu
        libc6-dev-arm64-cross libc6-arm64-cross linux-libc-dev-arm64-cross
        device-tree-compiler libssl-dev libelf-dev dwarves python3 gzip zstd file)
      ;;
    alpine|debian|ubuntu)
      packages+=(rsync cpio gzip xz-utils zstd e2fsprogs
        qemu-user-static binfmt-support openssh-client openssl
        kmod file device-tree-compiler)
      if [ "$profile" != alpine ]; then packages+=(arch-test); fi
      if [ "$profile" = debian ]; then packages+=(mmdebstrap); fi
      ;;
    *) echo "Unknown dependency profile: $profile" >&2; return 2;;
  esac
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends "${packages[@]}"
  if [ "$profile" != kernel ]; then
    ensure_aarch64_binfmt
    if [ "$profile" != alpine ]; then arch-test arm64; fi
  fi
  if [ "$profile" = debian ]; then
    # Retain the exact keyring download and SHA-256 pin from debian.yml.
    local keyring_file='/tmp/debian-archive-keyring_2025.1_all.deb'
    curl -fsSL --retry 3 \
      'https://deb.debian.org/debian/pool/main/d/debian-archive-keyring/debian-archive-keyring_2025.1_all.deb' \
      -o "$keyring_file"
    printf '%s  %s\n' \
      '9ea7778e443144ca490668737a8ab22dd3e748bb99e805e22ec055abeb3c7fac' \
      "$keyring_file" | sha256sum -c -
    sudo dpkg -i "$keyring_file"
    test -s /usr/share/keyrings/debian-archive-keyring.gpg
  fi
}
