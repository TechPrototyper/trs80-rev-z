#!/usr/bin/env python3
"""Build the cassette read probe (this repo's own code — NOT a Tandy ROM).

M2 stage 1: reads the 500-baud test tape (tools/build_cas.py) through
port 0xFF the way period software does — poll D7 (the Z24 input latch),
reset it with an OUT that keeps the motor running, and classify pulse
gaps. Per bit cell: wait for the clock pulse, then open a ~1.5 ms
window; a pulse inside the window is a '1', a timeout a '0' (the next
clock is caught by the following cell's wait). Bits shift MSB first
into a sync register until 0xA5 appears, then 16 payload bytes are
captured.

VRAM tags (hex chars): row 0 (3C00) "CA"; 3C04: the 16 payload bytes,
then their 8-bit sum. Expected for the standard test tape:
0714212E3B485562 6F7C8996A3B0BDCA, checksum 88.

HALT then raises NMI; the handler writes the 0xBF done marker.
Outputs: casstest.hex ($readmemh, 4 KiB) and casstest.bin (raw).
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


TAGB, HEXN, WPULSE, RDBIT, RDBYTE = 0x0200, 0x0220, 0x0240, 0x0270, 0x02A0


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

# WPULSE: BC = timeout polls (0 = 65536); returns CY=1 pulse seen (and
# the latch reset, motor kept on), CY=0 timeout. ~48 T per poll (~27 us).
emit_block(WPULSE, [
    ("label", "wp"),
    ([0xDB, 0xFF],),                     # IN A,(FF)
    ([0x17],),                           # RLA (D7 -> CY)
    ([0x38], ("rel8", "got")),
    ([0x0B],), ([0x78],), ([0xB1],),     # DEC BC; A=B|C
    ([0x20], ("rel8", "wp")),
    ([0xB7],), ([0xC9],),                # OR A (CY=0); RET
    ("label", "got"),
    ([0x3E, 0x04],), ([0xD3, 0xFF],),    # OUT (FF),04h: reset latch, motor on
    ([0x37],), ([0xC9],),                # SCF; RET
])

# RDBIT: one bit cell -> CY = bit. Wait for the clock pulse (no
# timeout), then a ~1.5 ms data window (55 polls x ~27 us).
emit_block(RDBIT, [
    ([0x01, 0x00, 0x00],),               # BC = 0: wait for clock
    ([0xCD, lo(WPULSE), hi(WPULSE)],),
    ([0x01, 0x37, 0x00],),               # BC = 55: data window
    ([0xCD, lo(WPULSE), hi(WPULSE)],),
    ([0xC9],),                           # CY = data pulse seen
])

# RDBYTE: 8 bits MSB first -> A. E counts (BC is WPULSE's timeout reg).
emit_block(RDBYTE, [
    ([0x16, 0x00],),                     # D = 0 (shifter)
    ([0x1E, 0x08],),                     # E = 8
    ("label", "nb"),
    ([0xCD, lo(RDBIT), hi(RDBIT)],),
    ([0xCB, 0x12],),                     # RL D (CY in)
    ([0x1D],),                           # DEC E
    ([0x20], ("rel8", "nb")),
    ([0x7A],), ([0xC9],),                # A = D
])

emit_block(0x0100, [
    ([0x21, 0x00, 0x3C],), ([0x11, 0x01, 0x3C],), ([0x01, 0xFF, 0x03],),
    ([0x36, 0x20],), ([0xED, 0xB0],),                # clear screen
    ([0x3E, 0x43],), ([0x32, 0x00, 0x3C],),          # 'C'
    ([0x3E, 0x41],), ([0x32, 0x01, 0x3C],),          # 'A'
    ([0x3E, 0x04],), ([0xD3, 0xFF],),                # motor on, latch clear
    # ---- bit-sync on the leader until 0xA5 shows up in D ----
    ([0x16, 0x00],),                                 # D = sync shifter
    ("label", "sy"),
    ([0xCD, lo(RDBIT), hi(RDBIT)],),
    ([0xCB, 0x12],),                                 # RL D
    ([0x7A],), ([0xFE, 0xA5],),                      # D == A5 ?
    ([0x20], ("rel8", "sy")),
    # ---- capture 16 payload bytes to 4100, tag as hex ----
    ([0x21, 0x04, 0x3C],),                           # tag cursor
    ([0xDD, 0x21, 0x00, 0x41],),                     # IX = 4100
    # count lives in memory — BC is WPULSE's timeout register
    ([0x3E, 0x10],), ([0x32, 0x80, 0x41],),
    ("label", "by"),
    ([0xCD, lo(RDBYTE), hi(RDBYTE)],),
    ([0xDD, 0x77, 0x00],),                           # (IX) = A
    ([0xDD, 0x23],),                                 # INC IX
    ([0xCD, lo(TAGB), hi(TAGB)],),                   # tag byte
    ([0x3A, 0x80, 0x41],), ([0x3D],), ([0x32, 0x80, 0x41],),
    ([0x20], ("rel8", "by")),
    # ---- checksum over 4100..410F ----
    ([0xE5],), ([0x21, 0x00, 0x41],), ([0x06, 0x10],), ([0xAF],),
    ("label", "cs"),
    ([0x86],), ([0x23],), ([0x05],), ([0x20], ("rel8", "cs")),
    ([0x57],), ([0xE1],), ([0x7A],),
    ([0xCD, lo(TAGB), hi(TAGB)],),
    ([0x76],),
])

with open("build/casstest.hex", "w") as f:
    f.write("\n".join(f"{b:02x}" for b in img) + "\n")
with open("build/casstest.bin", "wb") as f:
    f.write(img)
print("casstest: image 4096 bytes")
