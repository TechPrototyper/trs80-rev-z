#!/usr/bin/env python3
"""Build the FDC record-type (DAM) probe image (this repo's own code — NOT
a Tandy ROM).

Hand-assembled Z80 for the WD1771 record-type status bits: boots with a
DMK in drive 0 whose track 2 sectors 0..3 carry the four DAMs FB/FA/F9/F8
(build_dmk.py --damtrk 2; trs80gp mounts the same file with -d0), selects
the drive, restores, seeks to track 2, and reads the four sectors in
order, tagging each final Type II status byte to VRAM.

TRS-80 DOSes write directory sectors with deleted DAMs (FA/F8 observed on
real NEWDOS/80 disks) and verify the record type on every directory read
— one mis-encoded status bit and DIR dies while booting still works,
which is exactly the failure this probe pins down.

Driver pattern identical to build_fdc_rd_test.py (probed against trs80gp
2.5.5): Type I commands complete via the 37E0-bit-6 INTRQ poll; Type II
uses the boot-ROM loop (poll status, service DRQ, exit on busy clear).

VRAM tags (hex chars):
  row 0 (3C00) "DA"; 3C04: four Type II read statuses, in DAM order
  FB, FA, F9, F8 (sectors 0..3 of track 2)

HALT then raises NMI; the handler writes the 0xBF done marker.
Outputs: fdcdamtest.hex ($readmemh, 4 KiB) and fdcdamtest.bin (raw).
"""

img = bytearray(0x1000)


def emit(addr, byts, mnemonic=""):
    for i, b in enumerate(byts):
        assert img[addr + i] == 0, f"overlap at {addr+i:04X}"
        img[addr + i] = b
    return addr + len(byts)


def emit_block(addr, prog):
    """Two-pass mini assembler (chapter-7 idiom): items are ("label", n)
    or (bytes,) or (bytes, ("rel8", target))."""
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

# tagbyte: A as two hex chars to (HL), HL += 2 (clobbers nothing else)
emit(TAGB, [0xF5, 0x0F, 0x0F, 0x0F, 0x0F, 0xCD, lo(HEXN), hi(HEXN),
            0x77, 0x23, 0xF1, 0xCD, lo(HEXN), hi(HEXN), 0x77, 0x23, 0xC9])
emit(HEXN, [0xE6, 0x0F, 0xC6, 0x30, 0xFE, 0x3A, 0x38, 0x02,
            0xC6, 0x07, 0xC9])

# DOCMD: A -> command register, poll 37E0 bit 6 (INTRQ) with a bounded
# budget, return the (INTRQ-clearing) status read in A
emit(DOCMD, [0x32, 0xEC, 0x37, 0x01, 0x00, 0x00,
             0x3A, 0xE0, 0x37, 0xE6, 0x40, 0x20, 0x05,
             0x0B, 0x78, 0xB1, 0x20, 0xF4,
             0x3A, 0xEC, 0x37, 0xC9])

# RDSEC: E = command; boot-ROM loop; data bytes to (BC); returns the
# final status in A
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


def read_and_tag(s):
    """Motor retrigger, sector = s, read to 4100, tag the final status."""
    return [
        ([0x3E, 0x01],), ([0x32, 0xE0, 0x37],),      # motor retrigger
        ([0x3E, s],), ([0x32, 0xEE, 0x37],),         # sector = s
        ([0x01, 0x00, 0x41],),                       # dest = 4100
        ([0x1E, 0x88],), ([0xCD, lo(RDSEC), hi(RDSEC)],),
        ([0xCD, lo(TAGB), hi(TAGB)],),               # status
    ]


emit_block(0x0100, [
    ([0x21, 0x00, 0x3C],), ([0x11, 0x01, 0x3C],), ([0x01, 0xFF, 0x03],),
    ([0x36, 0x20],), ([0xED, 0xB0],),                # clear screen
    ([0x3E, 0x44],), ([0x32, 0x00, 0x3C],),          # 'D'
    ([0x3E, 0x41],), ([0x32, 0x01, 0x3C],),          # 'A'
    ([0x3E, 0x01],), ([0x32, 0xE0, 0x37],),          # select drive 0
    ([0x01, 0x00, 0x00],),
    ("label", "spin"),
    ([0x3A, 0xEC, 0x37],), ([0xE6, 0x80],), ([0x28], ("rel8", "rdy")),
    ([0x0B],), ([0x78],), ([0xB1],), ([0x20], ("rel8", "spin")),
    ("label", "rdy"),
    ([0x3E, 0x0B],), ([0xCD, lo(DOCMD), hi(DOCMD)],),  # restore (h, r3)

    # seek track 2
    ([0x3E, 0x01],), ([0x32, 0xE0, 0x37],),          # motor retrigger
    ([0x3E, 0x02],), ([0x32, 0xEF, 0x37],),          # data = 2
    ([0x3E, 0x1B],), ([0xCD, lo(DOCMD), hi(DOCMD)],),  # seek (h, r3)

    # read sectors 0..3 (DAMs FB, FA, F9, F8), tag each status
    ([0x21, 0x04, 0x3C],),                           # tag cursor row 0
    *read_and_tag(0),
    *read_and_tag(1),
    *read_and_tag(2),
    *read_and_tag(3),
    ([0x76],),
])

with open("build/fdcdamtest.hex", "w") as f:
    f.write("\n".join(f"{b:02x}" for b in img) + "\n")
with open("build/fdcdamtest.bin", "wb") as f:
    f.write(img)
print("fdcdamtest: image 4096 bytes")
