# ULX3S-85F target

The primary (and only committed) hardware target: ULX3S with Lattice ECP5-85F.
Toolchain: yosys → nextpnr-ecp5 → prjtrellis, upload via openFPGALoader/fujprog.
Constraints, top-level wrapper, and board-specific glue (HDMI, USB keyboard, SD)
live here; the machine itself lives in `rtl/` and stays board-agnostic.

The board is open hardware by [Radiona](https://radiona.org/ulx3s/) (Zagreb, Croatia);
the 85F variant (LFE5U-85F) is the one this target assumes, although 45F variant will work (untested).

## Getting a board

Status 2026-07 — availability moves, the links don't:

- **[Crowd Supply](https://www.crowdsupply.com/radiona/ulx3s)** — the primary
  channel; the 85F ships in batches (current batch ships from 2026-08-21).
- **Mouser** — the 85F is
  [CS-ULX3S-03](https://www.mouser.com/ProductDetail/Radiona/CS-ULX3S-03)
  (US) / [eu.mouser.com](https://eu.mouser.com/ProductDetail/Crowd-Supply/CS-ULX3S-03)
  (EU), currently backorder; the 12F is CS-ULX3S-01. Intergalatik has announcned the
  avialability of a new batch mid [July 2026](https://www.linkedin.com/posts/intergalaktik-d-o-o_batch-opensource-ulx3s-activity-7482138909519429632-1CuQ?utm_source=share&utm_medium=member_desktop&rcm=ACoAAAAOl94BXYC9-vjYpqYVyciphlh0ri8jvfM)
- **[Lectronz](https://lectronz.com/products/ulx3s-85f-v3-1-8)** — the makers'
  direct EU shop (Intergalaktik, Zagreb); restock notifications available.

On the smaller ECP5 variants: the current design uses ≈15 k LUTs and 81 of
208 block RAMs (the debug core's non-intrusive memory path adds second BRAM
read ports — see DEBUG-PROTOCOL.md) — the 45F would carry it at ~75 % BRAM,
the 12F would not. The committed target, and the only tested one, is the
85F; the headroom is reserved for the Vision tier.

## Build & flash

```
make            # bitstream in build/ulx3s_top.bit
make prog       # flash to SRAM (board attached)
cd sim && make  # board-level testbenches (Verilator)
```

No board? The simulation branch still runs everything: `cd sim && make`
builds the board-level Verilator testbenches (SD loader, FAT reader, DMK
track fetch, HDMI/TMDS, USB keyboard mapping) with the same byte-exact
proofs. If a build breaks on your toolchain versions or a proof diverges,
please open an issue — that report is a contribution.

## ROM from SD card

The bitstream contains no Tandy ROM (see `roms/README.md`). At power-on the
machine first runs the repository's own self-test image ("TRS-80 REV Z  OK");
in parallel, `m1_sd_fs` mounts the micro-SD card and — if it finds the
ROM file — re-loads the system ROM behind a second reset. Card layout,
following the usual one-folder-per-core ULX3S convention:

```
TRS80/
  LEVEL2.ROM     12 KiB Level II BASIC image (user-supplied)
  DRIVE0/        floppy image for drive :0 — the FIRST *.DMK in the
  DRIVE1/        directory is mounted (same for :1..:3); other files
  DRIVE2/        are ignored, missing directories leave the
  DRIVE3/        drive empty
  CASSETTE/      the tape in the deck — the FIRST *.CAS is mounted and
                 plays into the cassette input at 500 baud (M2);
                 motor-gated, pauses in place, rewinds at end-of-tape
  CASSOUT.CAS    recording target: everything the machine writes
                 (CSAVE, SYSTEM tapes) is decoded and stored here
                 IN PLACE — create the file beforehand at the size you
                 want (e.g. 64 KiB of zeros); successive saves append
                 until power-off
```

Double-sided DMK images (header byte 4 bit 4 clear, two track blocks
per cylinder) are served with the DS drive-select convention — latch
bit 3 selects head 1, so NEWDOS/80 DS volumes like an 80-cylinder
nd80206 boot directly.

* Card: FAT32 (the out-of-the-box format of 4–32 GB cards; exFAT is not
  supported). Both factory MBR-partitioned cards and "superfloppy" cards
  work. Long filenames are fine — matching happens on the 8.3 entries, so
  `trs80/level2.rom` created on any OS is found.
* No card, no file, unreadable filesystem: the self-test banner stays on
  screen — the machine is never left dead or running a half-written ROM
  (a load that fails midway is zero-filled deterministically).
* `led[2]` reports the outcome: on = Level II loaded from card.
* The SD lines are shared with the ESP32; this bitstream holds the ESP32
  in reset (`wifi_en = 0`) for deterministic bus ownership. The ESP32
  companion (debug server) returns post-M3 with its own ADR.

Loader facts: own SPI host + streaming FAT32 reader (no sector buffer,
no vendored FS core), single clock domain per ADR-0001, ~2.66 MHz data
clock — the 12 KiB ROM is on screen well under 200 ms after power-up.
Proofs live in `sim/tb_sd_loader.sv` (byte-exact load across a fragmented
cluster chain, SDHC and SDSC, boot-from-SD to the golden marker, and the
no-card / no-file fallbacks).

After the ROM phase, `m1_sd_fs` walks each drive image's cluster chain
once into a BRAM cluster→LBA map (4 × 256 entries) and then serves random
512-byte sector reads in O(1) — the seam the WD1771 FDC (EI stage 2,
ADR-0005) reads tracks through. Images up to 2 MiB; a chain that does not
fit the map leaves that drive unmounted. Proofs live in `sim/tb_sd_fs.sv`
(mount mask with a decoy file, a fragmented image read in full, random
access across drives, partial last sector, refusal paths, SDHC + SDSC).
