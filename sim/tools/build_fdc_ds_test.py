#!/usr/bin/env python3
"""Build the double-sided read probe (this repo's own code — NOT a Tandy
ROM).

Exercises the Model 1 double-sided convention (NEWDOS/80 PDRIVE, probed
from the nd80206 boot sector 2026-08-20): drive-select latch bit 3
together with a drive bit selects head 1, so 0x09 = drive 0 side 1.
Against build_dmk.py --sides 2 (two track blocks per cylinder, distinct
data per side) the probe:

  1. selects drive 0 (0x01), restores, seeks to track 2,
  2. reads t2/s3 on side 0 (status, count, checksum),
  3. writes 0x09 to the latch and reads t2/s3 on side 1 — different
     content proves the second head,
  4. selects side 0 again and re-reads t2/s3 — the checksum must swing
     back (the FDC's track buffer is keyed by side, not just track).

VRAM tags (hex chars): row 0 (3C00) "DS"; 3C04: side-0 status, count
low, checksum; side-1 status, count low, checksum; side-0 checksum
again. Expected with the standard 5-track DS disk:
00 00 97 / 00 00 F9 / 97 -> "0000970000f997".

HALT then raises NMI; the handler writes the 0xBF done marker.
Outputs: fdcdstest.hex ($readmemh, 4 KiB) and fdcdstest.bin (raw).
"""

img = bytearray(0x1000)


def emit(addr, byts, mnemonic=""):
    for i, b in enumerate(byts):
        assert img[addr + i] == 0, f"overlap at {addr+i:04X}"
        img[addr + i] = b
    return addr + len(byts)


def emit_block(addr, prog):
    """Two-pass mini assembler (chapter-7 idiom)."""
    labels, pc = {}, addr
    for item in prog:
        if item[0] == "label":
            labels[item[1]] = pc
        else:
            pc += len(item[0]) + (1 if len(item) > 1
                                  and isinstance(item[1], tuple) else 0)
    pc = addr
    for item in prog:
        if item[0] == "label":
            continue
        for b in item[0]:
            assert img[pc] == 0, f"overlap at {pc:04X}"
            img[pc] = b
            pc += 1
        if len(item) > 1 and isinstance(item[1], tuple):
            disp = labels[item[1][1]] - (pc + 1)
            assert -128 <= disp <= 127, f"jump range to {item[1][1]}"
            img[pc] = disp & 0xFF
            pc += 1
    return pc


TAGB, HEXN, DOCMD, RDSEC = 0x0200, 0x0220, 0x0240, 0x0270


def lo(x): return x & 0xFF
def hi(x): return x >> 8


emit(0x0000, [0xF3, 0x31, 0xFF, 0x7F, 0xC3, 0x00, 0x01],
     "DI; LD SP,7FFFh; JP 0100h")
emit(0x0066, [0x3E, 0xBF, 0x32, 0xFF, 0x3F, 0x18, 0xFE],
     "NMI: done marker, spin")

# tagbyte: A as two hex chars to (HL), HL += 2
emit(TAGB, [0xF5, 0x0F, 0x0F, 0x0F, 0x0F, 0xCD, lo(HEXN), hi(HEXN),
            0x77, 0x23, 0xF1, 0xCD, lo(HEXN), hi(HEXN), 0x77, 0x23, 0xC9])
emit(HEXN, [0xE6, 0x0F, 0xC6, 0x30, 0xFE, 0x3A, 0x38, 0x02,
            0xC6, 0x07, 0xC9])

# DOCMD: A -> command register, poll 37E0 bit 6 (INTRQ), status in A
emit(DOCMD, [0x32, 0xEC, 0x37, 0x01, 0x00, 0x00,
             0x3A, 0xE0, 0x37, 0xE6, 0x40, 0x20, 0x05,
             0x0B, 0x78, 0xB1, 0x20, 0xF4,
             0x3A, 0xEC, 0x37, 0xC9])

