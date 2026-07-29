#!/usr/bin/env python3
"""Build the EI heartbeat test image (this repo's own code — NOT a Tandy ROM).

Hand-assembled Z80 for EI stage 1 (the m1_ei container): proves the 40 Hz
RTC heartbeat and the 0x37E0 interrupt-status register end to end.

Flow: IM 1 + EI with the ISR at 0x0038 (we own the ROM). The ISR reads
0x37E0 (which must clear the RTC interrupt), remembers the FIRST status
value it saw, and counts ticks; at the 8th tick it returns WITHOUT re-
enabling interrupts, so the count is exactly 8 in any correct machine —
timing-robust by construction (no cycle-exact interleaving is compared).
The main loop polls the counter under a bounded budget (~3.3 M T-states,
so a machine without a heartbeat still terminates and tags the failure).

VRAM tags (all quirk-invariant, D6 == NOR(D5,D7)):
  3C00..01  "HB" banner
  3C02      'K' if exactly 8 ticks arrived, '-' otherwise
  3C04..05  hex of 0x37E0 read BEFORE EI (idle status)
  3C06..07  hex of 0x37E0 read INSIDE the first ISR (active status)
  3C08..09  hex of 0x37E0 read after DI, post-clear (idle again)

The three hex tags pin down the 37E0 bit layout AND the clear-on-read
semantics against trs80gp (PLAN-EI-FDC open point) — if our RTL got either
wrong, the bytes differ and the golden compare fails.

HALT then raises NMI and the handler writes the 0xBF done marker into the
last VRAM cell (the established completion idiom).

Outputs: eitest.hex ($readmemh, 4 KiB) and eitest.bin (raw).
"""

ROM_SIZE = 0x1000

img = bytearray(ROM_SIZE)


def emit(addr, byts, mnemonic):
    for i, b in enumerate(byts):
        assert img[addr + i] == 0, f"overlap at {addr+i:04X}"
        img[addr + i] = b
    return addr + len(byts)


# RAM variables
FIRST = 0x4080   # first status value seen in the ISR
CNT   = 0x4081   # tick counter
SEEN  = 0x4082   # first-value-captured flag
IDLE  = 0x4083   # status before EI
POST  = 0x4084   # status after DI

TAGBYTE = 0x0200
HEXN    = 0x0220


def lo(x): return x & 0xFF
def hi(x): return x >> 8


a = 0x0000
a = emit(a, [0xF3],                   "DI")
a = emit(a, [0x31, 0xFF, 0x7F],       "LD SP,7FFFh")
a = emit(a, [0xC3, 0x80, 0x00],       "JP 0080h")

# --- ISR (IM 1 -> RST 38h; we own the ROM) -------------------------------
a = 0x0038
a = emit(a, [0xF5],                   "PUSH AF")
a = emit(a, [0x3A, 0xE0, 0x37],       "LD A,(37E0h)     ; read + clear RTC FF")
a = emit(a, [0xF5],                   "PUSH AF          ; keep the status")
a = emit(a, [0x3A, lo(SEEN), hi(SEEN)], "LD A,(SEEN)")
a = emit(a, [0xB7],                   "OR A")
a = emit(a, [0x20, 0x0B],             "JR NZ,skip       ; first value only")
a = emit(a, [0xF1],                   "POP AF")
a = emit(a, [0x32, lo(FIRST), hi(FIRST)], "LD (FIRST),A")
a = emit(a, [0x3E, 0x01],             "LD A,01h")
a = emit(a, [0x32, lo(SEEN), hi(SEEN)], "LD (SEEN),A")
a = emit(a, [0x18, 0x01],             "JR cont")
a = emit(a, [0xF1],                   "skip: POP AF")
a = emit(a, [0x3A, lo(CNT), hi(CNT)], "cont: LD A,(CNT)")
a = emit(a, [0x3C],                   "INC A")
a = emit(a, [0x32, lo(CNT), hi(CNT)], "LD (CNT),A")
a = emit(a, [0xFE, 0x08],             "CP 08h")
a = emit(a, [0x30, 0x03],             "JR NC,noei       ; 8th tick: stay off")
a = emit(a, [0xF1],                   "POP AF")
a = emit(a, [0xFB],                   "EI")
a = emit(a, [0xC9],                   "RET")
a = emit(a, [0xF1],                   "noei: POP AF")
a = emit(a, [0xC9],                   "RET")
assert a <= 0x0066, f"ISR runs into the NMI vector: {a:04X}"

# --- NMI handler (fixed vector), the established completion idiom --------
a = 0x0066
a = emit(a, [0x3E, 0xBF],             "LD A,0BFh        ; full graphics block")
a = emit(a, [0x32, 0xFF, 0x3F],       "LD (3FFFh),A     ; done marker")
a = emit(a, [0x18, 0xFE],             "JR $             ; spin")

