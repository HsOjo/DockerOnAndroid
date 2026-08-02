#!/bin/sh
# build-pasta.sh: build the patched pasta binary ON the device (musl toolchain)
# and drop it into rootfs/. Set PROXY if the device needs one to reach the net.
set -e
cd "$(dirname "$0")"

TAG=2026_07_28.f8df3f1
PROXY=${PROXY:-}

[ -n "$PROXY" ] && export https_proxy="$PROXY" http_proxy="$PROXY"
command -v git >/dev/null 2>&1 || apk add git
command -v make >/dev/null 2>&1 || apk add make gcc musl-dev linux-headers
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
