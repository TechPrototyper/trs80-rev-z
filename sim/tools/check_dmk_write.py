#!/usr/bin/env python3
"""Verify a written DMK artifact mathematically (EI stage 5b).

Parses <hex> (one byte per line, the media model's post-run image),
locates track T sector S through the IDAM pointer table, and asserts:
the 256 data bytes equal the write-test pattern (0x11 + 3*i) and the
data-field CRC (CCITT 0x1021 over DAM + data, init 0xFFFF) is the one a
real 1771 — or trs80gp reading the image — would accept.

Usage: check_dmk_write.py <hex> <track> <sector> [--e5]
  --e5: expect a freshly FORMATTED sector (Write Track): 256 bytes of
        0xE5, and require the track's rebuilt IDAM pointer table to
        hold exactly two entries (the stage-6a mini format).
"""
import sys


def crc16(data):
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 \
                  else (crc << 1) & 0xFFFF
    return crc


def main():
    path, trk, sec = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    e5 = "--e5" in sys.argv
    mem = [int(l, 16) for l in open(path) if l.strip()]
    tlen = mem[2] | mem[3] << 8
    base = 16 + trk * tlen
    t = mem[base:base + tlen]
    for e in range(64):
        p = (t[2 * e] | t[2 * e + 1] << 8) & 0x3FFF
        if p == 0:
            break
        if t[p] == 0xFE and t[p + 1] == trk and t[p + 3] == sec:
            q = p + 7
            while t[q] not in (0xF8, 0xF9, 0xFA, 0xFB):
                q += 1
            dam, data = t[q], t[q + 1:q + 257]
            got_crc = t[q + 257] << 8 | t[q + 258]
            want = crc16([dam] + data)
            pat = [0xE5] * 256 if e5 \
                  else [(0x11 + 3 * i) & 0xFF for i in range(256)]
            if data != pat:
                sys.exit(f"FAIL: t{trk}/s{sec} data is not the pattern "
                         f"({sum(1 for a, b in zip(data, pat) if a != b)} differ)")
            if got_crc != want:
                sys.exit(f"FAIL: CRC {got_crc:04X}, a 1771 computes {want:04X}")
            if e5:
                nptr = sum(1 for k in range(64)
                           if (t[2 * k] | t[2 * k + 1] << 8) != 0)
                if nptr != 2:
                    sys.exit(f"FAIL: {nptr} IDAM pointers, expected 2")
                idcrc = crc16(t[p:p + 5])
                if (t[p + 5] << 8 | t[p + 6]) != idcrc:
                    sys.exit(f"FAIL: ID CRC bad "
                             f"({t[p+5]:02X}{t[p+6]:02X} != {idcrc:04X})")
            print(f"ARTIFACT OK  t{trk}/s{sec}: 256/256 pattern bytes, "
                  f"CRC {got_crc:04X} valid (DAM {dam:02X})"
                  + (", table+ID CRC valid" if e5 else ""))
            return
    sys.exit(f"FAIL: t{trk}/s{sec} not found in {path}")


if __name__ == "__main__":
    main()
