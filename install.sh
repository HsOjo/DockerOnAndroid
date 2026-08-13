#!/bin/sh
# install.sh: deploy the DockerOnAndroid pasta stack per ./configure's
# config.env. Reconciles existing state: wraps podman only when this config
# needs it, restores *.real otherwise (configure changes just work).
set -e
cd "$(dirname "$0")"

[ -f config.env ] || { echo "error: config.env missing; run ./configure first" >&2; exit 1; }
# shellcheck source=/dev/null
. ./config.env

MANIFEST=/etc/dockeronandroid.manifest

if [ -d /usr/libexec/podman ]; then LIBEXEC=/usr/libexec/podman
elif [ -d /usr/lib/podman ]; then LIBEXEC=/usr/lib/podman
else echo "error: podman libexec dir not found (tried /usr/libexec/podman, /usr/lib/podman)" >&2; exit 1
fi

is_wrapper() { grep -q DockerOnAndroid "$1" 2>/dev/null; }

pkg_install() {
  if command -v apk >/dev/null 2>&1; then apk add "$@"
  elif command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y "$@"
  elif command -v dnf >/dev/null 2>&1; then dnf install -y "$@"
  elif command -v pacman >/dev/null 2>&1; then pacman -Sy --noconfirm "$@"
  else echo "error: no supported package manager (apk/apt-get/dnf/pacman)" >&2; exit 1
  fi
}

if ! command -v jq >/dev/null 2>&1; then
  echo "> installing jq (required by the netavark shim / crun-nomq)"
  pkg_install jq
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "> installing podman-docker (docker CLI shim; also enables 'docker compose' via the podman socket)"
  pkg_install podman-docker
fi

if [ "$STORAGE_DRIVER" = fuse-overlayfs ] && ! command -v fuse-overlayfs >/dev/null 2>&1; then
  echo "> installing fuse-overlayfs (no kernel overlayfs; vfs does a full-tree copy per layer)"
  pkg_install fuse-overlayfs
fi

# wrap binaries this config needs; restore ones it doesn't (pristine > wrapper)
WRAPPED=""
reconcile() {
  b=$1 want=$2 src=$3
  if [ "$want" = 1 ]; then
    if [ -f "$b.real" ]; then
      if is_wrapper "$b.real"; then
        echo "error: $b.real is itself a DoA wrapper; restore pristine binaries first" >&2; exit 1
      fi
    elif is_wrapper "$b"; then
      : # already wrapped, backup in place
    else
      cp "$b" "$b.real"
    fi
    install_file "$src" "$b"
    chmod 755 "$b"
    WRAPPED="$WRAPPED $b"
  elif is_wrapper "$b" && [ -f "$b.real" ]; then
    echo "< restore $b (no longer wrapped)"
    mv -f "$b.real" "$b"
  fi
}

# sidestep ETXTBSY on running binaries: copy aside, then atomic rename
install_file() {
  echo "> $2"
  cp "$1" /.doa-install.tmp
  mv /.doa-install.tmp "$2"
}

FILES=""
[ -f rootfs/usr/local/bin/pasta ] || { echo "error: rootfs/usr/local/bin/pasta missing; run ./build-pasta.sh" >&2; exit 1; }
if [ "$CRUN_PATCH" = 1 ] && [ ! -f rootfs/usr/bin/crun-doa ]; then
  echo "error: rootfs/usr/bin/crun-doa missing; run ./build-crun.sh" >&2; exit 1
fi
reconcile /usr/bin/podman "$PODMAN_WRAPPER" rootfs/usr/bin/podman
reconcile /usr/bin/conmon 1 rootfs/usr/bin/conmon
reconcile "$LIBEXEC/netavark" 1 rootfs/usr/libexec/podman/netavark
reconcile /usr/bin/crun "$CRUN_PATCH" rootfs/usr/bin/crun-doa
install_file rootfs/usr/local/bin/pasta /usr/local/bin/pasta
chmod 755 /usr/local/bin/pasta
FILES="$FILES /usr/local/bin/pasta"

