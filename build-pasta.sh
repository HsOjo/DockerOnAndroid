#!/bin/sh
# build-pasta.sh: rebuild the patched pasta binary on the LoA device and
# pull it back into rootfs/. The whole build happens on-device (musl toolchain).
set -e
cd "$(dirname "$0")"

TARGET=${TARGET:?set TARGET, e.g. TARGET=root@<device-ip> ./build-pasta.sh}
SSH=${SSH:-ssh -o StrictHostKeyChecking=no}
SCP=${SCP:-scp -o StrictHostKeyChecking=no}
TAG=2026_07_28.f8df3f1
PROXY=${PROXY:-}

$SCP patches/passt/android-compat.patch "$TARGET:/tmp/android-compat.patch"
$SSH "$TARGET" "[ -n '$PROXY' ] && export https_proxy='$PROXY' http_proxy='$PROXY'; set -e
  command -v git >/dev/null 2>&1 || apk add git
  command -v make >/dev/null 2>&1 || apk add make gcc musl-dev linux-headers
  if [ ! -d /root/passt-src/.git ]; then
    rm -rf /root/passt-src
    git clone https://passt.top/passt /root/passt-src
  fi
  cd /root/passt-src
  git fetch --tags
  git checkout -f $TAG
  git apply --check /tmp/android-compat.patch && git apply /tmp/android-compat.patch
  make pasta"
$SCP "$TARGET:/root/passt-src/pasta" rootfs/usr/local/bin/pasta
echo "built: rootfs/usr/local/bin/pasta (passt $TAG + android-compat.patch)"