# --- main -----------------------------------------------------------------
a = 0x0080
a = emit(a, [0x21, 0x00, 0x3C],       "LD HL,3C00h      ; clear screen")
a = emit(a, [0x11, 0x01, 0x3C],       "LD DE,3C01h")
a = emit(a, [0x01, 0xFF, 0x03],       "LD BC,03FFh")
a = emit(a, [0x36, 0x20],             "LD (HL),20h")
a = emit(a, [0xED, 0xB0],             "LDIR")
a = emit(a, [0xAF],                   "XOR A            ; clear the variables")
a = emit(a, [0x32, lo(FIRST), hi(FIRST)], "LD (FIRST),A")
a = emit(a, [0x32, lo(CNT), hi(CNT)],     "LD (CNT),A")
a = emit(a, [0x32, lo(SEEN), hi(SEEN)],   "LD (SEEN),A")
a = emit(a, [0x3E, 0x48],             "LD A,'H'")
a = emit(a, [0x32, 0x00, 0x3C],       "LD (3C00h),A")
a = emit(a, [0x3E, 0x42],             "LD A,'B'")
a = emit(a, [0x32, 0x01, 0x3C],       "LD (3C01h),A")
a = emit(a, [0x3A, 0xE0, 0x37],       "LD A,(37E0h)     ; idle status")
a = emit(a, [0x32, lo(IDLE), hi(IDLE)], "LD (IDLE),A")
a = emit(a, [0xED, 0x56],             "IM 1")
a = emit(a, [0xFB],                   "EI")
a = emit(a, [0x01, 0x00, 0x00],       "LD BC,0000h      ; 65536-round budget")
# wait: (00AD)
a = emit(a, [0x3A, lo(CNT), hi(CNT)], "wait: LD A,(CNT)")
a = emit(a, [0xFE, 0x08],             "CP 08h")
a = emit(a, [0x28, 0x05],             "JR Z,done")
a = emit(a, [0x0B],                   "DEC BC")
a = emit(a, [0x78],                   "LD A,B")
a = emit(a, [0xB1],                   "OR C")
a = emit(a, [0x20, 0xF4],             "JR NZ,wait       ; ~50 T/round budget")
# done: (00B9)
a = emit(a, [0xF3],                   "done: DI")
a = emit(a, [0x3A, 0xE0, 0x37],       "LD A,(37E0h)     ; post-clear status")
a = emit(a, [0x32, lo(POST), hi(POST)], "LD (POST),A")
a = emit(a, [0x3A, lo(CNT), hi(CNT)], "LD A,(CNT)")
a = emit(a, [0xFE, 0x08],             "CP 08h")
a = emit(a, [0x3E, 0x4B],             "LD A,'K'")
a = emit(a, [0x28, 0x02],             "JR Z,+2")
a = emit(a, [0x3E, 0x2D],             "LD A,'-'")
a = emit(a, [0x32, 0x02, 0x3C],       "LD (3C02h),A     ; tick tag")
a = emit(a, [0x21, 0x04, 0x3C],       "LD HL,3C04h      ; hex tags from here")
a = emit(a, [0x3A, lo(IDLE), hi(IDLE)], "LD A,(IDLE)")
a = emit(a, [0xCD, lo(TAGBYTE), hi(TAGBYTE)], "CALL tagbyte")
a = emit(a, [0x3A, lo(FIRST), hi(FIRST)], "LD A,(FIRST)")
a = emit(a, [0xCD, lo(TAGBYTE), hi(TAGBYTE)], "CALL tagbyte")
a = emit(a, [0x3A, lo(POST), hi(POST)], "LD A,(POST)")
a = emit(a, [0xCD, lo(TAGBYTE), hi(TAGBYTE)], "CALL tagbyte")
a = emit(a, [0x76],                   "HALT             ; ~HALT -> NMI -> 0066h")

# --- tagbyte: A as two hex chars to (HL), HL += 2 -------------------------
a = TAGBYTE
a = emit(a, [0xF5],                   "PUSH AF")
a = emit(a, [0x0F, 0x0F, 0x0F, 0x0F], "RRCA x4          ; high nibble first")
a = emit(a, [0xCD, lo(HEXN), hi(HEXN)], "CALL hexn")
a = emit(a, [0x77],                   "LD (HL),A")
a = emit(a, [0x23],                   "INC HL")
a = emit(a, [0xF1],                   "POP AF")
a = emit(a, [0xCD, lo(HEXN), hi(HEXN)], "CALL hexn")
a = emit(a, [0x77],                   "LD (HL),A")
a = emit(a, [0x23],                   "INC HL")
a = emit(a, [0xC9],                   "RET")

# --- hexn: low nibble of A -> '0'..'9','A'..'F' ---------------------------
a = HEXN
a = emit(a, [0xE6, 0x0F],             "AND 0Fh")
a = emit(a, [0xC6, 0x30],             "ADD A,30h")
a = emit(a, [0xFE, 0x3A],             "CP 3Ah")
a = emit(a, [0x38, 0x02],             "JR C,+2")
a = emit(a, [0xC6, 0x07],             "ADD A,07h")
a = emit(a, [0xC9],                   "RET")

with open("build/eitest.hex", "w") as f:
    f.write("\n".join(f"{b:02x}" for b in img) + "\n")
with open("build/eitest.bin", "wb") as f:
    f.write(img)
print(f"eitest: image {ROM_SIZE} bytes")