if [ "$CRUN_NOMQ" = 1 ]; then
  install_file rootfs/usr/local/bin/crun-nomq /usr/local/bin/crun-nomq
  install_file rootfs/usr/local/lib/crun-nomq.jq /usr/local/lib/crun-nomq.jq
  mkdir -p /usr/local/share/doa
  install_file rootfs/usr/local/share/doa/apt-sandbox.conf /usr/local/share/doa/apt-sandbox.conf
  chmod 755 /usr/local/bin/crun-nomq
  FILES="$FILES /usr/local/bin/crun-nomq /usr/local/lib/crun-nomq.jq /usr/local/share/doa/apt-sandbox.conf"
else
  rm -f /usr/local/bin/crun-nomq /usr/local/lib/crun-nomq.jq /usr/local/share/doa/apt-sandbox.conf
fi

if [ "$LO_FIX" = 1 ]; then
  install_file rootfs/etc/network/interfaces /etc/network/interfaces
  FILES="$FILES /etc/network/interfaces"
fi

if [ "$CGROUP_FIX" = 1 ]; then
  if command -v rc-update >/dev/null 2>&1; then
    install_file rootfs/etc/init.d/doa-cgroups /etc/init.d/doa-cgroups
    chmod 755 /etc/init.d/doa-cgroups
    rc-update add doa-cgroups boot
    rc-service doa-cgroups start
    FILES="$FILES /etc/init.d/doa-cgroups"
  else
    echo "warn: cgroup v1 not mounted and no openrc; containers will fail until /sys/fs/cgroup is mounted" >&2
  fi
else
  rc-update del doa-cgroups 2>/dev/null || true
  rm -f /etc/init.d/doa-cgroups
fi

if [ "$TS_FIX" = 1 ]; then
  # no /proc/thread-self: podman.real is binary-patched to resolve thread
  # paths via /run/doa-ts, served by the doa-tsd FUSE shim
  install_file rootfs/usr/local/bin/doa-tsd /usr/local/bin/doa-tsd
  chmod 755 /usr/local/bin/doa-tsd
  FILES="$FILES /usr/local/bin/doa-tsd"
  PODB=/usr/bin/podman.real; [ -f "$PODB" ] || PODB=/usr/bin/podman
  if grep -q /run/doa-ts "$PODB" 2>/dev/null; then
    : # already patched
  elif command -v python3 >/dev/null 2>&1 && grep -q /proc/thread-self "$PODB" 2>/dev/null; then
    echo "> patch $PODB (thread-self -> /run/doa-ts)"
    python3 patches/podman/thread-self.py < "$PODB" > /.doa-install.tmp && \
      chmod 755 /.doa-install.tmp && mv /.doa-install.tmp "$PODB"
  else
    echo "warn: cannot binary-patch $PODB (no python3 or no thread-self refs); podman may fail to create netns" >&2
  fi
  if command -v rc-update >/dev/null 2>&1; then
    install_file rootfs/etc/init.d/doa-tsd /etc/init.d/doa-tsd
    chmod 755 /etc/init.d/doa-tsd
    rc-update add doa-tsd boot
    rc-service doa-tsd start 2>/dev/null || true
    FILES="$FILES /etc/init.d/doa-tsd"
  else
    echo "warn: no openrc; run 'doa-tsd /run/doa-ts' before podman or containers will fail" >&2
  fi
else
  rc-update del doa-tsd 2>/dev/null || true
  rc-service doa-tsd stop 2>/dev/null || true
  rm -f /etc/init.d/doa-tsd /usr/local/bin/doa-tsd
fi

# podman schedules container healthchecks via systemd transient timers; without
# systemd they never run, containers stay "starting" and compose hangs on
# depends_on: service_healthy. doa-healthcheckd replicates the scheduling.
install_file rootfs/usr/local/bin/doa-healthcheckd /usr/local/bin/doa-healthcheckd
chmod 755 /usr/local/bin/doa-healthcheckd
FILES="$FILES /usr/local/bin/doa-healthcheckd"
if command -v rc-update >/dev/null 2>&1; then
  install_file rootfs/etc/init.d/doa-healthcheckd /etc/init.d/doa-healthcheckd
  chmod 755 /etc/init.d/doa-healthcheckd
  rc-update add doa-healthcheckd default
  rc-service doa-healthcheckd start 2>/dev/null || true
  FILES="$FILES /etc/init.d/doa-healthcheckd"
else
  echo "warn: no openrc; run 'doa-healthcheckd &' after podman starts or healthchecks will never fire" >&2
