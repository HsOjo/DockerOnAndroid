#!/bin/sh
# uninstall.sh: restore pristine podman/conmon/netavark and remove DoA state.
# Run ON the device. Bridge-network containers lose networking afterwards; stop them first.
set -e

NV=
for d in /usr/libexec/podman /usr/lib/podman; do
  [ -f "$d/netavark.real" ] && NV=$d/netavark
done

is_wrapper() { grep -q DockerOnAndroid "$1" 2>/dev/null; }

for b in /usr/bin/podman /usr/bin/conmon $NV; do
  [ -f "$b.real" ] || continue
  if is_wrapper "$b.real"; then
    echo "warn: $b.real is itself a DoA wrapper, skipping restore" >&2
    continue
  fi
  mv -f "$b.real" "$b"
done
rm -rf /tmp/pasta /tmp/nv-shim.log /tmp/nv-aardvark.log
echo "done: pristine binaries restored, pasta state removed"