# RDSEC: E = command; boot-ROM loop; data bytes to (BC); status in A
emit_block(RDSEC, [
    ([0x7B],), ([0x32, 0xEC, 0x37],),                # command = E
    ("label", "rl"),
    ([0x3A, 0xEC, 0x37],), ([0x57],),                # D = status
    ([0x0F],), ([0x30], ("rel8", "dn")),             # busy clear -> done
    ([0x7A],), ([0xCB, 0x4F],), ([0x28], ("rel8", "rl")),   # DRQ?
    ([0x3A, 0xEF, 0x37],), ([0x02],), ([0x03],),     # store, advance
    ([0x18], ("rel8", "rl")),
    ("label", "dn"),
    ([0x7A],), ([0xC9],),                            # A = final status
])


def read_t2s3(latch, tag_status):
    """Select latch (drive 0, side per bit 3), read t2/s3 to 4100, tag
    status+count (optional) and the 8-bit checksum."""
    seq = [
        ([0x3E, latch],), ([0x32, 0xE0, 0x37],),     # select + motor
        ([0x3E, 0x03],), ([0x32, 0xEE, 0x37],),      # sector = 3
        ([0x01, 0x00, 0x41],),                       # dest = 4100
        ([0x1E, 0x88],), ([0xCD, lo(RDSEC), hi(RDSEC)],),
    ]
    if tag_status:
        seq += [
            ([0xCD, lo(TAGB), hi(TAGB)],),           # status
            ([0x79],), ([0xCD, lo(TAGB), hi(TAGB)],),  # count low (C)
        ]
    seq += [
        ([0xE5],), ([0x21, 0x00, 0x41],), ([0x06, 0x00],), ([0xAF],),
        ("label", f"cs{latch}_{tag_status}"),
        ([0x86],), ([0x23],), ([0x05],),
        ([0x20], ("rel8", f"cs{latch}_{tag_status}")),
        ([0x57],), ([0xE1],), ([0x7A],),
        ([0xCD, lo(TAGB), hi(TAGB)],),               # checksum
    ]
    return seq


prog = [
    ([0x21, 0x00, 0x3C],), ([0x11, 0x01, 0x3C],), ([0x01, 0xFF, 0x03],),
    ([0x36, 0x20],), ([0xED, 0xB0],),                # clear screen
    ([0x3E, 0x44],), ([0x32, 0x00, 0x3C],),          # 'D'
    ([0x3E, 0x53],), ([0x32, 0x01, 0x3C],),          # 'S'
    ([0x3E, 0x01],), ([0x32, 0xE0, 0x37],),          # select drive 0
    ([0x01, 0x00, 0x00],),
    ("label", "spin"),
    ([0x3A, 0xEC, 0x37],), ([0xE6, 0x80],), ([0x28], ("rel8", "rdy")),
    ([0x0B],), ([0x78],), ([0xB1],), ([0x20], ("rel8", "spin")),
    ("label", "rdy"),
    ([0x3E, 0x0B],), ([0xCD, lo(DOCMD), hi(DOCMD)],),  # restore (h, r3)
    ([0x3E, 0x02],), ([0x32, 0xEF, 0x37],),          # data = 2
    ([0x3E, 0x1B],), ([0xCD, lo(DOCMD), hi(DOCMD)],),  # seek track 2
    ([0x21, 0x04, 0x3C],),                           # tag cursor row 0
]
prog += read_t2s3(0x01, True)    # side 0: 00 00 97
prog += read_t2s3(0x09, True)    # side 1: 00 00 F9
prog += read_t2s3(0x01, False)   # side 0 again: 97 (buffer re-keyed)
prog += [([0x76],)]

emit_block(0x0100, prog)

with open("build/fdcdstest.hex", "w") as f:
    f.write("\n".join(f"{b:02x}" for b in img) + "\n")
with open("build/fdcdstest.bin", "wb") as f:
    f.write(img)
print("fdcdstest: image 4096 bytes")
