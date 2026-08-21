#!/usr/bin/env python3
"""Build the NEWDOS/80-shaped read-loop probe (this repo's own code — NOT
a Tandy ROM, and no NEWDOS code: only the *shape* of the driver's
polling idiom is reproduced, as observed in a RAM disassembly of a live
system).

Why this exists: NEWDOS/80's resident sector reader (observed at
0x46C3..0x4739 on a live AJ6 system) differs from the boot-ROM loop the
earlier probes used. Its idiom:

  - seek setup: sector -> 37EE, target -> 37EF, cmd 0x18, then a
    delay-12-then-status poll until busy clears (no 37E0 INTRQ poll)
  - the TRACK REGISTER is then written directly (logical track)
  - motor/drive latch refresh via a write to 0x37E1 (the 37E0-37E3
    window)
  - read 0x88, then: delay-12 + one status read, DI,
    busy? -> `LD A,83h / AND (HL) / JP po` entry poll,
    per-byte: LD A,(DE) / LD (BC),A / INC BC with a triple BIT 1,(HL)
    cascade, a busy exit, and a NOT-READY check looping back
  - final status read, then Force Interrupt (0xD0)

The probe replays exactly that shape against the four-DAM disk
(build_dmk.py --damtrk 2): read t0/s0 (DAM FB) and t2/s3 (DAM F8), tag
each final status, the buffer cursor low byte, and an 8-bit checksum.
Golden: the same image + disk in trs80gp (make golden-fdc-nd).

VRAM tags (hex chars): row 0 (3C00) "ND";
  3C04: t0/s0 status, count low, checksum, then t2/s3 status, count
  low, checksum.

HALT then raises NMI; the handler writes the 0xBF done marker.
Outputs: fdcndtest.hex ($readmemh, 4 KiB) and fdcndtest.bin (raw).
"""

img = bytearray(0x1000)


def emit(addr, byts, mnemonic=""):
    for i, b in enumerate(byts):
        assert img[addr + i] == 0, f"overlap at {addr+i:04X}"
        img[addr + i] = b
    return addr + len(byts)


def emit_block(addr, prog):
    """Two-pass mini assembler (chapter-7 idiom), plus ("patch16", label)
    items that emit an absolute little-endian label address."""
    labels, pc = {}, addr
    for item in prog:
        if item[0] == "label":
            labels[item[1]] = pc
        elif item[0] == "patch16":
            pc += 2
        else:
            pc += len(item[0]) + (1 if len(item) > 1
                                  and isinstance(item[1], tuple) else 0)
    pc = addr
    for item in prog:
        if item[0] == "label":
            continue
        if item[0] == "patch16":
            t = labels[item[1]]
            img[pc] = t & 0xFF
            img[pc + 1] = t >> 8
            pc += 2
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


TAGB, HEXN, DLY12 = 0x0300, 0x0320, 0x0340


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

# DLY12: the driver's delay-12-then-read-status helper (47E3 shape):
# LD A,12; DEC A; JR NZ,-1; LD A,(37EC); RET
emit(DLY12, [0x3E, 0x0C, 0x3D, 0x20, 0xFD, 0x3A, 0xEC, 0x37, 0xC9])


