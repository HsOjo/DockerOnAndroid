#!/bin/sh
# install.sh: deploy the DockerOnAndroid pasta stack from ./rootfs into /.
# Run ON the device (copy this repo onto it first, any way you like).
set -e
cd "$(dirname "$0")"

if [ -d /usr/libexec/podman ]; then LIBEXEC=/usr/libexec/podman
elif [ -d /usr/lib/podman ]; then LIBEXEC=/usr/lib/podman
else echo "error: podman libexec dir not found (tried /usr/libexec/podman, /usr/lib/podman)" >&2; exit 1
fi

is_wrapper() { grep -q DockerOnAndroid "$1" 2>/dev/null; }

# back up pristine binaries (first install only); never treat a wrapper as
# pristine, and refuse to reinstall over a wrapper whose backup is missing
for b in /usr/bin/podman /usr/bin/conmon "$LIBEXEC/netavark"; do
  if [ -f "$b.real" ]; then
    if is_wrapper "$b.real"; then
      echo "error: $b.real is itself a DoA wrapper; restore pristine binaries first" >&2; exit 1
    fi
  elif is_wrapper "$b"; then
    echo "error: $b is already a DoA wrapper but $b.real is missing; cannot recover the pristine binary" >&2; exit 1
  else
    cp "$b" "$b.real"
  fi
done

FILES="usr/bin/podman
usr/local/bin/pasta
usr/local/bin/crun-nomq
usr/local/lib/crun-nomq.jq
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
echo "> $LIBEXEC/netavark"
cp rootfs/usr/libexec/podman/netavark /.doa-install.tmp
mv /.doa-install.tmp "$LIBEXEC/netavark"

chmod 755 /usr/bin/podman /usr/local/bin/pasta /usr/local/bin/crun-nomq "$LIBEXEC/netavark" /usr/bin/conmon
echo "done. check: podman ps"
