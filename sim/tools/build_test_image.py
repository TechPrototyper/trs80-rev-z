#!/usr/bin/env python3
"""Build the chapter-5 CPU test image (this repo's own code — NOT a Tandy ROM).

Hand-assembled Z80, byte for byte, so the listing below IS the source of
truth and reviewable without an assembler. The program:

  1. clears the screen via LDIR through video RAM (exercises block ops
     and the bit-6 write/read quirk),
  2. copies a 16-character banner into the top line,
  3. checksums the banner bytes (8-bit loop, DJNZ), stores the sum at
     0x4000 and prints it as two pseudo-hex characters (nibble + 0x30)
     via a CALL/RET subroutine with PUSH/POP,
  4. doubles 0x1234 twice through ADD HL,HL / PUSH/POP and parks the
     result at 0x4001/0x4002,
  5. exercises port 0xFF: reads MODESEL back on D6 and the cassette bit on
     D7 (writing quirk-invariant tag chars '6'/'3'/'0' to cells 66-68 so the
     read path is golden-checkable), switches to 32-char mode and back,
  6. reads the keyboard matrix: polls row 6 for SPACE and samples row 0 for
     'A', tagging cells 69-70 with 'S'/'A' (or '-') — the sim injects the keys
     via the testbench, trs80gp via -ik, so the tags golden-check the matrix,
  7. executes HALT — on a Model 1 the falling ~HALT pin asserts NMI*
     (Z53a/Z37d, chapter 5 §5), so execution resumes at 0x0066, which
     writes a marker into the last VRAM cell and spins.

Outputs: testimg.hex ($readmemh format, one byte per line, 4 KiB padded)
and testimg.bin (raw, for the golden model).
"""

import sys

ROM_SIZE = 0x1000        # pad to 4 KiB — trs80gp's smallest ROM quantum

BANNER = b"TRS-80 REV Z  OK"      # 16 chars
BANNER_ADDR = 0x0140              # past main + the print subroutine
BLO, BHI = BANNER_ADDR & 0xFF, BANNER_ADDR >> 8
assert len(BANNER) == 16

img = bytearray(ROM_SIZE)

def emit(addr, byts, mnemonic):
    for i, b in enumerate(byts):
        assert img[addr + i] == 0, f"overlap at {addr+i:04X}"
        img[addr + i] = b
    return addr + len(byts)

def emit_block(addr, prog):
    """Tiny two-pass assembler for a straight-line block with labels.

    prog is a list of ("label", name) markers and (bytes, "mnemonic") tuples.
    A relative jump is written as (bytes_prefix, ("rel8", target)): the last
    operand byte is the signed 8-bit displacement to label `target`, computed
    from the address after the operand. Keeps hand-assembled JRs honest.
    """
    labels, pc = {}, addr
    for item in prog:                      # pass 1: place labels
        if item[0] == "label":
            labels[item[1]] = pc
        else:
            pc += len(item[0]) + (1 if len(item) > 1 and isinstance(item[1], tuple) else 0)
    pc = addr
    for item in prog:                      # pass 2: emit
        if item[0] == "label":
            continue
        prefix = item[0]
        for b in prefix:
            assert img[pc] == 0, f"overlap at {pc:04X}"
            img[pc] = b; pc += 1
        if len(item) > 1 and isinstance(item[1], tuple):
            _, target = item[1]
            disp = labels[target] - (pc + 1)
            assert -128 <= disp <= 127, f"jump out of range to {target}"
            img[pc] = disp & 0xFF; pc += 1
    return pc

a = 0x0000
a = emit(a, [0xF3],             "DI")
a = emit(a, [0x31, 0xFF, 0x7F], "LD SP,7FFFh")
a = emit(a, [0xC3, 0x70, 0x00], "JP 0070h")

# --- NMI handler (fixed vector) ------------------------------------------
a = 0x0066
a = emit(a, [0x3E, 0xBF],       "LD A,0BFh        ; full graphics block")
a = emit(a, [0x32, 0xFF, 0x3F], "LD (3FFFh),A     ; done marker, last cell")
a = emit(a, [0x18, 0xFE],       "JR $             ; spin (must NOT halt again)")

