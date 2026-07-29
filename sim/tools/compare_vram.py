#!/usr/bin/env python3
"""Byte-exact VRAM comparison: our simulation vs. a golden-model dump (SPEC §6).

Both files are 1024 raw bytes, one per screen cell (row*64 + col). Before
comparing, BOTH sides are normalized to the form a real Model 1 reads back:
bit 6 := NOR(D5, D7) — the "sneaky bit 6" (chapter 3, Z30). Our simulation
already writes that form; trs80gp's `-it` dump returns the bytes as the CPU
wrote them, which coincides with it for full-ASCII writes (all the tag-based
goldens) but NOT for software that stores bit-6-stripped characters — TRSDOS
2.3 writes 'T' as 0x14, real hardware and our RTL read that back as 0x54
(found 2026-07-24 by the stage-4 DOS boot golden). Normalization is exactly
"what the hardware would read", and the identity on every quirk-invariant
byte, so the historical goldens are unaffected.

Usage: compare_vram.py <golden.bin> <sim.bin>
Exit 0 on a byte-exact match, 1 otherwise (with a diff listing).
"""

import sys

def load(path):
    with open(path, "rb") as f:
        d = f.read()
    if len(d) != 1024:
        sys.exit(f"{path}: expected 1024 bytes, got {len(d)}")
    # the Z30 read-back transform: D6 = NOR(D5, D7)
    return bytes((b & 0xBF) | (0 if (b & 0xA0) else 0x40) for b in d)

def glyph(b):
    # printable ASCII where the code maps to it, else '.'
    return chr(b) if 32 <= b < 127 else "."

def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    golden = load(sys.argv[1])
    sim    = load(sys.argv[2])

    diffs = [i for i in range(1024) if golden[i] != sim[i]]
    if not diffs:
        print(f"MATCH  1024/1024 cells byte-exact  ({sys.argv[1]} == {sys.argv[2]})")
        # a human-readable echo of the top three screen lines
        for r in range(3):
            line = "".join(glyph(sim[r * 64 + c] & 0x7F) for c in range(64))
            print(f"  row {r}: {line!r}")
        return 0

    print(f"MISMATCH  {len(diffs)}/1024 cells differ:")
    for i in diffs[:32]:
        print(f"  cell {i:4d} (row {i//64:2d} col {i%64:2d}): "
              f"golden={golden[i]:02x} sim={sim[i]:02x}")
    if len(diffs) > 32:
        print(f"  ... and {len(diffs) - 32} more")
    return 1

if __name__ == "__main__":
    sys.exit(main())
