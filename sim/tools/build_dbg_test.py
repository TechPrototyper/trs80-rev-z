#!/usr/bin/env python3
"""Build the debug-core test image (ADR-0006 stage A — this repo's own code).

A deliberately prefix-heavy program: the debug core's single-step must
treat every Z80 prefix chain (DD/FD, ED, CB, DD CB) as ONE instruction,
and its breakpoint must fire at an instruction boundary. The main loop
lives at a fixed address with a fixed instruction-start map, so the
testbench can assert the exact PC sequence a step must produce.

Layout:
  0x0000  DI; LD SP,7FFFh; IM 1; JP 0010h   (IM 1: the tracker's proof)
  0x0010  loop:
    0x0010  DD 21 34 12   LD IX,1234h
    0x0014  FD 21 78 56   LD IY,5678h
    0x0018  ED 44         NEG
    0x001A  CB 07         RLC A
    0x001C  DD CB 05 06   RLC (IX+5)       ; one instruction, two M1s
    0x0020  3E 55         LD A,55h
    0x0022  32 00 41      LD (4100h),A     ; the visible side effect
    0x0025  C3 10 00      JP loop

Expected PC sequence from a halt at 0x0010:
  0010 -> 0014 -> 0018 -> 001A -> 001C -> 0020 -> 0022 -> 0025 -> 0010
Outputs dbgtest.hex (4 KiB ROM image).
"""

img = bytearray(0x1000)


def emit(addr, byts):
    for i, b in enumerate(byts):
        assert img[addr + i] == 0, f"overlap at {addr+i:04X}"
        img[addr + i] = b


emit(0x0000, [0xF3, 0x31, 0xFF, 0x7F, 0xED, 0x56, 0xC3, 0x10, 0x00])
emit(0x0010, [0xDD, 0x21, 0x34, 0x12,
              0xFD, 0x21, 0x78, 0x56,
              0xED, 0x44,
              0xCB, 0x07,
              0xDD, 0xCB, 0x05, 0x06,
              0x3E, 0x55,
              0x32, 0x00, 0x41,
              0xC3, 0x10, 0x00])

with open("build/dbgtest.hex", "w") as f:
    f.write("\n".join(f"{b:02x}" for b in img) + "\n")
print("dbgtest: image 4096 bytes")
