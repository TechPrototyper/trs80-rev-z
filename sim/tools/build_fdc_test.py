#!/usr/bin/env python3
"""Build the FDC Type-I test image (this repo's own code — NOT a Tandy ROM).

Hand-assembled Z80 for EI stage 2 (WD1771 Type I): selects drive 0, then
drives the FDC through Restore / Seek 17 / 3x Step-In / Step-Out / Seek 0
and tags registers and statuses into VRAM. Every command completion is
detected by polling the FDC INTRQ through 0x37E0 bit 6 (never by delay
loops), so the tags are robust against step-rate and emulator-speed
differences; the INDEX status bit (S1) is masked out of every status tag
(AND 0xFD) because it follows disk rotation and is therefore not
deterministic between machines.

The status register is never tagged before the ready poll: trs80gp
reports NOT READY for one emulation quantum right after the select
write, and whether a read lands inside that quantum shifts with
unrelated instruction timing (probed 2026-07-24: two images identical
from the select on differed 84 vs 06 there). Polling ready first is
also what real DOS drivers do.

VRAM tags (quirk-invariant hex chars; ground truth probed against
trs80gp 2.5.5 on an unformatted "-d dmk" disk, 2026-07-24):
  row 0 (3C00): "FD" banner; 3C04: status&FD once ready ("04"), track,
                sector, data ("000000" — note sector resets to 0, not
                1). The poll budget is NOT tagged: trs80gp models a
                short spin-up (a few ms), our drives are ready at once —
                the tag would compare emulator internals, not contract.
  row 1 (3C44): restore status&FD, track, INTRQ-after-status-read ("00"),
                seek-17 status&FD, track ("11"), 3x-step-in status&FD,
                track ("14"), step-out status&FD, track ("13")
  row 2 (3C84): seek-0 status&FD ("04": TR00 again), track ("00"),
                data-register r/w ("55"), sector-register r/w ("AA")

HALT then raises NMI and the handler writes the 0xBF done marker.
Outputs: fdctest.hex ($readmemh, 4 KiB) and fdctest.bin (raw).
"""

ROM_SIZE = 0x1000

img = bytearray(ROM_SIZE)


def emit(addr, byts, mnemonic):
    for i, b in enumerate(byts):
        assert img[addr + i] == 0, f"overlap at {addr+i:04X}"
        img[addr + i] = b
    return addr + len(byts)


TAGB, HEXN, DOCMD = 0x0200, 0x0220, 0x0240


def lo(x): return x & 0xFF
def hi(x): return x >> 8


a = emit(0x0000, [0xF3, 0x31, 0xFF, 0x7F, 0xC3, 0x00, 0x01],
         "DI; LD SP,7FFFh; JP 0100h")
a = emit(0x0066, [0x3E, 0xBF, 0x32, 0xFF, 0x3F, 0x18, 0xFE],
         "NMI: done marker, spin")

a = 0x0100
a = emit(a, [0x21, 0x00, 0x3C, 0x11, 0x01, 0x3C, 0x01, 0xFF, 0x03,
             0x36, 0x20, 0xED, 0xB0],   "clear screen")
a = emit(a, [0x3E, 0x46, 0x32, 0x00, 0x3C], "banner 'F'")
a = emit(a, [0x3E, 0x44, 0x32, 0x01, 0x3C], "banner 'D'")
a = emit(a, [0x3E, 0x01, 0x32, 0xE0, 0x37], "select drive 0, motor on")
a = emit(a, [0x21, 0x04, 0x3C],             "HL = tag cursor row 0")
# spin-up FIRST: poll status bit 7 until ready (bounded; see header)
a = emit(a, [0x01, 0x00, 0x00],             "LD BC,0 (budget)")
a = emit(a, [0x3A, 0xEC, 0x37, 0xE6, 0x80, 0x28, 0x05,
             0x0B, 0x78, 0xB1, 0x20, 0xF4], "spin: until S7 == 0")
a = emit(a, [0x3A, 0xEC, 0x37, 0xE6, 0xFD, 0xCD, lo(TAGB), hi(TAGB)],
         "status & FD once ready")
for reg in (0xED, 0xEE, 0xEF):
    a = emit(a, [0x3A, reg, 0x37, 0xCD, lo(TAGB), hi(TAGB)],
             f"initial reg 37{reg:02X}")

