#!/usr/bin/env python3
# DockerOnAndroid: binary-patch podman to use /run/doa-ts (the doa-tsd FUSE
# shim) instead of /proc/thread-self, which kernels < 3.17 lack. Replacements
# are length-preserving (padded with '/') so offsets stay valid.
# Usage: thread-self.py < podman.real > podman.real.patched
import sys

data = sys.stdin.buffer.read()
data = data.replace(b"/proc/thread-self", b"/run/doa-ts" + b"/" * 6)
sys.stdout.buffer.write(data)
