#!/usr/bin/env python3
"""Convert a binary PGM (P5) frame dump to PNG. Stdlib only, no PIL.

The testbenches write raw frames as PGM because that is trivial from Verilog
($fwrite); this turns them into something a human clicks on. Grayscale in,
grayscale out, plus an optional integer upscale so a 384x192 TRS-80 frame
becomes comfortably viewable (dots were not square on a real CRT; --scale-x/-y
let you approximate the 2:3-ish aspect if you care).

Usage: pgm2png.py in.pgm out.png [--scale N] [--scale-x N] [--scale-y N]
"""

import struct
import sys
import zlib


def read_pgm(path):
    with open(path, "rb") as f:
        data = f.read()
    # Header: P5 <ws> width <ws> height <ws> maxval <single ws> raster
    if not data.startswith(b"P5"):
        sys.exit(f"{path}: not a binary PGM (P5)")
    fields = []
    pos = 2
    while len(fields) < 3:
        while pos < len(data) and data[pos : pos + 1].isspace():
            pos += 1
        if data[pos : pos + 1] == b"#":  # comment line
            while data[pos : pos + 1] not in (b"\n", b""):
                pos += 1
            continue
        start = pos
        while pos < len(data) and not data[pos : pos + 1].isspace():
            pos += 1
        fields.append(int(data[start:pos]))
    pos += 1  # single whitespace after maxval
    width, height, maxval = fields
    if maxval > 255:
        sys.exit(f"{path}: 16-bit PGM not supported")
    raster = data[pos : pos + width * height]
    if len(raster) != width * height:
        sys.exit(f"{path}: raster truncated ({len(raster)} of {width*height} bytes)")
    return width, height, raster


def write_png(path, width, height, raster, sx=1, sy=1):
    w, h = width * sx, height * sy
    rows = []
    for y in range(height):
        line = raster[y * width : (y + 1) * width]
        if sx != 1:
            line = bytes(b for b in line for _ in range(sx))
        for _ in range(sy):
            rows.append(b"\x00" + line)  # filter type 0 per scanline
    def chunk(tag, payload):
        return (
            struct.pack(">I", len(payload))
            + tag
            + payload
            + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
        )
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0)  # 8-bit grayscale
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", zlib.compress(b"".join(rows), 9)))
        f.write(chunk(b"IEND", b""))


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    opts = [a for a in argv[1:] if a.startswith("--")]
    if len(args) != 2:
        sys.exit(__doc__.strip().splitlines()[-1])
    sx = sy = 1
    for o in opts:
        key, _, val = o.partition("=")
        if key == "--scale":
            sx = sy = int(val)
        elif key == "--scale-x":
            sx = int(val)
        elif key == "--scale-y":
            sy = int(val)
        else:
            sys.exit(f"unknown option {key}")
    width, height, raster = read_pgm(args[0])
    write_png(args[1], width, height, raster, sx, sy)
    print(f"{args[1]}: {width*sx}x{height*sy} from {width}x{height}")


if __name__ == "__main__":
    main(sys.argv)
