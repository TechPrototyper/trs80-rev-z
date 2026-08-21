#!/usr/bin/env python3
"""Decode a recorded cassette pulse list back to bytes and compare.

Input: a file of pulse timestamps (decimal microseconds, one per line —
the deck model's +caswr dump or any pulse capture). Decoding mirrors
the read probe: a pulse ~1 ms after a clock pulse is a '1', the next
clock follows at the 2 ms boundary; bits shift MSB first; the stream is
aligned at the 0xA5 sync byte.

Usage: check_cass_write.py <pulses> [expected-hex-bytes]
Default expectation: A5 + the standard 16-byte payload (t*13+7).
Exit 1 on mismatch.
"""

import sys

pulses = [int(x) for x in open(sys.argv[1]) if x.strip()]
if len(sys.argv) > 2:
    expected = bytes.fromhex(sys.argv[2])
else:
    expected = bytes([0xA5] + [(t * 13 + 7) & 0xFF for t in range(16)])

# pulse gaps -> bits: after a clock, a pulse < 1.5 ms away is a data
# pulse ('1', and the pulse after it is the next clock); >= 1.5 ms means
# '0' and the pulse IS the next clock.
bits = []
i = 0
while i < len(pulses) - 1:
    gap = pulses[i + 1] - pulses[i]
    if gap < 1500:
        bits.append(1)
        i += 2
    else:
        bits.append(0)
        i += 1
# the stream ends after the last clock; trailing '0' bits of the final
# byte produce no pulses at all, so pad with zeros
bits += [0] * 16

stream = bytearray()
# assemble bytes MSB first from bit 0 (the writer is byte-aligned from
# the first pulse; the leader is all-zero bytes)
for k in range(0, len(bits) // 8 * 8, 8):
    b = 0
    for j in range(8):
        b = (b << 1) | bits[k + j]
    stream.append(b)

s = bytes(stream)
i = s.find(0xA5)
if i < 0:
    print("FAIL  no A5 sync byte in the decoded stream:", s.hex())
    sys.exit(1)
got = s[i:i + len(expected)]
if got == expected:
    print(f"MATCH  decoded stream from sync on: {got.hex()} "
          f"({len(pulses)} pulses, {i} leader bytes)")
else:
    print(f"FAIL  decoded {got.hex()}\n      expected {expected.hex()}")
    sys.exit(1)
