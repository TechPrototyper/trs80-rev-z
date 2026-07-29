#!/usr/bin/env python3
"""Build a small FAT32 card image for the SD loader/filesystem testbenches.

Produces a byte-true FAT32 volume (optionally behind an MBR partition,
as shipped cards are) containing DIRNAME/FILENAME with a chosen payload,
and optionally TRS80/DRIVE0..3/ directories with disk images for the
m1_sd_fs mount/serve phases. The layout deliberately includes the
realistic obstacles the streaming reader must step over:

  * a volume-label entry (attr 0x08) ahead of everything else
  * long-filename entries (attr 0x0F) before each 8.3 entry
  * "." / ".." entries inside every subdirectory
  * a NOTES.TXT decoy ahead of each drive's DMK (proves the extension
    match skips non-DMK files)
  * optionally FRAGMENTED cluster chains (clusters out of order), so the
    testbench proves real FAT following, not "read N sectors"

Outputs <out>.hex (one byte per line, $readmemh format), <out>.payload.hex
with the embedded ROM file, and <out>.d<N>.hex per drive image.

This is simulation tooling: payloads are either deterministic patterns
or the repository's own test image — never a Tandy ROM.
"""

import argparse
import struct

SEC = 512


def pattern_bytes(n, seed=0):
    """Deterministic, non-periodic-in-256 test payload (seed per file)."""
    return bytes(((i * 31) + ((i >> 8) * 17) + 5 + seed * 97) & 0xFF
                 for i in range(n))


def sfn_entry(name11, attr, cluster, size):
    """One 8.3 directory entry (32 bytes)."""
    assert len(name11) == 11
    e = bytearray(32)
    e[0:11] = name11.encode("ascii")
    e[11] = attr
    struct.pack_into("<H", e, 20, (cluster >> 16) & 0xFFFF)
    struct.pack_into("<H", e, 26, cluster & 0xFFFF)
    struct.pack_into("<I", e, 28, size)
    return bytes(e)


def lfn_entries(longname, name11):
    """Minimal LFN chain (single entry, names here are short) — present
    purely so the reader proves it skips attr-0x0F entries."""
    def checksum(n):
        s = 0
        for c in n.encode("ascii"):
            s = (((s & 1) << 7) + (s >> 1) + c) & 0xFF
        return s

    chars = list(longname) + ["\x00"] + ["￿"] * 12
    e = bytearray(32)
    e[0] = 0x41                      # sequence 1, last entry
    e[11] = 0x0F                     # LFN attribute
    e[13] = checksum(name11)
    slots = [(1, 5), (14, 6), (28, 2)]
    idx = 0
    for off, cnt in slots:
        for k in range(cnt):
            struct.pack_into("<H", e, off + 2 * k, ord(chars[idx]) & 0xFFFF)
            idx += 1
    return bytes(e)


def parse_drives(specs):
    """--drive N:SIZE[:frag], N:@file (binary payload), or N:empty."""
    drives = {}
    for spec in specs or []:
        parts = spec.split(":")
        n = int(parts[0])
        assert 0 <= n <= 3 and n not in drives, spec
        if parts[1] == "empty":
            drives[n] = (None, False)
        elif parts[1].startswith("@"):
            drives[n] = (parts[1][1:], len(parts) > 2 and parts[2] == "frag")
        else:
            drives[n] = (int(parts[1]), len(parts) > 2 and parts[2] == "frag")
    return drives


