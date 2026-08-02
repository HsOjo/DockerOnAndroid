#!/bin/sh
# build-pasta.sh: build the patched pasta binary ON the device (musl toolchain)
# and drop it into rootfs/. Set PROXY if the device needs one to reach the net.
set -e
cd "$(dirname "$0")"

TAG=2026_07_28.f8df3f1
PROXY=${PROXY:-}

install_deps() {
  if command -v apk >/dev/null 2>&1; then
    apk add git make gcc musl-dev linux-headers
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update && apt-get install -y git make gcc linux-libc-dev
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y git make gcc kernel-headers
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm git make gcc linux-api-headers
  else
    echo "error: no supported package manager (apk/apt-get/dnf/pacman)" >&2; exit 1
  fi
}

[ -n "$PROXY" ] && export https_proxy="$PROXY" http_proxy="$PROXY"
if ! command -v git >/dev/null 2>&1 || ! command -v make >/dev/null 2>&1 || ! command -v cc >/dev/null 2>&1; then
  install_deps
fi
if [ ! -d passt-src/.git ]; then
  rm -rf passt-src
  git clone https://passt.top/passt passt-src
fi
cd passt-src
git fetch --tags
git checkout -f "$TAG"
git apply --check ../patches/passt/android-compat.patch && git apply ../patches/passt/android-compat.patch
make pasta
cp pasta ../rootfs/usr/local/bin/pasta
echo "built: rootfs/usr/local/bin/pasta (passt $TAG + android-compat.patch)"
