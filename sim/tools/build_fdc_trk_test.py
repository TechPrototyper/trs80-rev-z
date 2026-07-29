#!/usr/bin/env python3
"""Build the track-access test image (EI stage 6a — this repo's own code).

Scenario, identical on our machine and in trs80gp:
  1. select drive 0, restore, seek track 2, READ TRACK (0xE4): the raw
     track bytes (gaps, ID fields, CRCs — everything) stream through the
     DRQ pull; tags: status (end bits masked) and count high byte. This
     is the Trakcess primitive. NOTE (probed 2026-07-24): the exact byte
     STREAM of an FM raw read is implementation-defined — resync at
     address marks reframes gap bytes, and trs80gp's stream is neither
     our stored bytes nor any fixed offset of them; real 1771s vary with
     sync state too. So the stream content is deliberately NOT a golden
     tag; byte-exactness of our buffer is covered by the sector reads.
  2. seek track 30, WRITE TRACK (0xF4): a minimal 2-sector FM format fed
     byte-wise — lead-in 16xFF, then per sector s=0/1: 6x00, FE 1E 00 s
     01, F7 (the 1771 emits both ID CRC bytes for one F7), 11xFF 6x00,
     FB, 256xE5, F7, 10xFF — then FF filler until the controller ends
     the revolution. Tag: status only (the exact fed count depends on
     the emulator's revolution length and is not contract).
  3. READ SECTOR t30/s0 and t30/s1 back: status, count, checksum
     (256xE5 sums to 00) — the fresh format is immediately usable.

Sector data results land in registers only (RDTRK keeps a running sum);
motor retriggers precede every operation (the real-DOS idiom).
Outputs: fdctrktest.hex ($readmemh, 4 KiB) and fdctrktest.bin (raw).
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


# FEEDC at 0x02C0: feed C when DRQ. Carry protocol (tight enough for
# the 64 us cadence: worst path ~57 us incl. caller): carry SET on
# return = the command ended, clear = byte fed.
FEEDC = 0x02C0
emit_block(FEEDC, [
    ("label", "f1"),
    ([0x3A, 0xEC, 0x37],),                           # status
    ([0x0F],), ([0x30], ("rel8", "f2")),             # busy gone -> ended
    ([0x0F],), ([0x30], ("rel8", "f1")),             # no DRQ yet
    ([0x79],), ([0x32, 0xEF, 0x37],),                # data = C
    ([0xB7],),                                       # carry clear: fed
    ([0xC9],),
    ("label", "f2"),
    ([0x37],),                                       # SCF: ended
    ([0xC9],),
])

# FEED: one byte from A (sections with mixed values)
FEED = 0x02D8
emit_block(FEED, [
    ([0x4F],), ([0xC3, lo(FEEDC), hi(FEEDC)],),
])

# FEEDN at 0x02E0: feed B bytes of value E (early-out when ended)
FEEDN = 0x02E0
emit_block(FEEDN, [
    ([0x4B],),                                       # C = E
    ("label", "n1"),
    ([0xCD, lo(FEEDC), hi(FEEDC)],),
    ([0xD8],),                                       # ended: ret C
    ([0x10], ("rel8", "n1")),                        # DJNZ
    ([0xB7],),                                       # carry clear
    ([0xC9],),
])

# SECT at 0x0300: format one sector, sector id in L (clobbers A,B,C,D,E)
SECT = 0x0300
emit_block(SECT, [
    ([0x06, 0x06],), ([0x1E, 0x00],), ([0xCD, lo(FEEDN), hi(FEEDN)],), ([0xD8],),
    ([0x3E, 0xFE],), ([0xCD, lo(FEED), hi(FEED)],), ([0xD8],),
    ([0x3E, 0x1E],), ([0xCD, lo(FEED), hi(FEED)],), ([0xD8],),   # track 30
    ([0x3E, 0x00],), ([0xCD, lo(FEED), hi(FEED)],), ([0xD8],),   # side
    ([0x7D],),       ([0xCD, lo(FEED), hi(FEED)],), ([0xD8],),   # sector L
    ([0x3E, 0x01],), ([0xCD, lo(FEED), hi(FEED)],), ([0xD8],),   # len 256
    ([0x3E, 0xF7],), ([0xCD, lo(FEED), hi(FEED)],), ([0xD8],),   # ID CRC
    ([0x06, 0x0B],), ([0x1E, 0xFF],), ([0xCD, lo(FEEDN), hi(FEEDN)],), ([0xD8],),
    ([0x06, 0x06],), ([0x1E, 0x00],), ([0xCD, lo(FEEDN), hi(FEEDN)],), ([0xD8],),
    ([0x3E, 0xFB],), ([0xCD, lo(FEED), hi(FEED)],), ([0xD8],),   # DAM
    ([0x06, 0x00],), ([0x1E, 0xE5],), ([0xCD, lo(FEEDN), hi(FEEDN)],), ([0xD8],),
    ([0x3E, 0xF7],), ([0xCD, lo(FEED), hi(FEED)],), ([0xD8],),   # data CRC
    ([0x06, 0x0A],), ([0x1E, 0xFF],), ([0xCD, lo(FEEDN), hi(FEEDN)],),
    ([0xC9],),
])

# RDTRK at 0x0370: issue 0xE4; count in BC, 8-bit sum over the FIRST
# 1024 bytes in L (the track tail length varies with drive speed — real
# drives are +-1.5% — so only the head is contract); A = final status
RDTRK = 0x0370
emit_block(RDTRK, [
    ([0x01, 0x00, 0x00],),
    ([0x2E, 0x00],),
    ([0x3E, 0xE4],), ([0x32, 0xEC, 0x37],),
    ("label", "t1"),
    ([0x3A, 0xEC, 0x37],),
    ([0x0F],), ([0x30], ("rel8", "t2")),             # busy gone
    ([0x0F],), ([0x30], ("rel8", "t1")),             # no DRQ
    ([0x3A, 0xEF, 0x37],), ([0x5F],),                # E = data byte
    ([0x78],), ([0xFE, 0x04],),                      # count < 0x400 ?
    ([0x7B],), ([0x30], ("rel8", "t3")),
    ([0x85],), ([0x6F],),                            # L += byte
    ("label", "t3"),
    ([0x03],),
    ([0x18], ("rel8", "t1")),
    ("label", "t2"),
    ([0x3A, 0xEC, 0x37],), ([0xC9],),                # settle + status
])

emit_block(0x0100, [
    ([0x21, 0x00, 0x3C],), ([0x11, 0x01, 0x3C],), ([0x01, 0xFF, 0x03],),
    ([0x36, 0x20],), ([0xED, 0xB0],),
    ([0x3E, 0x54],), ([0x32, 0x00, 0x3C],),          # 'T'
    ([0x3E, 0x4B],), ([0x32, 0x01, 0x3C],),          # 'K'
    ([0x3E, 0x01],), ([0x32, 0xE0, 0x37],),
    ([0x01, 0x00, 0x00],),
    ("label", "spin"),
    ([0x3A, 0xEC, 0x37],), ([0xE6, 0x80],), ([0x28], ("rel8", "rdy")),
    ([0x0B],), ([0x78],), ([0xB1],), ([0x20], ("rel8", "spin")),
    ("label", "rdy"),
    ([0x3E, 0x0B],), ([0xCD, lo(DOCMD), hi(DOCMD)],),

    # ---- read track 2 raw ----
    ([0x3E, 0x02],), ([0x32, 0xEF, 0x37],),
    ([0x3E, 0x1B],), ([0xCD, lo(DOCMD), hi(DOCMD)],),
    ([0x3E, 0x01],), ([0x32, 0xE0, 0x37],),
    ([0xCD, lo(RDTRK), hi(RDTRK)],),
    ([0xE6, 0xF9],),                                 # mask DRQ+lost: the
    ([0x32, 0x80, 0x40],),                           # end-of-track bits
    ([0x78],), ([0x32, 0x81, 0x40],),                # count hi only
    ([0x21, 0x04, 0x3C],),
    ([0x3A, 0x80, 0x40],), ([0xCD, lo(TAGB), hi(TAGB)],),
    ([0x3A, 0x81, 0x40],), ([0xCD, lo(TAGB), hi(TAGB)],),

    # ---- write track 30 (mini format) ----
    ([0x3E, 0x1E],), ([0x32, 0xEF, 0x37],),
    ([0x3E, 0x1B],), ([0xCD, lo(DOCMD), hi(DOCMD)],),  # seek 30
    ([0x3E, 0x01],), ([0x32, 0xE0, 0x37],),
    ([0x3E, 0xF4],), ([0x32, 0xEC, 0x37],),          # WRITE TRACK
    ([0x06, 0x10],), ([0x1E, 0xFF],), ([0xCD, lo(FEEDN), hi(FEEDN)],),  # lead-in
    ([0x2E, 0x00],), ([0xCD, lo(SECT), hi(SECT)],),  # sector 0
    ([0x2E, 0x01],), ([0xCD, lo(SECT), hi(SECT)],),  # sector 1
    ([0x0E, 0xFF],),                                 # C = filler
    ("label", "fill"),
    ([0xCD, lo(FEEDC), hi(FEEDC)],),                 # feed to the index
    ([0x30], ("rel8", "fill")),
    ([0x21, 0x44, 0x3C],),
    ([0x3A, 0xEC, 0x37],), ([0xE6, 0xFB],),          # mask lost: the tail
    ([0xCD, lo(TAGB), hi(TAGB)],),                   # filler byte timing
                                                     # is not contract

    # ---- read the fresh sectors back ----
    ([0x3E, 0x01],), ([0x32, 0xE0, 0x37],),
    ([0xAF],), ([0x32, 0xEE, 0x37],),
    ([0x01, 0x00, 0x41],),
    ([0x1E, 0x88],), ([0xCD, lo(RDSEC), hi(RDSEC)],),
    ([0xCD, lo(TAGB), hi(TAGB)],),
    ([0x79],), ([0xCD, lo(TAGB), hi(TAGB)],),
    ([0xE5],), ([0x21, 0x00, 0x41],), ([0x06, 0x00],), ([0xAF],),
    ("label", "cs1"),
    ([0x86],), ([0x23],), ([0x05],), ([0x20], ("rel8", "cs1")),
    ([0x57],), ([0xE1],), ([0x7A],),
    ([0xCD, lo(TAGB), hi(TAGB)],),
    ([0x3E, 0x01],), ([0x32, 0xEE, 0x37],),
    ([0x01, 0x00, 0x41],),
    ([0x1E, 0x88],), ([0xCD, lo(RDSEC), hi(RDSEC)],),
    ([0xCD, lo(TAGB), hi(TAGB)],),
    ([0x76],),
])

with open("build/fdctrktest.hex", "w") as f:
    f.write("\n".join(f"{b:02x}" for b in img) + "\n")
with open("build/fdctrktest.bin", "wb") as f:
    f.write(img)
print("fdctrktest: image 4096 bytes")
