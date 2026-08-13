#!/usr/bin/env python3
# DockerOnAndroid: binary-patch podman to always use the overlay native diff
# driver. podman probes the kernel once per process (useNaiveDiff -> sync.Once
# -> func1) and falls back to a slow userspace "naive" diff when the probe
# fails; on Android kernels the probe fails even though overlay mounts work,
# so every layer commit pays a full userspace walk. Turning func1 into a no-op
# keeps the naive flag false. aarch64 only: func1 is located by a distinctive
# instruction pair in its body and its entry is overwritten with `ret`.
# Usage: naive-diff.py < podman.real > podman.real.patched
import sys

NEEDLE = bytes.fromhex("420740f9434c40f9")
PROLOGUE = bytes.fromhex("900b40f9")
RET = bytes.fromhex("c0035fd6")
CBNZ_X3_MASK = 0xFF00001F
CBNZ_X3 = 0xB5000003
ENTRY_DELTA = 0x1C

data = bytearray(sys.stdin.buffer.read())
hits = []
pos = 0
while True:
    pos = data.find(NEEDLE, pos)
    if pos < 0:
        break
    cbnz = int.from_bytes(data[pos + 8:pos + 12], "little")
    entry = pos - ENTRY_DELTA
    if cbnz & CBNZ_X3_MASK == CBNZ_X3 and entry >= 0 and \
            bytes(data[entry:entry + 4]) in (PROLOGUE, RET):
        hits.append(entry)
    pos += 1

if len(hits) != 1:
    print(f"naive-diff.py: expected 1 func1 candidate, found {len(hits)}; "
          "binary left unchanged", file=sys.stderr)
elif bytes(data[hits[0]:hits[0] + 4]) == RET:
    print("naive-diff.py: already patched", file=sys.stderr)
else:
    data[hits[0]:hits[0] + 4] = RET
    print(f"naive-diff.py: patched func1 at file offset {hits[0]}",
          file=sys.stderr)

sys.stdout.buffer.write(bytes(data))
