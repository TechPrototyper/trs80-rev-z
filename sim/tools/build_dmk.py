#!/usr/bin/env python3
"""Build a DMK floppy image with deterministic sector data (sim tooling).

Single-density, single-sided, 10 sectors x 256 bytes per track — the
TRS-80 Model 1 standard layout (sectors numbered 0..9, IBM length code
1). Bytes are stored ONCE (header flag 0x40); track length 0x0CC0
(3264 = 128-byte IDAM pointer table + 3136 raw bytes).

DMK facts (David Keil's format, verified against trs80gp 2.5.5 by the
stage-3 probes, 2026-07-24 — see PLAN-EI-FDC §6):
  header[0]  write protect (0x00 rw, 0xFF protected)
  header[1]  track count
  header[2:4] track length LE, INCLUDING the 128-byte pointer table
  header[4]  flags: bit6 = single density, bytes stored once;
             bit4 = single sided. trs80gp REQUIRES bit4 to match the
             file size (a 0x40-only header is "format not recognized" —
             it sizes the file as double-sided); wild DMKs are commonly
             0x10 with tracklen 0x1900 and SD bytes DOUBLED, so the
             parser must handle both encodings.
  per track: 64 x 16-bit LE IDAM pointers (offset of the 0xFE byte from
  the START OF THE TRACK, table included, so every pointer >= 0x80;
  bit15 = IDAM is double density), then the raw track bytes.
  trs80gp -im trackdump confirmed our tracks parse: IDAM/DAM found, ID
  CRC f1d3 for (0,0,0,1) identical to a reference JV1's, gaps as below.

Sector layout (FM / IBM 3740 style, as the WD1771 sees it):
  6x00  FE tk sd sc ln crc16(2)   ID field (CRC over FE..ln)
  11xFF 6x00  FB  256 data  crc16(2)   data field (CRC over FB+data)
gaps filled with 0xFF. CRC = CCITT 0x1021, init 0xFFFF, big-endian.

Data pattern: 256 bytes from Python's Mersenne Twister seeded with
t*256+s (stable across CPython versions). Structured patterns kept
collapsing to seed-independent 8-bit sums (affine, multiplicative-walk,
and XOR-of-permutation/balanced-bit patterns all do, provably), so the
data is simply pseudorandom; the build asserts the probe sectors have
pairwise distinct sums, and checksums are printed for test images.

Outputs <out>.dmk (binary) and <out>.hex (one byte/line, $readmemh).
"""

import argparse
import random

SEC_LEN = 256
SPT = 10
TRACK_LEN = 0x0CC0          # includes the 128-byte pointer table
RAW_LEN = TRACK_LEN - 128


def crc16(data):
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 \
                  else (crc << 1) & 0xFFFF
    return crc


def sector_data(t, s):
    rng = random.Random(t * 256 + s)
    return bytes(rng.randrange(256) for _ in range(SEC_LEN))


def boot_sector():
    """Our own boot sector (this repo's code — the 'DOS' is a banner).

    The Level II ROM loads track 0 sector 0 to 0x4200 and jumps there;
    this code clears the screen, prints a static banner and spins —
    a deterministic end state for the boot-chain golden (stage 4)."""
    msg = b"TRS-80 REV Z  DISK BOOT OK"
    code = bytes([
        0x21, 0x00, 0x3C,        # LD HL,3C00h ; clear screen
        0x11, 0x01, 0x3C,        # LD DE,3C01h
        0x01, 0xFF, 0x03,        # LD BC,03FFh
        0x36, 0x20,              # LD (HL),20h
        0xED, 0xB0,              # LDIR
        0x21, 0x1A, 0x42,        # LD HL,msg (0x4200 + len(code))
        0x11, 0x00, 0x3C,        # LD DE,3C00h
        0x01, len(msg), 0x00,    # LD BC,len
        0xED, 0xB0,              # LDIR
        0x18, 0xFE,              # JR $ ; static forever
    ])
    assert len(code) == 0x1A and code[14] == 0x1A
    sec = code + msg
    return sec + bytes(SEC_LEN - len(sec))


DAM_CYCLE = [0xFB, 0xFA, 0xF9, 0xF8]


def build_track(t, boot=False, dam_track=None):
    raw = bytearray()
    pointers = []
    raw += b"\xFF" * 16                      # post-index gap
    for s in range(SPT):
        raw += b"\x00" * 6
        pointers.append(128 + len(raw))      # offset of the FE byte
        idf = bytes([0xFE, t, 0, s, 1])
        c = crc16(idf)
        raw += idf + bytes([c >> 8, c & 0xFF])
        raw += b"\xFF" * 11 + b"\x00" * 6
        payload = boot_sector() if boot and t == 0 and s == 0 \
                  else sector_data(t, s)
        # DAM test track: sectors 0..3 carry FB/FA/F9/F8 (the 1771's four
        # record types; TRS-80 DOS directories use FA/F8), rest normal.
        dam = DAM_CYCLE[s] if dam_track == t and s < 4 else 0xFB
        dat = bytes([dam]) + payload
        c = crc16(dat)
        raw += dat + bytes([c >> 8, c & 0xFF])
        raw += b"\xFF" * 10                  # gap 3
    assert len(raw) <= RAW_LEN, len(raw)
    raw += b"\xFF" * (RAW_LEN - len(raw))

    table = bytearray(128)
    for i, p in enumerate(pointers):
        table[2 * i] = p & 0xFF
        table[2 * i + 1] = (p >> 8) & 0xFF   # bit15 clear: single density
    return bytes(table) + bytes(raw)