def nd_read(t, s):
    """One NEWDOS-shaped sector read into 0x4100. Entry: HL = VRAM tag
    cursor. Exit: status tagged, BC = one past the last stored byte."""
    return [
        # motor/drive latch refresh via 0x37E1 (the 4767 idiom)
        ([0x3E, 0x01],), ([0x32, 0xE1, 0x37],),
        # sector -> 37EE, seek target -> 37EF, SEEK 0x18 (h set, rate 0)
        ([0x3E, s],),    ([0x32, 0xEE, 0x37],),
        ([0x3E, t],),    ([0x32, 0xEF, 0x37],),
        ([0x3E, 0x18],), ([0x32, 0xEC, 0x37],),
        ("label", f"sk{t}_{s}"),
        ([0xCD, lo(DLY12), hi(DLY12)],),            # delay + status
        ([0xCB, 0x47],),                            # BIT 0,A (busy)
        ([0x20], ("rel8", f"sk{t}_{s}")),
        # track register written directly (the 46B9 idiom)
        ([0x3E, t],),    ([0x32, 0xED, 0x37],),
        ([0x3E, 0x01],), ([0x32, 0xE1, 0x37],),     # motor refresh
        # transfer core, register-for-register like 46C0..4719
        ([0xE5],),                                  # save tag cursor
        ([0x21, 0xEC, 0x37],),                      # HL = status/cmd
        ([0x11, 0xEF, 0x37],),                      # DE = data reg
        ([0x01, 0x00, 0x41],),                      # BC = buffer 4100
        ([0x36, 0x88],),                            # LD (HL),88h  READ
        ([0xCD, lo(DLY12), hi(DLY12)],),            # delay-12 + status
        ([0xF3],),                                  # DI
        ([0xCB, 0x46],),                            # BIT 0,(HL) busy?
        ([0x28], ("rel8", f"dn{t}_{s}")),
        ("label", f"pl{t}_{s}"),
        ([0x3E, 0x83],), ([0xA6],),                 # LD A,83h; AND (HL)
        ([0xE2],), ("patch16", f"pl{t}_{s}"),       # JP po,poll
        ("label", f"xf{t}_{s}"),
        ([0x1A],), ([0x02],), ([0x03],),            # (DE)->(BC), INC BC
        ("label", f"ck{t}_{s}"),
        ([0xCB, 0x4E],), ([0x20], ("rel8", f"xf{t}_{s}")),
        ([0xCB, 0x4E],), ([0x20], ("rel8", f"xf{t}_{s}")),
        ([0xCB, 0x4E],), ([0x20], ("rel8", f"xf{t}_{s}")),
        ([0xCB, 0x46],), ([0x28], ("rel8", f"dn{t}_{s}")),
        ([0xCB, 0x4E],), ([0x20], ("rel8", f"xf{t}_{s}")),
        ([0xCB, 0x7E],), ([0x28], ("rel8", f"ck{t}_{s}")),
        ("label", f"dn{t}_{s}"),
        ([0x7E],),                                  # A = final status
        ([0x36, 0xD0],),                            # Force Interrupt
        ([0xFB],),                                  # EI
        ([0xE1],),                                  # restore tag cursor
        ([0xCD, lo(TAGB), hi(TAGB)],),              # tag status
    ]


def tag_count_checksum(tag):
    """Tag C (count low), then the 8-bit sum over 4100..41FF."""
    return [
        ([0x79],), ([0xCD, lo(TAGB), hi(TAGB)],),   # count low
        ([0xE5],), ([0x21, 0x00, 0x41],), ([0x06, 0x00],), ([0xAF],),
        ("label", f"cs{tag}"),
        ([0x86],), ([0x23],), ([0x05],), ([0x20], ("rel8", f"cs{tag}")),
        ([0x57],), ([0xE1],), ([0x7A],),
        ([0xCD, lo(TAGB), hi(TAGB)],),
    ]


prog = [
    ([0x21, 0x00, 0x3C],), ([0x11, 0x01, 0x3C],), ([0x01, 0xFF, 0x03],),
    ([0x36, 0x20],), ([0xED, 0xB0],),               # clear screen
    ([0x3E, 0x4E],), ([0x32, 0x00, 0x3C],),         # 'N'
    ([0x3E, 0x44],), ([0x32, 0x01, 0x3C],),         # 'D'
    ([0x3E, 0x01],), ([0x32, 0xE1, 0x37],),         # select drive 0 (37E1)
    ([0x01, 0x00, 0x00],),
    ("label", "spin"),
    ([0x3A, 0xEC, 0x37],), ([0xE6, 0x80],), ([0x28], ("rel8", "rdy")),
    ([0x0B],), ([0x78],), ([0xB1],), ([0x20], ("rel8", "spin")),
    ("label", "rdy"),
    # restore, polled NEWDOS-style (status busy bit, not 37E0 INTRQ)
    ([0x3E, 0x0B],), ([0x32, 0xEC, 0x37],),
    ("label", "rst"),
    ([0xCD, lo(DLY12), hi(DLY12)],),
    ([0xCB, 0x47],), ([0x20], ("rel8", "rst")),
    ([0x21, 0x04, 0x3C],),                          # tag cursor row 0
]
prog += nd_read(0, 0)
prog += tag_count_checksum("a")
prog += nd_read(2, 3)
prog += tag_count_checksum("b")
prog += [([0x76],)]

emit_block(0x0100, prog)

with open("build/fdcndtest.hex", "w") as f:
    f.write("\n".join(f"{b:02x}" for b in img) + "\n")
with open("build/fdcndtest.bin", "wb") as f:
    f.write(img)
print("fdcndtest: image 4096 bytes")