a = emit(a, [0x21, 0x44, 0x3C],             "HL = tag cursor row 1")
a = emit(a, [0x3E, 0x02, 0xCD, lo(DOCMD), hi(DOCMD),
             0xE6, 0xFD, 0xCD, lo(TAGB), hi(TAGB)], "Restore (r=10)")
a = emit(a, [0x3A, 0xED, 0x37, 0xCD, lo(TAGB), hi(TAGB)], "track (00)")
a = emit(a, [0x3A, 0xE0, 0x37, 0xE6, 0x40, 0xCD, lo(TAGB), hi(TAGB)],
         "INTRQ after status read (00)")
a = emit(a, [0x3E, 0x11, 0x32, 0xEF, 0x37], "data = 17")
a = emit(a, [0x3E, 0x12, 0xCD, lo(DOCMD), hi(DOCMD),
             0xE6, 0xFD, 0xCD, lo(TAGB), hi(TAGB)], "Seek 17")
a = emit(a, [0x3A, 0xED, 0x37, 0xCD, lo(TAGB), hi(TAGB)], "track (11)")
a = emit(a, [0x3E, 0x52, 0xCD, lo(DOCMD), hi(DOCMD)], "Step-In u")
a = emit(a, [0x3E, 0x52, 0xCD, lo(DOCMD), hi(DOCMD)], "Step-In u")
a = emit(a, [0x3E, 0x52, 0xCD, lo(DOCMD), hi(DOCMD),
             0xE6, 0xFD, 0xCD, lo(TAGB), hi(TAGB)], "Step-In u (3rd)")
a = emit(a, [0x3A, 0xED, 0x37, 0xCD, lo(TAGB), hi(TAGB)], "track (14)")
a = emit(a, [0x3E, 0x72, 0xCD, lo(DOCMD), hi(DOCMD),
             0xE6, 0xFD, 0xCD, lo(TAGB), hi(TAGB)], "Step-Out u")
a = emit(a, [0x3A, 0xED, 0x37, 0xCD, lo(TAGB), hi(TAGB)], "track (13)")

a = emit(a, [0x21, 0x84, 0x3C],             "HL = tag cursor row 2")
a = emit(a, [0xAF, 0x32, 0xEF, 0x37],       "data = 0")
a = emit(a, [0x3E, 0x12, 0xCD, lo(DOCMD), hi(DOCMD),
             0xE6, 0xFD, 0xCD, lo(TAGB), hi(TAGB)], "Seek 0 (TR00)")
a = emit(a, [0x3A, 0xED, 0x37, 0xCD, lo(TAGB), hi(TAGB)], "track (00)")
a = emit(a, [0x3E, 0x55, 0x32, 0xEF, 0x37, 0x3A, 0xEF, 0x37,
             0xCD, lo(TAGB), hi(TAGB)],     "data register r/w (55)")
a = emit(a, [0x3E, 0xAA, 0x32, 0xEE, 0x37, 0x3A, 0xEE, 0x37,
             0xCD, lo(TAGB), hi(TAGB)],     "sector register r/w (AA)")
a = emit(a, [0x76],                          "HALT -> NMI -> marker")

a = emit(TAGB, [0xF5, 0x0F, 0x0F, 0x0F, 0x0F, 0xCD, lo(HEXN), hi(HEXN),
                0x77, 0x23, 0xF1, 0xCD, lo(HEXN), hi(HEXN),
                0x77, 0x23, 0xC9],           "tagbyte: A as hex to (HL)")
a = emit(HEXN, [0xE6, 0x0F, 0xC6, 0x30, 0xFE, 0x3A, 0x38, 0x02,
                0xC6, 0x07, 0xC9],           "hexn")
# DOCMD: A = command -> 37EC, poll 37E0 bit6 (bounded), return status in A
a = emit(DOCMD, [0x32, 0xEC, 0x37, 0x01, 0x00, 0x00,
                 0x3A, 0xE0, 0x37, 0xE6, 0x40, 0x20, 0x05,
                 0x0B, 0x78, 0xB1, 0x20, 0xF4,
                 0x3A, 0xEC, 0x37, 0xC9],    "docmd")

with open("build/fdctest.hex", "w") as f:
    f.write("\n".join(f"{b:02x}" for b in img) + "\n")
with open("build/fdctest.bin", "wb") as f:
    f.write(img)
print(f"fdctest: image {ROM_SIZE} bytes")
