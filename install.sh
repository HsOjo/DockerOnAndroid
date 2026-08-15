#!/bin/sh
# install.sh: deploy the DockerOnAndroid pasta stack per ./configure's
# config.env. Reconciles existing state: wraps podman only when this config
# needs it, restores *.real otherwise (configure changes just work).
set -e
cd "$(dirname "$0")"

[ -f config.env ] || { echo "error: config.env missing; run ./configure first" >&2; exit 1; }
# shellcheck source=/dev/null
. ./config.env

# pre-INET_GID/NET_BACKEND config.env: default to the historical behavior
INET_GID=${INET_GID-3003}
NET_BACKEND=${NET_BACKEND:-pasta}

MANIFEST=/etc/dockeronandroid.manifest

is_wrapper() { grep -q DockerOnAndroid "$1" 2>/dev/null; }

pkg_install() {
  if command -v apk >/dev/null 2>&1; then apk add "$@"
  elif command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y "$@"
  elif command -v dnf >/dev/null 2>&1; then dnf install -y "$@"
  elif command -v pacman >/dev/null 2>&1; then pacman -Sy --noconfirm "$@"
  else echo "error: no supported package manager (apk/apt-get/dnf/pacman)" >&2; exit 1
  fi
}

if ! command -v podman >/dev/null 2>&1; then
  echo "> installing podman stack (podman + netavark + aardvark-dns)"
  pkg_install podman netavark aardvark-dns
fi

# python3 powers the podman binary patches and the podman_compose probe below
if ! command -v python3 >/dev/null 2>&1; then
  echo "> installing python3 (required by the podman binary patches)"
  pkg_install python3
fi

# optional compose support; some distros lack a podman-compose package, so a
# failure here only disables the compose provider wrapper below
if ! python3 -c 'import podman_compose' 2>/dev/null; then
  echo "> installing podman-compose (compose provider for 'docker compose')"
  pkg_install podman-compose || echo "warn: podman-compose unavailable; compose support disabled" >&2
fi

if [ -d /usr/libexec/podman ]; then LIBEXEC=/usr/libexec/podman
elif [ -d /usr/lib/podman ]; then LIBEXEC=/usr/lib/podman
else echo "error: podman libexec dir not found (tried /usr/libexec/podman, /usr/lib/podman)" >&2; exit 1
fi

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

# silence podman-docker's "Emulate Docker CLI" banner on every docker call
touch /etc/containers/nodocker
FILES="$FILES /etc/containers/nodocker"

# pasta backend (Android-class kernels) vs native bridge (capable kernels):
# the netavark/conmon wrappers, pasta binary and tun persistence are only
# deployed for pasta; native restores the pristine binaries instead
pasta_want=1
[ "$NET_BACKEND" = pasta ] || pasta_want=0

if [ "$pasta_want" = 1 ]; then
  [ -f rootfs/usr/local/bin/pasta ] || ./build-pasta.sh
fi
if [ "$CRUN_PATCH" = 1 ] && [ ! -f rootfs/usr/bin/crun-doa ]; then
  ./build-crun.sh
fi
if [ "$FOV_PATCH" = 1 ] && [ ! -f rootfs/usr/bin/fuse-overlayfs-doa ]; then
  ./build-fuse-overlayfs.sh
fi
reconcile /usr/bin/podman "$PODMAN_WRAPPER" rootfs/usr/bin/podman
reconcile /usr/bin/conmon "$pasta_want" rootfs/usr/bin/conmon
if [ "$pasta_want" = 1 ]; then
  # the shim is generated, not shipped: @INET_GID@ follows the paranoid-network
  # probe (tun chgrp is skipped where the check is absent; pasta --runas always
  # pins uid 0, egid falls back to 0)
  sed -e "s/@INET_GID_OR_0@/${INET_GID:-0}/g" -e "s/@INET_GID@/$INET_GID/g" \
      rootfs/usr/libexec/podman/netavark > /.doa-conf.tmp
  reconcile "$LIBEXEC/netavark" 1 /.doa-conf.tmp
  rm -f /.doa-conf.tmp
  install_file rootfs/usr/local/bin/pasta /usr/local/bin/pasta
  chmod 755 /usr/local/bin/pasta
  FILES="$FILES /usr/local/bin/pasta"
else
  reconcile "$LIBEXEC/netavark" 0 ""
  rm -f /usr/local/bin/pasta
fi
reconcile /usr/bin/crun "$CRUN_PATCH" rootfs/usr/bin/crun-doa
reconcile /usr/bin/fuse-overlayfs "$FOV_PATCH" rootfs/usr/bin/fuse-overlayfs-doa

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

