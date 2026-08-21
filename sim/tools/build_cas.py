#!/usr/bin/env python3
"""Build a deterministic 500-baud test cassette (M2, sim tooling).

Produces the same tape twice:
  <out>.cas        — the raw byte stream (leader + sync + payload), the
                     format trs80gp inserts with -c
  <out>_pulses.hex — one pulse timestamp per line (decimal microseconds
                     from motor-on), for sim/cass_media_model.sv

Level II 500-baud encoding (Technical Manual 1978, "Cassette Audio
Input/Output"; verified shapes against trs80gp): 2 ms per bit, MSB
first. Every bit cell starts with a clock pulse; a '1' carries a second
pulse 1 ms into the cell. A 0x00 byte is therefore 8 clock pulses 2 ms
apart — the leader is a run of those, and the 0xA5 sync byte is the
first pattern that breaks it.

Tape layout here (SYSTEM-style but self-defined — this is OUR tape):
  leader 0x00 x LEADER, sync 0xA5, then the payload bytes verbatim.
The default payload is 16 bytes of t*13+7 (mod 256) — easy to check on
the far side and pairwise distinct.
"""

import argparse

BIT_US = 2000            # 500 baud
DATA_OFF_US = 1000       # '1' pulse sits mid-cell
START_US = 20000         # tape silence before the leader (motor spin-up)


def tape_bytes(leader, payload):
    return bytes([0x00] * leader + [0xA5]) + payload


def pulses(data):
    """Pulse timestamps (us) for the byte stream, MSB first."""
    out = []
    t = START_US
    for b in data:
        for i in range(7, -1, -1):
            out.append(t)                    # clock pulse
            if (b >> i) & 1:
                out.append(t + DATA_OFF_US)  # data pulse
            t += BIT_US
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--leader", type=int, default=32)
    args = ap.parse_args()

    payload = bytes((t * 13 + 7) & 0xFF for t in range(16))
    data = tape_bytes(args.leader, payload)

    with open(args.out + ".cas", "wb") as f:
        f.write(data)
    p = pulses(data)
    with open(args.out + "_pulses.hex", "w") as f:
        f.write("\n".join(str(x) for x in p) + "\n")

    csum = sum(payload) & 0xFF
    print(f"{args.out}: {len(data)} tape bytes, {len(p)} pulses, "
          f"{p[-1]/1e6:.2f} s, payload checksum {csum:02X}")


if __name__ == "__main__":
    main()
