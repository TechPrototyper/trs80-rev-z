#!/usr/bin/env python3
"""Convert a raw ROM binary to Verilog $readmemh hex (sim/emu and rtl/*.v
both load ROM images this way — see roms/README.md and sim/emu/README.md).

Output format: one hex byte per line (two lowercase hex digits, no address
tags, no prefix) — exactly what sim/emu/main.cpp's load_hex() and the RTL's
$readmemh() initial blocks expect.

The reference Level II BASIC image is 12288 bytes (12 KiB). This tool warns
rather than errors on a different size: 14336-byte dumps and other variants
exist in circulation (see roms/README.md) and may still be useful even
though they are not the verification reference.

Usage:
    sim/tools/bin2hex.py roms/level2.rom roms/level2.hex
"""

import argparse
import sys

REFERENCE_SIZE = 12288  # 12 KiB Level II BASIC 1.3


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("infile", help="raw ROM binary (e.g. roms/level2.rom)")
    parser.add_argument("outfile", help="$readmemh hex output (e.g. roms/level2.hex)")
    args = parser.parse_args()

    with open(args.infile, "rb") as f:
        data = f.read()

    if len(data) != REFERENCE_SIZE:
        print(
            f"bin2hex.py: warning: {args.infile} is {len(data)} bytes, "
            f"expected {REFERENCE_SIZE} (12 KiB) for the reference Level II "
            "BASIC 1.3 image — see roms/README.md",
            file=sys.stderr,
        )

    with open(args.outfile, "w") as f:
        for byte in data:
            f.write(f"{byte:02x}\n")

    print(f"{args.outfile}: {len(data)} bytes written")


if __name__ == "__main__":
    main()
