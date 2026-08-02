#!/bin/sh
# install.sh: deploy the DockerOnAndroid pasta stack into a running LoA guest.
# Default transport is ssh; override with TARGET/SSH.
set -e
cd "$(dirname "$0")"

TARGET=${TARGET:?set TARGET, e.g. TARGET=root@<device-ip> ./install.sh}
SSH=${SSH:-ssh -o StrictHostKeyChecking=no}
SCP=${SCP:-scp -o StrictHostKeyChecking=no}

# back up the pristine binaries we are about to replace (first install only)
$SSH "$TARGET" '[ -f /usr/bin/podman.real ] || cp /usr/bin/podman /usr/bin/podman.real
[ -f /usr/libexec/podman/netavark.real ] || cp /usr/libexec/podman/netavark /usr/libexec/podman/netavark.real
[ -f /usr/bin/conmon.real ] || cp /usr/bin/conmon /usr/bin/conmon.real'

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
  [ -f "rootfs/$f" ] || { echo "missing rootfs/$f" >&2; exit 1; }
  echo "> $f"
  # sidestep ETXTBSY on running binaries: upload aside, then atomic rename
  $SCP "rootfs/$f" "$TARGET:/.doa-install.tmp"
  $SSH "$TARGET" "mv /.doa-install.tmp '/$f'"
done

$SSH "$TARGET" sh -s <<'EOF'
set -e
chmod 755 /usr/bin/podman /usr/local/bin/pasta /usr/local/bin/crun-nomq /usr/libexec/podman/netavark /usr/bin/conmon
EOF
echo "done. check: ssh $TARGET podman ps"