DD_TRACK_LEN = 0x1900
DD_RAW = DD_TRACK_LEN - 128
DD_SPT = 18


def build_track_dd(t):
    """One MFM double-density track: 18 x 256-byte sectors, IBM System 34
    style gaps (4E), 12x00 sync + A1 A1 A1 premarks; CRC includes the
    premarks (equivalent: init 0xCDB4, then mark + payload). Pointer
    entries carry bit 15 (DD)."""
    raw = bytearray()
    pointers = []
    raw += b"\x4e" * 32
    for s_ in range(DD_SPT):
        raw += b"\x00" * 12 + b"\xa1\xa1\xa1"
        pointers.append(0x8000 | (128 + len(raw)))
        idf = bytes([0xFE, t, 0, s_, 1])
        c = crc16(b"\xa1\xa1\xa1" + idf)
        raw += idf + bytes([c >> 8, c & 0xFF])
        raw += b"\x4e" * 22 + b"\x00" * 12 + b"\xa1\xa1\xa1"
        dat = bytes([0xFB]) + sector_data(t, s_)
        c = crc16(b"\xa1\xa1\xa1" + dat)
        raw += dat + bytes([c >> 8, c & 0xFF])
        raw += b"\x4e" * 20
    assert len(raw) <= DD_RAW, len(raw)
    raw += b"\x4e" * (DD_RAW - len(raw))
    table = bytearray(128)
    for i, p in enumerate(pointers):
        table[2 * i] = p & 0xFF
        table[2 * i + 1] = (p >> 8) & 0xFF
    return bytes(table) + bytes(raw)


def build_track_sd_doubled(t, boot=False):
    """The SD track re-encoded for a 0x1900 container: every raw byte
    stored twice (the wild-image convention), pointers rescaled to the
    doubled offsets, bit 15 clear (FM)."""
    sd = build_track(t, boot)
    table, raw = sd[:128], sd[128:]
    draw = bytes(b for x in raw for b in (x, x))[:DD_RAW]
    dtable = bytearray(128)
    for i in range(64):
        p = table[2 * i] | table[2 * i + 1] << 8
        if p:
            p = 128 + 2 * ((p & 0x3FFF) - 128)
            dtable[2 * i] = p & 0xFF
            dtable[2 * i + 1] = (p >> 8) & 0xFF
    return bytes(dtable) + draw + b"\x4e" * (DD_RAW - len(draw))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, help="output basename")
    ap.add_argument("--tracks", type=int, default=35)
    ap.add_argument("--wp", action="store_true", help="write-protected")
    ap.add_argument("--boot", action="store_true",
                    help="t0/s0 = our banner boot sector (stage-4 golden)")
    ap.add_argument("--dd", action="store_true",
                    help="mixed-density image: track 0 SD (doubled bytes,"
                         " boot convention), tracks 1+ MFM DD 18x256;"
                         " container 0x1900/flags 0x10 like wild DMKs")
    ap.add_argument("--damtrk", type=int, default=None,
                    help="SD track whose sectors 0..3 carry the DAMs"
                         " FB/FA/F9/F8 (record-type probe)")
    args = ap.parse_args()

    hdr = bytearray(16)
    hdr[0] = 0xFF if args.wp else 0x00
    hdr[1] = args.tracks
    if args.dd:
        hdr[2] = DD_TRACK_LEN & 0xFF
        hdr[3] = DD_TRACK_LEN >> 8
        hdr[4] = 0x10                        # single-sided, SD doubled
        img = bytes(hdr) + b"".join(
            build_track_sd_doubled(t, args.boot) if t == 0
            else build_track_dd(t) for t in range(args.tracks))
    else:
        hdr[2] = TRACK_LEN & 0xFF
        hdr[3] = TRACK_LEN >> 8
        hdr[4] = 0x50                        # SD single-byte + single-sided
        img = bytes(hdr) + b"".join(build_track(t, args.boot, args.damtrk)
                                    for t in range(args.tracks))

    with open(args.out + ".dmk", "wb") as f:
        f.write(img)
    with open(args.out + ".hex", "w") as f:
        f.write("\n".join(f"{b:02x}" for b in img) + "\n")

    def csum(t, s):
        return sum(sector_data(t, s)) & 0xFF

    probes = [(0, 0), (2, 3), (2, 7), (17, 5)]
    sums = [csum(t, s) for t, s in probes]
    assert len(set(sums)) == len(sums), "probe checksums collide"
    print(f"{args.out}.dmk: {args.tracks} tracks, {len(img)} bytes; "
          f"checksums t0/s0={sums[0]:02X} t2/s3={sums[1]:02X} "
          f"t2/s7={sums[2]:02X} t17/s5={sums[3]:02X}")


if __name__ == "__main__":
    main()
