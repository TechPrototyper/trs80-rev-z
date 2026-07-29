#!/usr/bin/env python3
"""Build the FDC read test image (this repo's own code — NOT a Tandy ROM).

Hand-assembled Z80 for EI stage 3 (WD1771 Type II/III read): boots with a
DMK in drive 0 (build_dmk.py; trs80gp mounts the same file with -d0),
selects the drive, restores, and then

  1. reads track 0 sector 0 (256 bytes, checksummed),
  2. seeks to track 17 and reads sector 5,
  3. asks for sector 0x0B there (record-not-found path, ~1 s of index
     pulses in real time),
  4. runs Read Address and keeps its rotation-INVARIANT bytes (track,
     side, length — the sector byte depends on rotational position and
     is deliberately not tagged), plus the 1771 quirk that the ID track
     byte lands in the sector register.

Every operation starts with a drive-select rewrite (motor retrigger,
the real-DOS idiom; probed harmless in trs80gp) — without it the ~3 s
motor one-shot expires mid-sequence, index pulses stop, and the RNF
waits hang exactly like real hardware would.

Driver pattern exactly as probed against trs80gp 2.5.5 (2026-07-24):
Type I commands complete via the 37E0-bit-6 INTRQ poll; Type II/III use
the boot-ROM loop (poll status, service DRQ via bit 1, exit on busy
clear) — trs80gp shows a stale idle status for a moment right after a
command write, which this loop shape tolerates. Sector data lands at
0x4100 (read) / 0x4200 (read address); checksums are 8-bit sums.

VRAM tags (quirk-invariant hex chars; INDEX bit masked from Type I
statuses with AND 0xFD; Type II/III statuses have no INDEX bit):
  row 0 (3C00) "RD"; 3C04: rd t0/s0 status, count low, checksum
  row 1 (3C44): seek-17 status&FD, track reg, rd t17/s5 status, count,
                checksum
  row 2 (3C84): RNF status (10), RA status, RA track (11), RA side (00),
                RA length (01), sector reg after RA (11 — the quirk)

HALT then raises NMI; the handler writes the 0xBF done marker.
Outputs: fdcrdtest.hex ($readmemh, 4 KiB) and fdcrdtest.bin (raw).
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

emit_block(0x0100, [
    ([0x21, 0x00, 0x3C],), ([0x11, 0x01, 0x3C],), ([0x01, 0xFF, 0x03],),
    ([0x36, 0x20],), ([0xED, 0xB0],),                # clear screen
    ([0x3E, 0x52],), ([0x32, 0x00, 0x3C],),          # 'R'
    ([0x3E, 0x44],), ([0x32, 0x01, 0x3C],),          # 'D'
    ([0x3E, 0x01],), ([0x32, 0xE0, 0x37],),          # select drive 0
    ([0x01, 0x00, 0x00],),
    ("label", "spin"),
    ([0x3A, 0xEC, 0x37],), ([0xE6, 0x80],), ([0x28], ("rel8", "rdy")),
    ([0x0B],), ([0x78],), ([0xB1],), ([0x20], ("rel8", "spin")),
    ("label", "rdy"),
    ([0x3E, 0x0B],), ([0xCD, lo(DOCMD), hi(DOCMD)],),  # restore (h, r3)

    # ---- read t0/s0 -> tags: status, count, checksum ----
    ([0x21, 0x04, 0x3C],),                           # tag cursor row 0
    ([0x3E, 0x01],), ([0x32, 0xE0, 0x37],),          # motor retrigger
    ([0xAF],), ([0x32, 0xEE, 0x37],),                # sector = 0
    ([0x01, 0x00, 0x41],),                           # dest = 4100
    ([0x1E, 0x88],), ([0xCD, lo(RDSEC), hi(RDSEC)],),
    ([0xCD, lo(TAGB), hi(TAGB)],),                   # status
    ([0x79],), ([0xCD, lo(TAGB), hi(TAGB)],),        # count low (C)
    ([0xE5],), ([0x21, 0x00, 0x41],), ([0x06, 0x00],), ([0xAF],),
    ("label", "cs1"),
    ([0x86],), ([0x23],), ([0x05],), ([0x20], ("rel8", "cs1")),
    ([0x57],), ([0xE1],), ([0x7A],),                 # sum via D, restore HL
    ([0xCD, lo(TAGB), hi(TAGB)],),                   # checksum

    # ---- seek 17, read t17/s5 ----
    ([0x21, 0x44, 0x3C],),                           # tag cursor row 1
    ([0x3E, 0x01],), ([0x32, 0xE0, 0x37],),          # motor retrigger
    ([0x3E, 0x11],), ([0x32, 0xEF, 0x37],),          # data = 17
    ([0x3E, 0x1B],), ([0xCD, lo(DOCMD), hi(DOCMD)],),  # seek (h, r3)
    ([0xE6, 0xFD],), ([0xCD, lo(TAGB), hi(TAGB)],),  # status & FD
    ([0x3A, 0xED, 0x37],), ([0xCD, lo(TAGB), hi(TAGB)],),  # track reg
    ([0x3E, 0x01],), ([0x32, 0xE0, 0x37],),          # motor retrigger
    ([0x3E, 0x05],), ([0x32, 0xEE, 0x37],),          # sector = 5
    ([0x01, 0x00, 0x41],),
    ([0x1E, 0x88],), ([0xCD, lo(RDSEC), hi(RDSEC)],),
    ([0xCD, lo(TAGB), hi(TAGB)],),                   # status
    ([0x79],), ([0xCD, lo(TAGB), hi(TAGB)],),        # count low
    ([0xE5],), ([0x21, 0x00, 0x41],), ([0x06, 0x00],), ([0xAF],),
    ("label", "cs2"),
    ([0x86],), ([0x23],), ([0x05],), ([0x20], ("rel8", "cs2")),
    ([0x57],), ([0xE1],), ([0x7A],),
    ([0xCD, lo(TAGB), hi(TAGB)],),                   # checksum

    # ---- record not found: sector 0x0B on track 17 (~1 s) ----
    ([0x21, 0x84, 0x3C],),                           # tag cursor row 2
    ([0x3E, 0x01],), ([0x32, 0xE0, 0x37],),          # motor retrigger
    ([0x3E, 0x0B],), ([0x32, 0xEE, 0x37],),
    ([0x01, 0x00, 0x42],),                           # (unused dest)
    ([0x1E, 0x88],), ([0xCD, lo(RDSEC), hi(RDSEC)],),
    ([0xCD, lo(TAGB), hi(TAGB)],),                   # status (10)

    # ---- read address ----
    ([0x3E, 0x01],), ([0x32, 0xE0, 0x37],),          # motor retrigger
    ([0x01, 0x00, 0x42],),                           # dest = 4200
    ([0x1E, 0xC4],), ([0xCD, lo(RDSEC), hi(RDSEC)],),
    ([0xCD, lo(TAGB), hi(TAGB)],),                   # status
    ([0x3A, 0x00, 0x42],), ([0xCD, lo(TAGB), hi(TAGB)],),  # ID track
    ([0x3A, 0x01, 0x42],), ([0xCD, lo(TAGB), hi(TAGB)],),  # ID side
    ([0x3A, 0x03, 0x42],), ([0xCD, lo(TAGB), hi(TAGB)],),  # ID length
    ([0x3A, 0xEE, 0x37],), ([0xCD, lo(TAGB), hi(TAGB)],),  # sector (quirk)
    ([0x76],),
])

with open("build/fdcrdtest.hex", "w") as f:
    f.write("\n".join(f"{b:02x}" for b in img) + "\n")
with open("build/fdcrdtest.bin", "wb") as f:
    f.write(img)
print("fdcrdtest: image 4096 bytes")
