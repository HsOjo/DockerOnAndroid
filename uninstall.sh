#!/bin/sh
# uninstall.sh: restore pristine podman/conmon/netavark and remove DoA state.
# Run ON the device. Bridge-network containers lose networking afterwards; stop them first.
set -e

for b in /usr/bin/podman /usr/bin/conmon /usr/libexec/podman/netavark; do
  [ -f "$b.real" ] && mv -f "$b.real" "$b"
done
rm -rf /tmp/pasta /tmp/nv-shim.log /tmp/nv-aardvark.log
echo "done: pristine binaries restored, pasta state removed"
