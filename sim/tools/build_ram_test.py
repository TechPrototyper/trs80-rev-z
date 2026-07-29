#!/usr/bin/env python3
"""Build the EI-RAM test image (this repo's own code — NOT a Tandy ROM).

Hand-assembled Z80 for ADR-0005 stage 1: proves the 48K memory map end to
end. The program clears the screen, writes a distinct byte to each memory
boundary cell — end of keyboard RAM (0x7FFF), first/last of EI bank 1
(0x8000/0xBFFF), first/last of EI bank 2 (0xC000/0xFFFF) — then reads all
five back *after* all writes (so any address aliasing between banks would
corrupt an earlier cell and be caught) and tags VRAM cells 0-4 with 'K'
(match) or '-' (mismatch). HALT then raises NMI (chapter 5 §5) and the
handler writes the 0xBF done marker into the last VRAM cell.

All tag characters are quirk-invariant (D6 == NOR(D5,D7)), so the VRAM
dump golden-compares byte-exactly against trs80gp -m1 -mem 48 (SPEC §6).

Outputs: ramtest.hex ($readmemh, 4 KiB) and ramtest.bin (raw).
"""

ROM_SIZE = 0x1000

img = bytearray(ROM_SIZE)


def emit(addr, byts, mnemonic):
    for i, b in enumerate(byts):
        assert img[addr + i] == 0, f"overlap at {addr+i:04X}"
        img[addr + i] = b
    return addr + len(byts)


a = 0x0000
a = emit(a, [0xF3],             "DI")
a = emit(a, [0x31, 0xFF, 0x7F], "LD SP,7FFFh")
a = emit(a, [0xC3, 0x70, 0x00], "JP 0070h")

# --- NMI handler (fixed vector), same shape as the chapter-5 image -------
a = 0x0066
a = emit(a, [0x3E, 0xBF],       "LD A,0BFh        ; full graphics block")
a = emit(a, [0x32, 0xFF, 0x3F], "LD (3FFFh),A     ; done marker, last cell")
a = emit(a, [0x18, 0xFE],       "JR $             ; spin")

# --- main -----------------------------------------------------------------
a = 0x0070
a = emit(a, [0x21, 0x00, 0x3C], "LD HL,3C00h      ; clear screen")
a = emit(a, [0x11, 0x01, 0x3C], "LD DE,3C01h")
a = emit(a, [0x01, 0xFF, 0x03], "LD BC,03FFh")
a = emit(a, [0x36, 0x20],       "LD (HL),20h")
a = emit(a, [0xED, 0xB0],       "LDIR")

# the five boundary cells: (address, test byte, VRAM tag cell)
CELLS = [
    (0x7FFF, 0x55, 0x3C00),   # end of keyboard-unit RAM
    (0x8000, 0x66, 0x3C01),   # first byte of EI bank 1
    (0xBFFF, 0x77, 0x3C02),   # last byte of EI bank 1
    (0xC000, 0x88, 0x3C03),   # first byte of EI bank 2
    (0xFFFF, 0x99, 0x3C04),   # last byte of EI bank 2
]

# write pass — all writes complete before any read, so bank aliasing
# (e.g. 0xC000 mirroring onto 0x8000) would clobber an earlier cell
for addr_, val, _tag in CELLS:
    a = emit(a, [0x3E, val],                        f"LD A,{val:02X}h")
    a = emit(a, [0x32, addr_ & 0xFF, addr_ >> 8],   f"LD ({addr_:04X}h),A")

# read-back pass — tag 'K' (0x4B) on match, '-' (0x2D) on mismatch
for addr_, val, tag in CELLS:
    a = emit(a, [0x3A, addr_ & 0xFF, addr_ >> 8],   f"LD A,({addr_:04X}h)")
    a = emit(a, [0xFE, val],                        f"CP {val:02X}h")
    a = emit(a, [0x06, 0x4B],                       "LD B,'K'")
    a = emit(a, [0x28, 0x02],                       "JR Z,+2")
    a = emit(a, [0x06, 0x2D],                       "LD B,'-'")
    a = emit(a, [0x78],                             "LD A,B")
    a = emit(a, [0x32, tag & 0xFF, tag >> 8],       f"LD ({tag:04X}h),A")

a = emit(a, [0x76],             "HALT             ; ~HALT low -> NMI -> 0066h")

with open("build/ramtest.hex", "w") as f:
    f.write("\n".join(f"{b:02x}" for b in img) + "\n")
with open("build/ramtest.bin", "wb") as f:
    f.write(img)
print(f"ramtest: {a:04X} bytes of program, image {ROM_SIZE} bytes")
