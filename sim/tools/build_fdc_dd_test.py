#!/usr/bin/env python3
"""Build the double-density test image (EI stage 6 — this repo's own code).

Scenario on the mixed-density disk (build_dmk.py --dd: SD boot track 0,
MFM 18x256 elsewhere), identical on our machine and in trs80gp -ddp:

  1. 0xFE (Percom latch -> SD/1771), read t0/s0 — the SD track of the
     mixed disk, ordinary 64 us loop. Tags: status, count, checksum.
  2. 0xFF (-> DD/1791), seek track 2, read s3 with the DOUBLER-ERA
     DRIVER LOOP: MFM is one byte per 32 us = 56.7 Z80 T-states, which
     no straight poll loop meets; the 2x-unrolled loop below runs ~52.5
     T/byte (DE-indirect status poll at 7 T is the period trick — no
     WAIT gating existed on an unmodified Model 1, probed identically
     in trs80gp). Tags: status, count, checksum.
  3. DD-write s7 with constant 0x5A fill (fill in C, LD (HL),C store —
     see WRDD below for the worst-case budget), read it back with the
     fast loop. Tags prove the overwrite (checksum 00 replaces the
     generator's 40).
  4. Still-DD proof inverted: switch 0xFE (SD) and request s3 on the
     all-MFM track 2 — the density filter must answer RNF (status 10).

Motor retriggers before every operation. Outputs fdcddtest.hex/.bin.
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
# final status in A and the byte-count low in L' (we recompute from BC)
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


# RDDD at 0x02C0: fast MFM read, 256 bytes to (HL, page-aligned), then
# wait INTRQ; returns final status in A. DE=37EC on entry.
RDDD = 0x02C0
emit_block(RDDD, [
    ([0x11, 0xEC, 0x37],),                           # DE = status
    ([0x06, 0x80],),                                 # B = 128 pairs
    ([0x3E, 0x88],), ([0x32, 0xEC, 0x37],),          # READ SECTOR
    ("label", "p1"),
    ([0x1A],), ([0x0F],), ([0x0F],), ([0x30], ("rel8", "p1")),
    ([0x3A, 0xEF, 0x37],), ([0x77],), ([0x2C],),     # byte 1
    ("label", "p2"),
    ([0x1A],), ([0x0F],), ([0x0F],), ([0x30], ("rel8", "p2")),
    ([0x3A, 0xEF, 0x37],), ([0x77],), ([0x2C],),     # byte 2
    ([0x10], ("rel8", "p1")),                        # DJNZ
    ([0x01, 0x00, 0x00],),
    ("label", "wi"),
    ([0x3A, 0xE0, 0x37],), ([0xE6, 0x40],), ([0x20], ("rel8", "wd")),
    ([0x0B],), ([0x78],), ([0xB1],), ([0x20], ("rel8", "wi")),
    ("label", "wd"),
    ([0x3A, 0xEC, 0x37],), ([0xC9],),
])

# WRDD at 0x0300: fast MFM write, 256 x 0x5A. The status poll clobbers
# A, so the fill lives in C and HL points at the data register: the
# store is LD (HL),C at 7 T. That keeps the worst case (DRQ lands just
# after a status sample) at ~46 T from DRQ to write strobe — inside the
# 56.7-T MFM byte window the DATASHEET grants (one byte time, then the
# controller substitutes 00 and flags lost data). The first cut
# reloaded A before each store (LD A,5A + LD (nn),A = 20 T) and missed
# the window by ~5 T on unlucky poll phases — one lost byte, and the
# driver hangs waiting for the 256th DRQ that never comes. trs80gp is
# more lenient than the datasheet here and forgave that loop; the RTL
# is not, on purpose (2026-07-25). Waits INTRQ; status in A.
WRDD = 0x0300
emit_block(WRDD, [
    ([0x11, 0xEC, 0x37],),
    ([0x21, 0xEF, 0x37],),                           # HL = data register
    ([0x0E, 0x5A],),                                 # C = the fill byte
    ([0x06, 0x80],),
    ([0x3E, 0xA8],), ([0x32, 0xEC, 0x37],),          # WRITE SECTOR
    ("label", "q1"),
    ([0x1A],), ([0x0F],), ([0x0F],), ([0x30], ("rel8", "q1")),
    ([0x71],),                                       # byte 1: LD (HL),C
    ("label", "q2"),
    ([0x1A],), ([0x0F],), ([0x0F],), ([0x30], ("rel8", "q2")),
    ([0x71],),                                       # byte 2
    ([0x10], ("rel8", "q1")),
    ([0x01, 0x00, 0x00],),
    ("label", "vi"),
    ([0x3A, 0xE0, 0x37],), ([0xE6, 0x40],), ([0x20], ("rel8", "vd")),
    ([0x0B],), ([0x78],), ([0xB1],), ([0x20], ("rel8", "vi")),
    ("label", "vd"),
    ([0x3A, 0xEC, 0x37],), ([0xC9],),
])

emit_block(0x0100, [
    ([0x21, 0x00, 0x3C],), ([0x11, 0x01, 0x3C],), ([0x01, 0xFF, 0x03],),
    ([0x36, 0x20],), ([0xED, 0xB0],),
    ([0x3E, 0x44],), ([0x32, 0x00, 0x3C],),          # 'D'
    ([0x3E, 0x44],), ([0x32, 0x01, 0x3C],),          # 'D'
    ([0x3E, 0x01],), ([0x32, 0xE0, 0x37],),
    ([0x01, 0x00, 0x00],),
    ("label", "spin"),
    ([0x3A, 0xEC, 0x37],), ([0xE6, 0x80],), ([0x28], ("rel8", "rdy")),
    ([0x0B],), ([0x78],), ([0xB1],), ([0x20], ("rel8", "spin")),
    ("label", "rdy"),
    ([0x3E, 0x0B],), ([0xCD, lo(DOCMD), hi(DOCMD)],),

    # ---- SD half of the mixed disk ----
    ([0x3E, 0xFE],), ([0x32, 0xEC, 0x37],),          # latch: SD
    ([0x21, 0x04, 0x3C],),
    ([0x3E, 0x01],), ([0x32, 0xE0, 0x37],),
    ([0xAF],), ([0x32, 0xEE, 0x37],),
    ([0x01, 0x00, 0x41],),
    ([0x1E, 0x88],), ([0xCD, lo(RDSEC), hi(RDSEC)],),
    ([0xCD, lo(TAGB), hi(TAGB)],),
    ([0x79],), ([0xCD, lo(TAGB), hi(TAGB)],),
    ([0xE5],), ([0x21, 0x00, 0x41],), ([0x06, 0x00],), ([0xAF],),
    ("label", "c1"),
    ([0x86],), ([0x23],), ([0x05],), ([0x20], ("rel8", "c1")),
    ([0x57],), ([0xE1],), ([0x7A],), ([0xCD, lo(TAGB), hi(TAGB)],),

    # ---- DD half ----
    ([0x3E, 0xFF],), ([0x32, 0xEC, 0x37],),          # latch: DD
    ([0x3E, 0x02],), ([0x32, 0xEF, 0x37],),
    ([0x3E, 0x1B],), ([0xCD, lo(DOCMD), hi(DOCMD)],),  # seek 2
    ([0x3E, 0x01],), ([0x32, 0xE0, 0x37],),
    ([0x3E, 0x03],), ([0x32, 0xEE, 0x37],),
    ([0x21, 0x00, 0x41],),
    ([0xCD, lo(RDDD), hi(RDDD)],),
    ([0x32, 0x80, 0x40],),                           # (4080) = status
    ([0x21, 0x00, 0x41],), ([0x06, 0x00],), ([0xAF],),
    ("label", "c2"),
    ([0x86],), ([0x23],), ([0x05],), ([0x20], ("rel8", "c2")),
    ([0x32, 0x81, 0x40],),                           # (4081) = checksum
    ([0x21, 0x44, 0x3C],),                           # NOW the tag cursor
    ([0x3A, 0x80, 0x40],), ([0xCD, lo(TAGB), hi(TAGB)],),
    ([0x3A, 0x81, 0x40],), ([0xCD, lo(TAGB), hi(TAGB)],),

    # ---- DD write + readback ----
    ([0x3E, 0x01],), ([0x32, 0xE0, 0x37],),
    ([0x3E, 0x07],), ([0x32, 0xEE, 0x37],),          # sector 7
    ([0xCD, lo(WRDD), hi(WRDD)],),
    ([0x32, 0x80, 0x40],),                           # write status
    ([0x3E, 0x01],), ([0x32, 0xE0, 0x37],),
    ([0x21, 0x00, 0x41],),
    ([0xCD, lo(RDDD), hi(RDDD)],),
    ([0x32, 0x81, 0x40],),                           # readback status
    ([0x21, 0x00, 0x41],), ([0x06, 0x00],), ([0xAF],),
    ("label", "c3"),
    ([0x86],), ([0x23],), ([0x05],), ([0x20], ("rel8", "c3")),
    ([0x32, 0x82, 0x40],),                           # readback checksum
    ([0x21, 0x84, 0x3C],),                           # tag cursor row 2
    ([0x3A, 0x80, 0x40],), ([0xCD, lo(TAGB), hi(TAGB)],),
    ([0x3A, 0x81, 0x40],), ([0xCD, lo(TAGB), hi(TAGB)],),
    ([0x3A, 0x82, 0x40],), ([0xCD, lo(TAGB), hi(TAGB)],),

    # ---- density filter: SD view of an all-MFM track = RNF ----
    ([0x3E, 0xFE],), ([0x32, 0xEC, 0x37],),          # latch: SD
    ([0x3E, 0x01],), ([0x32, 0xE0, 0x37],),
    ([0x3E, 0x03],), ([0x32, 0xEE, 0x37],),
    ([0x01, 0x00, 0x42],),
    ([0x1E, 0x88],), ([0xCD, lo(RDSEC), hi(RDSEC)],),
    ([0xCD, lo(TAGB), hi(TAGB)],),                   # status (10)
    ([0x76],),
])

with open("build/fdcddtest.hex", "w") as f:
    f.write("\n".join(f"{b:02x}" for b in img) + "\n")
with open("build/fdcddtest.bin", "wb") as f:
    f.write(img)
print("fdcddtest: image 4096 bytes")