# --- main ----------------------------------------------------------------
a = 0x0070
a = emit(a, [0x21, 0x00, 0x3C], "LD HL,3C00h")
a = emit(a, [0x11, 0x01, 0x3C], "LD DE,3C01h")
a = emit(a, [0x01, 0xFF, 0x03], "LD BC,03FFh")
a = emit(a, [0x36, 0x20],       "LD (HL),20h")
a = emit(a, [0xED, 0xB0],       "LDIR             ; clear screen through VRAM")
a = emit(a, [0x21, BLO, BHI], "LD HL,banner")
a = emit(a, [0x11, 0x00, 0x3C], "LD DE,3C00h")
a = emit(a, [0x01, 0x10, 0x00], "LD BC,0010h")
a = emit(a, [0xED, 0xB0],       "LDIR             ; banner to line 0")
a = emit(a, [0x21, BLO, BHI], "LD HL,banner")
a = emit(a, [0x06, 0x10],       "LD B,10h")
a = emit(a, [0xAF],             "XOR A")
loop = a
a = emit(a, [0x86],             "ADD A,(HL)")
a = emit(a, [0x23],             "INC HL")
rel = loop - (a + 2)
a = emit(a, [0x10, rel & 0xFF], "DJNZ loop")
a = emit(a, [0x32, 0x00, 0x40], "LD (4000h),A     ; checksum -> RAM")
a = emit(a, [0x4F],             "LD C,A")
a = emit(a, [0xCD, 0x20, 0x01], "CALL 0120h       ; pseudo-hex print")
a = emit(a, [0x21, 0x34, 0x12], "LD HL,1234h")
a = emit(a, [0x29],             "ADD HL,HL")
a = emit(a, [0x29],             "ADD HL,HL        ; 48D0h")
a = emit(a, [0xE5],             "PUSH HL")
a = emit(a, [0xD1],             "POP DE")
a = emit(a, [0x7A],             "LD A,D")
a = emit(a, [0x32, 0x01, 0x40], "LD (4001h),A     ; 48h")
a = emit(a, [0x7B],             "LD A,E")
a = emit(a, [0x32, 0x02, 0x40], "LD (4002h),A     ; D0h")
# --- port 0xFF: read MODESEL back on D6, cassette on D7, switch mode ---
# read the mode (currently 64-char), tag cell 66 with '6' or '3'
a = emit(a, [0xDB, 0xFF],       "IN A,(0FFh)      ; D7=cass, D6=MODESEL")
a = emit(a, [0xE6, 0x40],       "AND 40h          ; isolate MODESEL")
a = emit(a, [0x28, 0x04],       "JR Z,+4          ; 0 => 32-char")
a = emit(a, [0x3E, 0x36],       "LD A,'6'")
a = emit(a, [0x18, 0x02],       "JR +2")
a = emit(a, [0x3E, 0x33],       "LD A,'3'")
a = emit(a, [0x32, 0x42, 0x3C], "LD (3C42h),A     ; cell 66: expect '6'")
a = emit(a, [0x3E, 0x08],       "LD A,08h")
a = emit(a, [0xD3, 0xFF],       "OUT (0FFh),A     ; D3=1 -> 32-char mode")
a = emit(a, [0xDB, 0xFF],       "IN A,(0FFh)")
a = emit(a, [0xE6, 0x40],       "AND 40h")
a = emit(a, [0x28, 0x04],       "JR Z,+4")
a = emit(a, [0x3E, 0x36],       "LD A,'6'")
a = emit(a, [0x18, 0x02],       "JR +2")
a = emit(a, [0x3E, 0x33],       "LD A,'3'")
a = emit(a, [0x32, 0x43, 0x3C], "LD (3C43h),A     ; cell 67: expect '3'")
a = emit(a, [0xDB, 0xFF],       "IN A,(0FFh)      ; cassette bit (D7)")
a = emit(a, [0xE6, 0x80],       "AND 80h")
a = emit(a, [0x28, 0x04],       "JR Z,+4")
a = emit(a, [0x3E, 0x31],       "LD A,'1'")
a = emit(a, [0x18, 0x02],       "JR +2")
a = emit(a, [0x3E, 0x30],       "LD A,'0'")
a = emit(a, [0x32, 0x44, 0x3C], "LD (3C44h),A     ; cell 68: expect '0' (no tape)")
# --- keyboard: poll row 6 for SPACE (D7), sample row 0 for 'A' (D1) -------
# Tags are quirk-invariant letters so the read path is golden-checkable: the
# sim injects the keys via the testbench, trs80gp via -ik 6 80 / -ik 0 02.
a = emit_block(a, [
    ([0x01, 0x00, 0x00],            "LD BC,0000h      ; poll timeout (65536)"),
    ("label", "kwait"),
    ([0x3A, 0x40, 0x38],           "LD A,(3840h)     ; keyboard row 6"),
    ([0xE6, 0x80],                 "AND 80h          ; SPACE = D7"),
    ([0x20], ("rel8", "kspace"),   "JR NZ,kspace"),
    ([0x0B],                       "DEC BC"),
    ([0x78],                       "LD A,B"),
    ([0xB1],                       "OR C"),
    ([0x20], ("rel8", "kwait"),    "JR NZ,kwait"),
    ([0x3E, 0x2D],                 "LD A,'-'         ; timeout: no SPACE"),
    ([0x18], ("rel8", "kst1"),     "JR kst1"),
    ("label", "kspace"),
    ([0x3E, 0x53],                 "LD A,'S'"),
    ("label", "kst1"),
    ([0x32, 0x45, 0x3C],           "LD (3C45h),A     ; cell 69: 'S' when SPACE seen"),
    ([0x3A, 0x01, 0x38],           "LD A,(3801h)     ; keyboard row 0"),
    ([0xE6, 0x02],                 "AND 02h          ; 'A' = D1"),
    ([0x28], ("rel8", "kna"),      "JR Z,kna"),
    ([0x3E, 0x41],                 "LD A,'A'"),
    ([0x18], ("rel8", "kst2"),     "JR kst2"),
    ("label", "kna"),
    ([0x3E, 0x2D],                 "LD A,'-'"),
    ("label", "kst2"),
    ([0x32, 0x46, 0x3C],           "LD (3C46h),A     ; cell 70: 'A' when pressed"),
])
a = emit(a, [0x3E, 0x06],       "LD A,06h")
a = emit(a, [0xD3, 0xFF],       "OUT (0FFh),A     ; motor+level, D3=0 -> back to 64-char")
a = emit(a, [0x76],             "HALT             ; ~HALT low -> NMI -> 0066h")

