#!/bin/sh
# build-crun.sh: build the patched crun binary ON the device and drop it into
# rootfs/. Only needed when ./configure reports CRUN_PATCH=1 (kernel without
# MEMCG, or a broken read-only cpuset - typical on Android-class 3.x/4.x
# kernels). Set PROXY if the device needs one to reach the net.
set -e
cd "$(dirname "$0")"

TAG=1.28
PROXY=${PROXY:-}

install_deps() {
  if command -v apk >/dev/null 2>&1; then
    apk add git build-base autoconf automake libtool python3 \
      libcap-dev yajl-dev libseccomp-dev json-c-dev argp-standalone go-md2man
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update && apt-get install -y git build-essential autoconf automake libtool python3 \
      libcap-dev libyajl-dev libseccomp-dev libjson-c-dev go-md2man
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y git gcc make autoconf automake libtool python3 \
      libcap-devel yajl-devel libseccomp-devel json-c-devel go-md2man
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm git base-devel autoconf automake libtool python \
      libcap yajl libseccomp json-c go-md2man
  else
    echo "error: no supported package manager (apk/apt-get/dnf/pacman)" >&2; exit 1
  fi
}

[ -n "$PROXY" ] && export https_proxy="$PROXY" http_proxy="$PROXY"
if ! command -v git >/dev/null 2>&1 || ! command -v make >/dev/null 2>&1 || ! command -v cc >/dev/null 2>&1; then
  install_deps
fi
if [ ! -d crun-src/.git ]; then
  rm -rf crun-src
  git clone https://github.com/containers/crun.git crun-src
fi
cd crun-src
git fetch --tags
git checkout -f "$TAG"
git apply --check ../patches/crun/android-cgroup.patch && git apply ../patches/crun/android-cgroup.patch
[ -x configure ] || ./autogen.sh
[ -f Makefile ] || ./configure --disable-systemd
make -j"$(nproc)"
cp crun ../rootfs/usr/bin/crun-doa
echo "built: rootfs/usr/bin/crun-doa (crun $TAG + android-cgroup.patch)"
