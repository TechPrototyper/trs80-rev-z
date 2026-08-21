#!/usr/bin/env python3
"""Dump the TRS-80 screen headless via the emulator's --debug-pty.

Speaks binary protocol v0 (docs/DEBUG-PROTOCOL.md): HALT, READ_MEM
0x3C00..0x3FFF, RUN — then renders the VRAM as text (bit-6 fold per
chapter 3; block graphics shown as '#').

Usage: python3 tools/emu_screen_dump.py /dev/ttysNN
(the pty path is printed by sim/emu's --debug-pty at startup)

Note: HALT freezes only the CPU — the FDC keeps pacing (like a real
ICE), so avoid dumping while a sector transfer is in flight."""
import os, sys, time, tty

dev = sys.argv[1]
if dev.startswith("tcp:"):
    import socket
    _sk = socket.create_connection(("127.0.0.1", int(dev[4:])), timeout=10)
    _sk.setblocking(False)
    fd = _sk.fileno()
else:
    fd = os.open(dev, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    tty.setraw(fd)

buf = b''
def rd(n, timeout=20):
    global buf
    t0 = time.time()
    while len(buf) < n and time.time() - t0 < timeout:
        try: buf += os.read(fd, 512)
        except BlockingIOError: time.sleep(0.01)
    out, buf = buf[:n], buf[n:]
    return out

def strip_events(data):
    # drop interleaved async events (80 cause pc pc)
    out = bytearray()
    i = 0
    while i < len(data):
        if data[i] == 0x80 and i + 3 < len(data):
            i += 4
        else:
            out.append(data[i]); i += 1
    return bytes(out)

os.write(fd, bytes([0x01]))            # HALT -> 01 pc pc
rd(3)
os.write(fd, bytes([0x06, 0x00, 0x3C, 0x00, 0x04]))  # READ_MEM 3C00 x400
r = rd(1 + 1024, timeout=30)
os.write(fd, bytes([0x02]))            # RUN
rd(1)
os.close(fd)

r = strip_events(r)
assert r and r[0] == 0x06, r[:4].hex()
vram = r[1:1025]
for row in range(16):
    line = ''
    for c in vram[row*64:(row+1)*64]:
        # Model 1 VRAM bit-6 fold (chapter 3): displayed glyph
        if c < 0x20: c += 0x40
        line += chr(c) if 32 <= c < 127 else ('#' if c >= 128 else '.')
    print(line.rstrip())