# --- subroutine: print C as two chars (nibble+30h) at 3C40h/3C41h --------
a = 0x0120
a = emit(a, [0xF5],             "PUSH AF")
a = emit(a, [0x79],             "LD A,C")
a = emit(a, [0x0F] * 4,         "RRCA x4")
a = emit(a, [0xE6, 0x0F],       "AND 0Fh")
a = emit(a, [0xC6, 0x30],       "ADD A,30h")
a = emit(a, [0x32, 0x40, 0x3C], "LD (3C40h),A")
a = emit(a, [0x79],             "LD A,C")
a = emit(a, [0xE6, 0x0F],       "AND 0Fh")
a = emit(a, [0xC6, 0x30],       "ADD A,30h")
a = emit(a, [0x32, 0x41, 0x3C], "LD (3C41h),A")
a = emit(a, [0xF1],             "POP AF")
a = emit(a, [0xC9],             "RET")

emit(BANNER_ADDR, BANNER, "banner text")

def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "build"
    with open(f"{outdir}/testimg.hex", "w", encoding="ascii") as f:
        f.write("\n".join(f"{b:02x}" for b in img) + "\n")
    with open(f"{outdir}/testimg.bin", "wb") as f:
        f.write(bytes(img))
    csum = sum(BANNER) & 0xFF
    print(f"testimg: {ROM_SIZE} bytes, banner checksum {csum:02X}h "
          f"-> screen chars {0x30 + (csum >> 4):02X}h {0x30 + (csum & 0xF):02X}h")

if __name__ == "__main__":
    main()
