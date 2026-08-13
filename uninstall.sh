#!/bin/sh
# uninstall.sh: restore pristine binaries and remove everything install.sh
# deployed, per /etc/dockeronandroid.manifest. Run ON the device.
# Bridge-network containers lose networking afterwards; stop them first.
set -e

MANIFEST=/etc/dockeronandroid.manifest
WRAPPED="" FILES=""
# shellcheck source=/dev/null
[ -f "$MANIFEST" ] && . "$MANIFEST"

is_wrapper() { grep -q DockerOnAndroid "$1" 2>/dev/null; }

if [ -z "$WRAPPED" ]; then
  # pre-manifest install: fall back to probing for *.real backups
  for d in /usr/libexec/podman /usr/lib/podman; do
    [ -f "$d/netavark.real" ] && WRAPPED="$WRAPPED $d/netavark"
  done
  [ -f /usr/bin/podman.real ] && WRAPPED="$WRAPPED /usr/bin/podman"
  [ -f /usr/bin/conmon.real ] && WRAPPED="$WRAPPED /usr/bin/conmon"
fi

for b in $WRAPPED; do
  [ -f "$b.real" ] || continue
  if is_wrapper "$b.real"; then
    echo "warn: $b.real is itself a DoA wrapper, skipping restore" >&2
    continue
  fi
  mv -f "$b.real" "$b"
done

if [ -z "$FILES" ]; then
  FILES="/usr/local/bin/pasta /usr/local/bin/crun-nomq /usr/local/lib/crun-nomq.jq /usr/local/bin/doa-tsd /etc/init.d/doa-tsd /usr/local/bin/doa-healthcheckd /etc/init.d/doa-healthcheckd"
fi
for f in $FILES; do
  case $f in
    /etc/init.d/doa-cgroups)
      rc-update del doa-cgroups 2>/dev/null || true
      rm -f "$f"
      ;;
    /etc/init.d/doa-tsd)
      rc-update del doa-tsd 2>/dev/null || true
      rc-service doa-tsd stop 2>/dev/null || true
      rm -f "$f"
      ;;
    /etc/init.d/doa-healthcheckd)
      rc-update del doa-healthcheckd 2>/dev/null || true
      rc-service doa-healthcheckd stop 2>/dev/null || true
      rm -f "$f"
      ;;
    /etc/containers/*|/etc/network/interfaces)
      if [ -f "$f.doa-bak" ]; then mv -f "$f.doa-bak" "$f"; else rm -f "$f"; fi
      ;;
    *) rm -f "$f" ;;
  esac
done

rm -f "$MANIFEST"
rm -rf /tmp/pasta /tmp/nv-shim.log /tmp/nv-aardvark.log
echo "done: pristine state restored"
