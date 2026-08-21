#!/usr/bin/env python3
"""Build the cassette WRITE probe (this repo's own code — NOT a Tandy ROM).

M2 write path: bit-bangs a 500-baud tape onto port 0xFF the way the
Level II CSAVE routine does — for each pulse the output ladder swings
positive (OUT 01), negative (OUT 02) and back to center (OUT 00), each
phase ~90 us; a bit cell is 2 ms with the clock pulse at the start and
a data pulse mid-cell for '1'. Motor stays on throughout (D2).

Stream written: 8 x 0x00 leader, 0xA5 sync, then the standard 16-byte
payload (t*13+7). The deck model records the positive spikes;
tools/check_cass_write.py decodes them back to bytes and compares.

VRAM tags: row 0 (3C00) "CW"; 3C04: payload checksum (88).
HALT then raises NMI; the handler writes the 0xBF done marker.
Outputs: casswtest.hex ($readmemh, 4 KiB) and casswtest.bin (raw).
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


TAGB, HEXN, PULSE, D820, WRBIT, WRBYTE = \
    0x0200, 0x0220, 0x0240, 0x0260, 0x0280, 0x02B0


def lo(x): return x & 0xFF
def hi(x): return x >> 8


emit(0x0000, [0xF3, 0x31, 0xFF, 0x7F, 0xC3, 0x00, 0x01],
     "DI; LD SP,7FFFh; JP 0100h")
emit(0x0066, [0x3E, 0xBF, 0x32, 0xFF, 0x3F, 0x18, 0xFE],
     "NMI: done marker, spin")

emit(TAGB, [0xF5, 0x0F, 0x0F, 0x0F, 0x0F, 0xCD, lo(HEXN), hi(HEXN),
            0x77, 0x23, 0xF1, 0xCD, lo(HEXN), hi(HEXN), 0x77, 0x23, 0xC9])
emit(HEXN, [0xE6, 0x0F, 0xC6, 0x30, 0xFE, 0x3A, 0x38, 0x02,
            0xC6, 0x07, 0xC9])

# PULSE: positive ~90us, negative ~90us, back to center; motor kept on
emit_block(PULSE, [
    ([0x3E, 0x05],), ([0xD3, 0xFF],),    # OUT 05h: level 01 + motor
    ([0x06, 0x0C],),                     # ~12 x 13T = 88 us
    ("label", "p1"), ([0x10], ("rel8", "p1")),
    ([0x3E, 0x06],), ([0xD3, 0xFF],),    # OUT 06h: level 10 + motor
    ([0x06, 0x0C],),
    ("label", "p2"), ([0x10], ("rel8", "p2")),
    ([0x3E, 0x04],), ([0xD3, 0xFF],),    # OUT 04h: center + motor
    ([0xC9],),
])

# D820: ~820 us (111 x 13T)
emit_block(D820, [
    ([0x06, 0x6F],),
    ("label", "d1"), ([0x10], ("rel8", "d1")),
    ([0xC9],),
])

# WRBIT: CY = bit. Clock pulse, mid-cell data pulse for '1', pad to 2 ms.
emit_block(WRBIT, [
    ([0xF5],),                            # save the bit (in CY via AF)
    ([0xCD, lo(PULSE), hi(PULSE)],),      # clock pulse (~180 us)
    ([0xCD, lo(D820), hi(D820)],),        # -> ~1 ms
    ([0xF1],),                            # restore CY
    ([0x30], ("rel8", "b0")),
    ([0xCD, lo(PULSE), hi(PULSE)],),      # data pulse
    ([0x18], ("rel8", "bt")),
    ("label", "b0"),
    ([0xCD, lo(D820), hi(D820)],),        # '0': idle where data would be
    ([0x06, 0x1A],),                      # trim ~150us: pulse-vs-delay skew
    ("label", "b2"), ([0x10], ("rel8", "b2")),
    ([0x18], ("rel8", "bx")),
    ("label", "bt"),
    ("label", "bx"),
    ([0xCD, lo(D820), hi(D820)],),        # -> ~2 ms
    ([0xC9],),
])

# WRBYTE: A, MSB first
emit_block(WRBYTE, [
    ([0x57],),                            # D = byte
    ([0x1E, 0x08],),                      # E = 8
    ("label", "wb"),
    ([0xCB, 0x12],),                      # RL D (MSB -> CY)
    ([0xCD, lo(WRBIT), hi(WRBIT)],),
    ([0x1D],),
    ([0x20], ("rel8", "wb")),
    ([0xC9],),
])

emit_block(0x0100, [
    ([0x21, 0x00, 0x3C],), ([0x11, 0x01, 0x3C],), ([0x01, 0xFF, 0x03],),
    ([0x36, 0x20],), ([0xED, 0xB0],),                # clear screen
    ([0x3E, 0x43],), ([0x32, 0x00, 0x3C],),          # 'C'
    ([0x3E, 0x57],), ([0x32, 0x01, 0x3C],),          # 'W'
    ([0x3E, 0x04],), ([0xD3, 0xFF],),                # motor on
    # ~50 ms of settled motor before the first pulse
    ([0x11, 0x00, 0x1A],),
    ("label", "mt"),
    ([0x1B],), ([0x7A],), ([0xB3],), ([0x20], ("rel8", "mt")),
    # ---- leader: 8 x 00 ----
    ([0x3E, 0x08],), ([0x32, 0x80, 0x41],),
    ("label", "ld"),
    ([0xAF],), ([0xCD, lo(WRBYTE), hi(WRBYTE)],),
    ([0x3A, 0x80, 0x41],), ([0x3D],), ([0x32, 0x80, 0x41],),
    ([0x20], ("rel8", "ld")),
    # ---- sync ----
    ([0x3E, 0xA5],), ([0xCD, lo(WRBYTE), hi(WRBYTE)],),
    # ---- payload: A = t*13+7, running in (4181); checksum in (4182) ----
    ([0xAF],), ([0x32, 0x82, 0x41],),
    ([0x3E, 0x10],), ([0x32, 0x80, 0x41],),          # count = 16
    ([0x3E, 0x07],), ([0x32, 0x81, 0x41],),          # value = 7
    ("label", "pl"),
    ([0x3A, 0x81, 0x41],),
    ([0xCD, lo(WRBYTE), hi(WRBYTE)],),
    ([0x3A, 0x82, 0x41],), ([0x47],),                # B = csum
    ([0x3A, 0x81, 0x41],), ([0x80],), ([0x32, 0x82, 0x41],),
    ([0x3A, 0x81, 0x41],), ([0xC6, 0x0D],), ([0x32, 0x81, 0x41],),
    ([0x3A, 0x80, 0x41],), ([0x3D],), ([0x32, 0x80, 0x41],),
    ([0x20], ("rel8", "pl")),
    # ---- tag the checksum, stop the motor, halt ----
    ([0x21, 0x04, 0x3C],),
    ([0x3A, 0x82, 0x41],), ([0xCD, lo(TAGB), hi(TAGB)],),
    ([0xAF],), ([0xD3, 0xFF],),                      # motor off
    ([0x76],),
])

with open("build/casswtest.hex", "w") as f:
    f.write("\n".join(f"{b:02x}" for b in img) + "\n")
with open("build/casswtest.bin", "wb") as f:
    f.write(img)
print("casswtest: image 4096 bytes")
