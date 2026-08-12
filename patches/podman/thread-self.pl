# DockerOnAndroid: binary-patch podman to use /run/doa-ts (the doa-tsd FUSE
# shim) instead of /proc/thread-self, which kernels < 3.17 lack. Replacements
# are length-preserving (padded with '/') so offsets stay valid.
# Usage: perl thread-self.pl < podman.real > podman.real.patched
local $/;
$_ = <>;
s{/proc/thread-self}{"/run/doa-ts" . "/" x 6}ge;
print;
