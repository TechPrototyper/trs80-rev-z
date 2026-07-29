#!/usr/bin/env python3
"""Build the FDC write test image (this repo's own code — NOT a Tandy ROM).

EI stage 5b scenario, identical on our machine and in trs80gp:

  1. select drive 0, restore, seek track 2
  2. WRITE sector 3: 256 bytes, byte i = (0x11 + 3*i) & 0xFF, fed through
     the DRQ pull (boot-ROM loop shape, write direction)
  3. read sector 3 back -> status/count/checksum tags (from the TRACK
     BUFFER — proves the in-buffer write)
  4. seek track 5 and read t5/s0 (evicts the dirty buffer -> the
     write-back travels down the media chain), seek back to track 2,
     read sector 3 again -> tags (now re-FETCHED from the media — proves
     the write-back arrived)

On a write-protected disk (+wp variants) step 2 must refuse with status
0x40 and the readbacks show the ORIGINAL generator pattern (t2/s3
checksum 97 from build_dmk.py).

Motor retriggers before every operation (the real-DOS idiom, probed).

VRAM tags: row 0 "WS" + write status, write count low; row 1 readback
status/count/checksum (buffer); row 2 readback status/count/checksum
(after eviction + reload). Expected pattern checksum: sum((0x11+3i)&FF)
= computed by this script and printed.

HALT raises NMI; the handler writes the 0xBF done marker.
Outputs: fdcwrtest.hex ($readmemh, 4 KiB) and fdcwrtest.bin (raw).
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


# WRSEC at 0x02A0: E = command; feed bytes via DRQ, byte walks A += 3
# from 0x11; returns final status in A, count low in C
WRSEC = 0x02A0
emit_block(WRSEC, [
    ([0x06, 0x11],),                                 # B = next byte
    ([0x0E, 0x00],),                                 # C = count
    ([0x7B],), ([0x32, 0xEC, 0x37],),                # command = E
    ("label", "wl"),
    ([0x3A, 0xEC, 0x37],), ([0x57],),                # D = status
    ([0x0F],), ([0x30], ("rel8", "wd")),             # busy clear -> done
    ([0x7A],), ([0xCB, 0x4F],), ([0x28], ("rel8", "wl")),   # DRQ?
    ([0x78],), ([0x32, 0xEF, 0x37],),                # data = B
    ([0x78],), ([0xC6, 0x03],), ([0x47],),           # B += 3
    ([0x0C],),                                       # C++
    ([0x18], ("rel8", "wl")),
    ("label", "wd"),
    ([0x7A],), ([0xC9],),
])

emit_block(0x0100, [
    ([0x21, 0x00, 0x3C],), ([0x11, 0x01, 0x3C],), ([0x01, 0xFF, 0x03],),
    ([0x36, 0x20],), ([0xED, 0xB0],),                # clear screen
    ([0x3E, 0x57],), ([0x32, 0x00, 0x3C],),          # 'W'
    ([0x3E, 0x53],), ([0x32, 0x01, 0x3C],),          # 'S'
    ([0x3E, 0x01],), ([0x32, 0xE0, 0x37],),          # select drive 0
    ([0x01, 0x00, 0x00],),
    ("label", "spin"),
    ([0x3A, 0xEC, 0x37],), ([0xE6, 0x80],), ([0x28], ("rel8", "rdy")),
    ([0x0B],), ([0x78],), ([0xB1],), ([0x20], ("rel8", "spin")),
    ("label", "rdy"),
    ([0x3E, 0x0B],), ([0xCD, lo(DOCMD), hi(DOCMD)],),  # restore
    ([0x3E, 0x02],), ([0x32, 0xEF, 0x37],),          # data = 2
    ([0x3E, 0x1B],), ([0xCD, lo(DOCMD), hi(DOCMD)],),  # seek 2

    # ---- write t2/s3 ----
    ([0x21, 0x04, 0x3C],),                           # tag cursor row 0
    ([0x3E, 0x01],), ([0x32, 0xE0, 0x37],),          # motor retrigger
    ([0x3E, 0x03],), ([0x32, 0xEE, 0x37],),          # sector = 3
    ([0x1E, 0xA8],), ([0xCD, lo(WRSEC), hi(WRSEC)],),
    ([0xCD, lo(TAGB), hi(TAGB)],),                   # write status
    ([0x79],), ([0xCD, lo(TAGB), hi(TAGB)],),        # bytes fed

    # ---- read back from the (dirty) buffer ----
    ([0x21, 0x44, 0x3C],),
    ([0x3E, 0x01],), ([0x32, 0xE0, 0x37],),
    ([0x01, 0x00, 0x41],),
    ([0x1E, 0x88],), ([0xCD, lo(RDSEC), hi(RDSEC)],),
    ([0xCD, lo(TAGB), hi(TAGB)],),
    ([0x79],), ([0xCD, lo(TAGB), hi(TAGB)],),
    ([0xE5],), ([0x21, 0x00, 0x41],), ([0x06, 0x00],), ([0xAF],),
    ("label", "cs1"),
    ([0x86],), ([0x23],), ([0x05],), ([0x20], ("rel8", "cs1")),
    ([0x57],), ([0xE1],), ([0x7A],),
    ([0xCD, lo(TAGB), hi(TAGB)],),

    # ---- evict (t5 read), return, read again ----
    ([0x21, 0x84, 0x3C],),
    ([0x3E, 0x01],), ([0x32, 0xE0, 0x37],),
    ([0x3E, 0x05],), ([0x32, 0xEF, 0x37],),
    ([0x3E, 0x1B],), ([0xCD, lo(DOCMD), hi(DOCMD)],),  # seek 5
    ([0xAF],), ([0x32, 0xEE, 0x37],),                # sector = 0
    ([0x01, 0x00, 0x41],),
    ([0x1E, 0x88],), ([0xCD, lo(RDSEC), hi(RDSEC)],),  # forces flush+fetch
    ([0x3E, 0x01],), ([0x32, 0xE0, 0x37],),
    ([0x3E, 0x02],), ([0x32, 0xEF, 0x37],),
    ([0x3E, 0x1B],), ([0xCD, lo(DOCMD), hi(DOCMD)],),  # back to 2
    ([0x3E, 0x03],), ([0x32, 0xEE, 0x37],),
    ([0x01, 0x00, 0x41],),
    ([0x1E, 0x88],), ([0xCD, lo(RDSEC), hi(RDSEC)],),  # re-fetched track
    ([0xCD, lo(TAGB), hi(TAGB)],),
    ([0x79],), ([0xCD, lo(TAGB), hi(TAGB)],),
    ([0xE5],), ([0x21, 0x00, 0x41],), ([0x06, 0x00],), ([0xAF],),
    ("label", "cs2"),
    ([0x86],), ([0x23],), ([0x05],), ([0x20], ("rel8", "cs2")),
    ([0x57],), ([0xE1],), ([0x7A],),
    ([0xCD, lo(TAGB), hi(TAGB)],),
    ([0x76],),
])

with open("build/fdcwrtest.hex", "w") as f:
    f.write("\n".join(f"{b:02x}" for b in img) + "\n")
with open("build/fdcwrtest.bin", "wb") as f:
    f.write(img)
cs = sum((0x11 + 3 * i) & 0xFF for i in range(256)) & 0xFF
print(f"fdcwrtest: image 4096 bytes; pattern checksum {cs:02X}")