fi

# Android kernels fail podman's native-diff probe even though overlay mounts
# work, forcing slow userspace layer commits; no-op the probe (aarch64 only,
# no change if the probe is not found)
PODB=/usr/bin/podman.real; [ -f "$PODB" ] || PODB=/usr/bin/podman
if command -v python3 >/dev/null 2>&1; then
  echo "> patch $PODB (force native overlay diff)"
  python3 patches/podman/naive-diff.py < "$PODB" > /.doa-install.tmp && \
    chmod 755 /.doa-install.tmp && mv /.doa-install.tmp "$PODB"
else
  echo "warn: cannot binary-patch $PODB (no python3); layer commits will use slow naive diff" >&2
fi

# back up a pre-existing non-DoA config once before overwriting it
backup_conf() {
  if [ -f "$1" ] && ! grep -q DockerOnAndroid "$1" 2>/dev/null && [ ! -f "$1.doa-bak" ]; then
    cp "$1" "$1.doa-bak"
  fi
}

# generate configs from the rootfs templates per probe results
RUNTIME=crun
[ "$CRUN_NOMQ" = 1 ] && RUNTIME=/usr/local/bin/crun-nomq
# podman >= 5.5 builds the pod infra rootfs via rootfs-overlay, which needs
# overlayfs; pinning infra_image keeps pods on the image (vfs) path instead
INFRA_IMAGE=$(podman images --noheading --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep '^localhost/podman-pause:' | head -1)
INFRASED='s|^#infra_image = .*|infra_image = ""|'
[ -n "$INFRA_IMAGE" ] && INFRASED="s|^#infra_image = .*|infra_image = \"$INFRA_IMAGE\"|"
backup_conf /etc/containers/containers.conf
{ echo "# DockerOnAndroid: generated by install.sh from config.env"
  sed -e "s/^ipcns = .*/ipcns = \"$IPCNS\"/" \
      -e "s/^pidns = .*/pidns = \"$PIDNS\"/" \
      -e "s/^utsns = .*/utsns = \"$UTSNS\"/" \
      -e "s|^runtime = .*|runtime = \"$RUNTIME\"|" \
      -e "$INFRASED" \
      rootfs/etc/containers/containers.conf; } > /.doa-conf.tmp
echo "> etc/containers/containers.conf (runtime=$RUNTIME ipcns=$IPCNS pidns=$PIDNS utsns=$UTSNS infra_image=${INFRA_IMAGE:-none})"
[ -n "$INFRA_IMAGE" ] || echo "warn: no localhost/podman-pause image; pods need one on podman >= 5.5 (rootfs-overlay requires overlayfs)" >&2
mv /.doa-conf.tmp /etc/containers/containers.conf

backup_conf /etc/containers/storage.conf
DRIVER=$STORAGE_DRIVER
[ "$DRIVER" = fuse-overlayfs ] && DRIVER=overlay
{ echo "# DockerOnAndroid: generated by install.sh from config.env"
  sed "s/^driver = .*/driver = \"$DRIVER\"/" rootfs/etc/containers/storage.conf
  if [ "$STORAGE_DRIVER" = fuse-overlayfs ]; then
    echo
    echo "[storage.options.overlay]"
    echo "mount_program = \"$(command -v fuse-overlayfs)\""
  fi
} > /.doa-conf.tmp
VIA=
[ "$STORAGE_DRIVER" != "$DRIVER" ] && VIA=" via $STORAGE_DRIVER"
echo "> etc/containers/storage.conf (driver=$DRIVER$VIA)"
mv /.doa-conf.tmp /etc/containers/storage.conf
FILES="$FILES /etc/containers/containers.conf /etc/containers/storage.conf"

{ echo "WRAPPED=\"${WRAPPED# }\""; echo "FILES=\"${FILES# }\""; } > "$MANIFEST"
echo "> manifest: $MANIFEST"

have=$(podman info --format '{{.Store.GraphDriverName}}' 2>/dev/null || true)
if [ -n "$have" ] && [ "$have" != "$DRIVER" ]; then
  echo "warn: storage DB still uses \"$have\"; wipe /var/lib/containers/storage to switch to $DRIVER" >&2
fi
echo "done. check: podman ps"
