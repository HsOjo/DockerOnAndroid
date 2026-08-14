#!/bin/sh
# uninstall.sh: restore pristine binaries and remove everything install.sh can
# deploy. Probe-based: walks the full known universe of DoA artifacts instead
# of trusting config.env / the manifest, which only reflect the last install
# and may be stale or edited. Run ON the device.
# Bridge-network containers lose networking afterwards; stop them first.
set -e

is_wrapper() { grep -q DockerOnAndroid "$1" 2>/dev/null; }

if [ -d /usr/libexec/podman ]; then LIBEXEC=/usr/libexec/podman
elif [ -d /usr/lib/podman ]; then LIBEXEC=/usr/lib/podman
else LIBEXEC=
fi

# restore wrapped binaries from *.real backups
for b in /usr/bin/podman /usr/bin/conmon /usr/bin/crun /usr/bin/fuse-overlayfs ${LIBEXEC:+$LIBEXEC/netavark}; do
  [ -f "$b.real" ] || continue
  if is_wrapper "$b.real"; then
    echo "warn: $b.real is itself a DoA wrapper, skipping restore" >&2
    continue
  fi
  mv -f "$b.real" "$b"
done

# openrc services
for s in doa-cgroups doa-tsd doa-healthcheckd; do
  rc-update del "$s" 2>/dev/null || true
  rc-service "$s" stop 2>/dev/null || true
  rm -f "/etc/init.d/$s"
done

# deployed files. /etc configs are only touched when they carry the DoA marker;
# a *.doa-bak gets restored, a DoA file without one is removed, and a foreign
# file is left alone.
for f in /usr/local/bin/pasta /usr/local/bin/crun-nomq /usr/local/lib/crun-nomq.jq \
         /usr/local/share/doa/apt-sandbox.conf /usr/local/bin/doa-tsd \
         /usr/local/bin/doa-healthcheckd /usr/local/bin/podman-compose-doa \
         /etc/network/interfaces \
         /etc/containers/containers.conf /etc/containers/storage.conf; do
  case $f in
    /etc/*)
      if is_wrapper "$f"; then
        if [ -f "$f.doa-bak" ]; then mv -f "$f.doa-bak" "$f"; else rm -f "$f"; fi
      fi
      ;;
    *) rm -f "$f" ;;
  esac
done

rm -f /etc/dockeronandroid.manifest
rm -rf /tmp/pasta /tmp/nv-shim.log /tmp/nv-aardvark.log /run/doa-healthcheckd
echo "done: pristine state restored"
