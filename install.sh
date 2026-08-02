#!/bin/sh
# install.sh: deploy the DockerOnAndroid pasta stack from ./rootfs into /.
# Run ON the device (copy this repo onto it first, any way you like).
set -e
cd "$(dirname "$0")"

# back up the pristine binaries we are about to replace (first install only)
[ -f /usr/bin/podman.real ] || cp /usr/bin/podman /usr/bin/podman.real
[ -f /usr/libexec/podman/netavark.real ] || cp /usr/libexec/podman/netavark /usr/libexec/podman/netavark.real
[ -f /usr/bin/conmon.real ] || cp /usr/bin/conmon /usr/bin/conmon.real

FILES="usr/bin/podman
usr/local/bin/pasta
usr/local/bin/crun-nomq
usr/local/lib/crun-nomq.jq
usr/libexec/podman/netavark
usr/bin/conmon
etc/network/interfaces
etc/containers/containers.conf
etc/containers/storage.conf"

for f in $FILES; do
  [ -f "rootfs/$f" ] || { echo "missing rootfs/$f (run ./build-pasta.sh first if it's pasta)" >&2; exit 1; }
  echo "> $f"
  mkdir -p "$(dirname "/$f")"
  # sidestep ETXTBSY on running binaries: copy aside, then atomic rename
  cp "rootfs/$f" /.doa-install.tmp
  mv /.doa-install.tmp "/$f"
done

chmod 755 /usr/bin/podman /usr/local/bin/pasta /usr/local/bin/crun-nomq /usr/libexec/podman/netavark /usr/bin/conmon
echo "done. check: podman ps"