# back up a pre-existing non-DoA config once before overwriting it
backup_conf() {
  if [ -f "$1" ] && ! grep -q DockerOnAndroid "$1" 2>/dev/null && [ ! -f "$1.doa-bak" ]; then
    cp "$1" "$1.doa-bak"
  fi
}

if [ "$WMEM_FIX" = 1 ]; then
  mkdir -p /etc/sysctl.d
  install_file rootfs/etc/sysctl.d/90-doa-tcp-wmem.conf /etc/sysctl.d/90-doa-tcp-wmem.conf
  # apply now, not just at boot; existing pasta listeners must restart to
  # inherit the new default, which the shim's supervise loop does on its own
  # (config errors exit pasta, the loop relaunches it)
  sysctl -p /etc/sysctl.d/90-doa-tcp-wmem.conf >/dev/null
  FILES="$FILES /etc/sysctl.d/90-doa-tcp-wmem.conf"
else
  rm -f /etc/sysctl.d/90-doa-tcp-wmem.conf
fi

if [ "$LO_FIX" = 1 ]; then
  backup_conf /etc/network/interfaces
  install_file rootfs/etc/network/interfaces /etc/network/interfaces
  FILES="$FILES /etc/network/interfaces"
else
  if [ -f /etc/network/interfaces.doa-bak ]; then mv -f /etc/network/interfaces.doa-bak /etc/network/interfaces
  else rm -f /etc/network/interfaces; fi
fi

# kernel modules per backend: pasta needs /dev/net/tun inside the container
# netns; native bridge needs veth+bridge plus the firewall driver's netfilter
# modules. Persist via modules-load.d (honored by systemd and openrc's
# modules service alike) so networking survives reboots.
if [ "$pasta_want" = 1 ]; then
  grep -q DockerOnAndroid /etc/modules-load.d/doa-native-net.conf 2>/dev/null && rm -f /etc/modules-load.d/doa-native-net.conf
  [ -c /dev/net/tun ] || modprobe tun 2>/dev/null || true
  if [ ! -c /dev/net/tun ]; then
    echo "warn: no /dev/net/tun (kernel TUN unavailable); pasta cannot give containers networking" >&2
  elif ! grep -qs '^tun$' /etc/modules-load.d/tun.conf /etc/modules 2>/dev/null; then
    mkdir -p /etc/modules-load.d
    install_file rootfs/etc/modules-load.d/tun.conf /etc/modules-load.d/tun.conf
    FILES="$FILES /etc/modules-load.d/tun.conf"
  fi
else
  grep -q DockerOnAndroid /etc/modules-load.d/tun.conf 2>/dev/null && rm -f /etc/modules-load.d/tun.conf
  # netavark shells out to the driver's userspace binary at runtime
  if [ "$NET_FWDRIVER" = iptables ]; then
    command -v iptables >/dev/null 2>&1 || pkg_install iptables
    NAT_MODS="ip_tables iptable_nat ip6_tables ip6table_nat"
  else
    command -v nft >/dev/null 2>&1 || pkg_install nftables
    NAT_MODS="nf_tables nf_nat"
  fi
  for m in bridge veth $NAT_MODS; do modprobe "$m" 2>/dev/null; done
  mkdir -p /etc/modules-load.d
  { echo "# DockerOnAndroid: native bridge backend (${NET_FWDRIVER:-nftables})"
    echo bridge; echo veth
    for m in $NAT_MODS; do echo "$m"; done
  } > /.doa-conf.tmp
  install_file /.doa-conf.tmp /etc/modules-load.d/doa-native-net.conf
  FILES="$FILES /etc/modules-load.d/doa-native-net.conf"
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
    # restart (not start): re-running install.sh must pick up a new doa-tsd
    # binary; the remount window is harmless since /run/doa-ts is only
    # resolved at container creation
    rc-service doa-tsd restart 2>/dev/null || true
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
  # restart (not start): install.sh is meant to be re-run after git pull,
  # and a no-op start would leave the old scheduler binary running
  rc-service doa-healthcheckd restart 2>/dev/null || true
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

# podman-compose's attached `up` re-starts already-running containers, which
# crun rejects with a bogus "cannot open exec.fifo" (start -a on a live
# container is an unconditional runtime start upstream). Ship a compose
# provider wrapper that attaches instead, and point compose_providers at it.
COMPOSE_SED=
if python3 -c 'import podman_compose' 2>/dev/null; then
  install_file rootfs/usr/local/bin/podman-compose-doa /usr/local/bin/podman-compose-doa
  chmod 755 /usr/local/bin/podman-compose-doa
  FILES="$FILES /usr/local/bin/podman-compose-doa"
  COMPOSE_SED='s|^#compose_providers=.*|compose_providers = ["/usr/local/bin/podman-compose-doa"]|'
