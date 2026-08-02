#!/bin/sh
# uninstall.sh: restore pristine podman/conmon/netavark and remove DoA state.
# Bridge-network containers lose networking afterwards; stop them first.
set -e
TARGET=${TARGET:?set TARGET, e.g. TARGET=root@<device-ip> ./uninstall.sh}
SSH=${SSH:-ssh -o StrictHostKeyChecking=no}

$SSH "$TARGET" 'set -e
for b in /usr/bin/podman /usr/bin/conmon /usr/libexec/podman/netavark; do
  [ -f "$b.real" ] && mv -f "$b.real" "$b"
done
rm -rf /tmp/pasta /tmp/nv-shim.log /tmp/nv-aardvark.log'
echo "done: pristine binaries restored, pasta state removed"