def build(args):
    spc = args.spc                       # sectors per cluster
    rsvd = 32
    nfats = 2
    fatsz = 16                           # sectors per FAT (plenty for sim)
    part = 0 if args.superfloppy else args.part_start
    bytes_per_clus = spc * SEC
    drives = parse_drives(args.drive)

    if args.file_hex:
        with open(args.file_hex) as f:
            payload = bytes(int(line.strip(), 16) for line in f
                            if line.strip())
    else:
        payload = pattern_bytes(args.pattern)

    # ---- cluster allocation --------------------------------------------
    # root = 2, TRS80/ = 3, then the ROM chain, then per drive the
    # directory cluster and the image chain — in that order, so images
    # without --drive stay byte-identical to the previous generator.
    alloc = [4]                          # next free cluster (boxed)

    def take(n=1):
        c = list(range(alloc[0], alloc[0] + n))
        alloc[0] += n
        return c

    def chainify(ids, frag):
        if frag and len(ids) >= 2:
            return [ids[0]] + list(reversed(ids[1:]))
        return list(ids)

    rom_chain = []
    if not args.no_file:
        n = max(1, -(-len(payload) // bytes_per_clus))
        rom_chain = chainify(take(n), args.fragment)

    drv_dir_clus = {}
    drv_chain = {}
    drv_payload = {}
    for n in sorted(drives):
        size, frag = drives[n]
        drv_dir_clus[n] = take(1)[0]
        if size is not None:
            if isinstance(size, str):
                with open(size, "rb") as fh:
                    drv_payload[n] = fh.read()
            else:
                drv_payload[n] = pattern_bytes(size, seed=n + 1)
            nc = max(1, -(-len(drv_payload[n]) // bytes_per_clus))
            drv_chain[n] = chainify(take(nc), frag)

    nclusters = alloc[0] - 2 + 8         # small slack
    totsec = rsvd + nfats * fatsz + nclusters * spc

    img = bytearray(b"\xFF" * ((part + totsec) * SEC))

    def wr(lba, data):
        img[lba * SEC:lba * SEC + len(data)] = data

    # ---- MBR ----------------------------------------------------------
    if not args.superfloppy:
        mbr = bytearray(SEC)
        pe = 446
        mbr[pe] = 0x00                                   # not bootable
        mbr[pe + 1:pe + 4] = b"\xFE\xFF\xFF"             # CHS dummy
        mbr[pe + 4] = 0x0C                               # FAT32 LBA
        mbr[pe + 5:pe + 8] = b"\xFE\xFF\xFF"
        struct.pack_into("<I", mbr, pe + 8, part)
        struct.pack_into("<I", mbr, pe + 12, totsec)
        mbr[510:512] = b"\x55\xAA"
        wr(0, mbr)

    # ---- VBR + FSInfo --------------------------------------------------
    vbr = bytearray(SEC)
    vbr[0:3] = b"\xEB\x58\x90"
    vbr[3:11] = b"MSDOS5.0"
    struct.pack_into("<H", vbr, 11, SEC)                 # BytsPerSec
    vbr[13] = spc
    struct.pack_into("<H", vbr, 14, rsvd)
    vbr[16] = nfats
    struct.pack_into("<H", vbr, 17, 0)                   # RootEntCnt
    struct.pack_into("<H", vbr, 19, 0)                   # TotSec16
    vbr[21] = 0xF8
    struct.pack_into("<H", vbr, 22, 0)                   # FATSz16 (FAT32!)
    struct.pack_into("<H", vbr, 24, 63)
    struct.pack_into("<H", vbr, 26, 255)
    struct.pack_into("<I", vbr, 28, part)                # HiddSec
    struct.pack_into("<I", vbr, 32, totsec)              # TotSec32
    struct.pack_into("<I", vbr, 36, fatsz)               # FATSz32
    struct.pack_into("<I", vbr, 44, 2)                   # RootClus
    struct.pack_into("<H", vbr, 48, 1)                   # FSInfo
    struct.pack_into("<H", vbr, 50, 6)                   # BkBootSec
    vbr[64] = 0x80
    vbr[66] = 0x29
    struct.pack_into("<I", vbr, 67, 0x26702626)          # VolID
    vbr[71:82] = b"TRS80 REVZ "
    vbr[82:90] = b"FAT32   "
    vbr[510:512] = b"\x55\xAA"
    wr(part, vbr)

    fsi = bytearray(SEC)
    fsi[0:4] = b"RRaA"
    fsi[484:488] = b"rrAa"
    struct.pack_into("<I", fsi, 488, 0xFFFFFFFF)
    struct.pack_into("<I", fsi, 492, 0xFFFFFFFF)
    fsi[510:512] = b"\x55\xAA"
    wr(part + 1, fsi)

    # ---- FAT ------------------------------------------------------------
    fat = bytearray(fatsz * SEC)
    EOC = 0x0FFFFFFF

    def fset(i, v):
        struct.pack_into("<I", fat, 4 * i, v)

    def fchain(chain):
        for a, b in zip(chain, chain[1:]):
            fset(a, b)
        fset(chain[-1], EOC)

    fset(0, 0x0FFFFFF8)
    fset(1, 0xFFFFFFFF)
    fset(2, EOC)                                         # root dir
    fset(3, EOC)                                         # TRS80/
    if rom_chain:
        fchain(rom_chain)
    for n in sorted(drives):
        fset(drv_dir_clus[n], EOC)
        if n in drv_chain:
            fchain(drv_chain[n])
    for k in range(nfats):
        wr(part + rsvd + k * fatsz, fat)

    data0 = part + rsvd + nfats * fatsz

    def clus_lba(c):
        return data0 + (c - 2) * spc

    def wr_file(chain, data):
        pos = 0
        for c in chain:
            wr(clus_lba(c), data[pos:pos + bytes_per_clus])
            pos += bytes_per_clus

    # ---- root directory -------------------------------------------------
    root = bytearray(bytes_per_clus)
    root[0:32] = sfn_entry("TRS80 REVZ ", 0x08, 0, 0)    # volume label
    if not args.no_dir:
        root[32:64] = lfn_entries("trs80", "TRS80      ")
        root[64:96] = sfn_entry("TRS80      ", 0x10, 3, 0)
    wr(clus_lba(2), root)

    # ---- TRS80/ ---------------------------------------------------------
    sub = bytearray(bytes_per_clus)
    sub[0:32] = sfn_entry(".          ", 0x10, 3, 0)
    sub[32:64] = sfn_entry("..         ", 0x10, 0, 0)
    pos = 64
    if rom_chain and not args.no_dir:
        sub[pos:pos + 32] = lfn_entries("level2.rom", "LEVEL2  ROM")
        sub[pos + 32:pos + 64] = sfn_entry("LEVEL2  ROM", 0x20,
                                           rom_chain[0], len(payload))
        pos += 64
    for n in sorted(drives):
        name11 = f"DRIVE{n}     "
        sub[pos:pos + 32] = lfn_entries(f"drive{n}", name11)
        sub[pos + 32:pos + 64] = sfn_entry(name11, 0x10, drv_dir_clus[n], 0)
        pos += 64
    wr(clus_lba(3), sub)

    # ---- TRS80/DRIVEn/ --------------------------------------------------
    for n in sorted(drives):
        d = bytearray(bytes_per_clus)
        d[0:32] = sfn_entry(".          ", 0x10, drv_dir_clus[n], 0)
        d[32:64] = sfn_entry("..         ", 0x10, 3, 0)
        # decoy ahead of the image: the extension match must skip it
        d[64:96] = lfn_entries("notes.txt", "NOTES   TXT")
        d[96:128] = sfn_entry("NOTES   TXT", 0x20, 0, 0)
        if n in drv_chain:
            name11 = f"DISK{n}   DMK"
            d[128:160] = lfn_entries(f"disk{n}.dmk", name11)
            d[160:192] = sfn_entry(name11, 0x20, drv_chain[n][0],
                                   len(drv_payload[n]))
        wr(clus_lba(drv_dir_clus[n]), d)

    # ---- file payloads along their (possibly fragmented) chains ---------
    if rom_chain:
        wr_file(rom_chain, payload)
    for n in drv_chain:
        wr_file(drv_chain[n], drv_payload[n])

    with open(args.out + ".hex", "w") as f:
        f.write("\n".join(f"{b:02x}" for b in img) + "\n")
    with open(args.out + ".payload.hex", "w") as f:
        f.write("\n".join(f"{b:02x}" for b in payload) + "\n")
    for n in drv_payload:
        with open(f"{args.out}.d{n}.hex", "w") as f:
            f.write("\n".join(f"{b:02x}" for b in drv_payload[n]) + "\n")

    dinfo = {n: (drv_chain.get(n), drives[n][0]) for n in sorted(drives)}
    print(f"{args.out}.hex: {len(img)//SEC} sectors, part@{part}, spc={spc}, "
          f"rom clusters {rom_chain if rom_chain else '-'}, "
          f"payload {len(payload)} bytes, drives {dinfo if dinfo else '-'}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, help="output basename")
    ap.add_argument("--file-hex", help="payload as one-byte-per-line hex")
    ap.add_argument("--pattern", type=int, default=12288,
                    help="payload: N deterministic pattern bytes")
    ap.add_argument("--spc", type=int, default=8, help="sectors/cluster")
    ap.add_argument("--part-start", type=int, default=2048)
    ap.add_argument("--superfloppy", action="store_true",
                    help="no MBR: sector 0 is the VBR")
    ap.add_argument("--fragment", action="store_true",
                    help="ROM cluster chain out of order")
    ap.add_argument("--no-file", action="store_true",
                    help="TRS80/ exists but has no LEVEL2.ROM")
    ap.add_argument("--no-dir", action="store_true",
                    help="volume without TRS80/ at all")
    ap.add_argument("--drive", action="append", metavar="N:SIZE[:frag]",
                    help="add TRS80/DRIVEN/ with DISKN.DMK of SIZE pattern "
                         "bytes, N:@file = real file content, N:empty = "
                         "directory with only the decoy")
    args = ap.parse_args()
    build(args)


if __name__ == "__main__":
    main()