else
  rm -f /usr/local/bin/podman-compose-doa
fi

# generate configs from the rootfs templates per probe results
RUNTIME=crun
[ "$CRUN_NOMQ" = 1 ] && RUNTIME=/usr/local/bin/crun-nomq
# podman >= 5.5 builds the pod infra rootfs via rootfs-overlay, which needs
# overlayfs; pinning infra_image keeps pods on the image (vfs) path instead
INFRA_IMAGE=$(podman images --noheading --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep '^localhost/podman-pause:' | head -1)
INFRASED='s|^#infra_image = .*|infra_image = ""|'
[ -n "$INFRA_IMAGE" ] && INFRASED="s|^#infra_image = .*|infra_image = \"$INFRA_IMAGE\"|"
# native bridge: pin the probed firewall driver or netavark defaults to
# nftables, which fails on kernels without NFT_FIB_INET
FWSED=
[ "$NET_BACKEND" = native ] && FWSED="s|^#firewall_driver = .*|firewall_driver = \"${NET_FWDRIVER:-nftables}\"|"
backup_conf /etc/containers/containers.conf
{ echo "# DockerOnAndroid: generated by install.sh from config.env"
  sed -e "s/^ipcns = .*/ipcns = \"$IPCNS\"/" \
      -e "s/^pidns = .*/pidns = \"$PIDNS\"/" \
      -e "s/^utsns = .*/utsns = \"$UTSNS\"/" \
      -e "s|^runtime = .*|runtime = \"$RUNTIME\"|" \
      ${COMPOSE_SED:+-e "$COMPOSE_SED"} \
      ${FWSED:+-e "$FWSED"} \
      -e "$INFRASED" \
      rootfs/etc/containers/containers.conf; } > /.doa-conf.tmp
echo "> etc/containers/containers.conf (runtime=$RUNTIME backend=$NET_BACKEND${NET_FWDRIVER:+/$NET_FWDRIVER} ipcns=$IPCNS pidns=$PIDNS utsns=$UTSNS infra_image=${INFRA_IMAGE:-none})"
[ -n "$INFRA_IMAGE" ] || echo "warn: no localhost/podman-pause image; pods need one on podman >= 5.5 (rootfs-overlay requires overlayfs)" >&2
mv /.doa-conf.tmp /etc/containers/containers.conf

backup_conf /etc/containers/storage.conf
DRIVER=$STORAGE_DRIVER
[ "$DRIVER" = fuse-overlayfs ] && DRIVER=overlay
GRAPHSED='/^graphroot = /d'
[ -n "$GRAPHROOT" ] && GRAPHSED="s|^graphroot = .*|graphroot = \"$GRAPHROOT\"|"
{ echo "# DockerOnAndroid: generated by install.sh from config.env"
  sed -e "s/^driver = .*/driver = \"$DRIVER\"/" -e "$GRAPHSED" rootfs/etc/containers/storage.conf
  if [ "$STORAGE_DRIVER" = fuse-overlayfs ]; then
    echo
    echo "[storage.options.overlay]"
    echo "mount_program = \"$(command -v fuse-overlayfs)\""
  fi
} > /.doa-conf.tmp
VIA=
[ "$STORAGE_DRIVER" != "$DRIVER" ] && VIA=" via $STORAGE_DRIVER"
echo "> etc/containers/storage.conf (driver=$DRIVER$VIA${GRAPHROOT:+ graphroot=$GRAPHROOT})"
mv /.doa-conf.tmp /etc/containers/storage.conf
FILES="$FILES /etc/containers/containers.conf /etc/containers/storage.conf"

{ echo "WRAPPED=\"${WRAPPED# }\""; echo "FILES=\"${FILES# }\""; echo "INET_GID=$INET_GID"; echo "NET_BACKEND=$NET_BACKEND"; } > "$MANIFEST"
echo "> manifest: $MANIFEST"

# storage.conf changes only apply to new podman processes; bounce the API
# service or the socket keeps serving the old graphroot/driver
rc-service podman restart 2>/dev/null || true

have=$(podman info --format '{{.Store.GraphDriverName}} {{.Store.GraphRoot}}' 2>/dev/null || true)
want="$DRIVER ${GRAPHROOT:-/var/lib/containers/storage}"
if [ -n "$have" ] && [ "$have" != "$want" ]; then
  echo "warn: storage DB is \"$have\", config wants \"$want\"; wipe the old graphroot to switch" >&2
fi
echo "done. check: podman ps"
