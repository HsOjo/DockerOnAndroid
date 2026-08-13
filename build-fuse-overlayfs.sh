#!/bin/sh
# build-fuse-overlayfs.sh: build the patched fuse-overlayfs binary ON the
# device and drop it into rootfs/. Only needed when ./configure reports
# FOV_PATCH=1 (kernel without renameat2 - every rename inside a container
# returns ENOSYS otherwise, breaking apt, corepack, ...). Set PROXY if the
# device needs one to reach the net.
set -e
cd "$(dirname "$0")"

TAG=v1.16
PROXY=${PROXY:-}

install_deps() {
  if command -v apk >/dev/null 2>&1; then
    apk add git build-base autoconf automake libtool fuse3-dev
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update && apt-get install -y git build-essential autoconf automake libtool libfuse3-dev
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y git gcc make autoconf automake libtool fuse3-devel
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm git base-devel autoconf automake libtool fuse3
  else
    echo "error: no supported package manager (apk/apt-get/dnf/pacman)" >&2; exit 1
  fi
}

[ -n "$PROXY" ] && export https_proxy="$PROXY" http_proxy="$PROXY"
# always install: package managers are no-ops on already-installed packages
install_deps
if [ ! -d fuse-overlayfs-src/.git ]; then
  rm -rf fuse-overlayfs-src
  git clone https://github.com/containers/fuse-overlayfs.git fuse-overlayfs-src
fi
cd fuse-overlayfs-src
git fetch --tags
git checkout -f "$TAG"
git apply --check ../patches/fuse-overlayfs/renameat2-fallback.patch && git apply ../patches/fuse-overlayfs/renameat2-fallback.patch
[ -x configure ] || ./autogen.sh
[ -f Makefile ] || ./configure
make -j"$(nproc)"
cp fuse-overlayfs ../rootfs/usr/bin/fuse-overlayfs-doa
echo "built: rootfs/usr/bin/fuse-overlayfs-doa (fuse-overlayfs $TAG + renameat2-fallback.patch)"
