# ADR-0005 — Expansion Interface: architecture, staging, and I/O egress

**Status:** accepted · 2026-07-19 (stages 1–5 shipped — RAM, EI container,
dual-controller FDC, mixed-density DMK; see ROADMAP M3. Stages 6–7 refined
2026-07-29, next up as ROADMAP M5/M6.)

## Context

M1 (ULX3S bring-up) is code-complete and simulation-proven; the plan pulls
the Expansion Interface (M3 core) forward,
in this order: basics, switchable 32K/48K RAM, WD1771 FDC with
SD-card disk images (read *and* write), Percom Doubler / double density,
RS-232-C, Centronics printer port. This ADR pins the architectural questions
so the stages can land one by one.

A key enabler discovered on the way: **trs80gp covers the whole EI roadmap as
a golden model** — `-m1 -mem 32|48` (RAM sizes), `-dN file.dmk` plus
`-im dump/trackdump` (floppy content introspection), `-ddp` (Percom Doubler),
`-r`/`-p` (serial/printer endpoints). Every stage keeps the byte-exact
verification pattern of chapters 1–8.

## Decisions

### 1. No new clock domain (the "Basics" question)

The EI brings no new CPU clock on real hardware; only the WD1771 runs its own
1 MHz clock. 1 MHz is not an integer divisor of the 10.6445 MHz dot clock —
but per ADR-0001 slower rates are one-cycle *enables*, and the FDC consumes
its clock only for coarse timing (step rates in ms, head-load delays, byte
rates of 64 µs SD / 32 µs DD). Decision: a **phase-accumulator enable**
(`acc += 1_000_000; if acc >= 10_644_500 { acc -= …; tick }`) — exact in the
mean, jitter of one dot clock, invisible at FDC timescales. The machine stays
single-domain; the DOS drivers and the golden runs are the arbiter of "close
enough". The EI heartbeat interrupt (40 Hz latch at 0x37E0, DOS's wall clock)
derives from the same scheme.

### 2. "Card cage" as a module seam, not a bus model

The goal is the EI as a slot machine (Apple II / IBM PC
style). In RTL this maps to: **each EI function is a self-contained module
with the chapter-3 bus idiom (dout + dout_en)**, composed in an `m1_ei`
container that owns the 0x37E0–0x37EF decode and the A15 memory region —
`m1_core` sees one seam. Slots stay a compile-time concept until the physical
card-cage hardware exists; nothing in the RTL shape blocks that future.

### 3. RAM: three configurations, run-time switchable

16K keyboard RAM (existing) + EI RAM at 0x8000–0xFFFF: **off / 16K / 32K**,
selected by ULX3S DIP switches, giving 16K/32K/48K systems. Unpopulated
regions behave like the real machine: open bus on reads, writes vanish.
Golden: trs80gp `-m1 -mem <k>` per configuration.

### 4. FDC: WD1771 at byte level, DMK on the SD card

Byte-level WD1771 (registers, Type I–IV commands, status/INTRQ/DRQ timing
from the 1 MHz enable) against a track buffer in BRAM; a DMK track (its real
strength: raw track bytes + IDAM pointers) is fetched from / written back to
the SD card by extending the existing FAT32 machinery with random file access
(offset → LBA via the cluster chain; writes are in-place — DMK files never
change size, so no allocation logic is ever needed). Read-only first
(acceptance: NEWDOS/80 boots, per ROADMAP), write-back second.

Card layout: `TRS80/DRIVE0..DRIVE3/`, the
**first `*.DMK` (8.3 match on the extension) in directory order** is mounted.
Images keep their meaningful names; a future ESP32 selector only ever has to
move files between folders. DMK is the only format until further notice.

### 5. Percom Doubler as the density story

Percom (not the Radio Shack doubler) is the target NEWDOS/80 expects:
WD1791-compatible command set + MFM, switched by the doubler's port. Golden:
`trs80gp -ddp`.

### 6. RS-232-C egress: the FTDI channel — no hub, no new hardware

The board reality: the ULX3S has **three** USB paths — US1 and US2 wired
raw to FPGA pins, plus the FT231X USB-serial bridge whose RX/TX are FPGA
pins (`ftdi_txd`/`ftdi_rxd`). US2 is the keyboard host. Decision: the EI
RS-232 board (ports 0xE8–0xEB, UART + baud-rate generator) is emulated
register-true, and its line side is routed to the **FTDI UART** — the same
USB cable that flashes the board shows up on the host as a serial device.
Zero additional hardware, no hub. Options kept open, not chosen now:
GPIO header + MAX3232 level shifter for *real* RS-232 peripherals
(the purist path), US1 as a soft USB device core (rejected for now: a
full-speed USB device core is a project of its own).

**Split TX/RX baud rate — a genuine hardware requirement, not a
nice-to-have (added 2026-07-29).** The real board's UART supports
independently configured transmit and receive baud rates — period-important,
since asymmetric links (e.g. 1200 baud receive / 75 baud send, common on
viewdata-style terminals) were routine and the TRS-80 natively supported
setting them separately. The register model must expose two independent
baud-rate dividers, not one shared rate. Open question, not resolved here:
the FTDI USB-serial bridge itself carries one configured baud rate on its
physical link to the host — how genuinely asymmetric TX/RX rates get
represented across that single-rate hop needs its own design pass when M5
is built. The register-level behavior on the TRS-80 side must be correct
regardless of how that hop is eventually resolved.

### 7. Centronics egress: register side now, spool-to-SD as primary sink

The printer port (memory-mapped 0x37E8) is trivial register-side: a data
latch plus a status byte that reports ready — that alone keeps `LPRINT`/DOS
from hanging. For the output itself, in order of preference:
**(a) spool to the SD card** (`TRS80/PRINT/`, plain text, append) — no
hardware, self-contained (no ESP32 needed), and the FDC work delivers SD writing
anyway; (b) GPIO header wired as a real Centronics port (latch + STROBE/BUSY
handshake is ~20 lines) for driving period printers; (c) ESP32 network
printing, post-M3 with the companion ADR. The register side ships with the
FDC stage; the spool sink lands once SD write-back exists.

**Spool layout and rotation (refined 2026-07-29):** directory
`TRS80/LINEPRINTER_OUTPUT/`, plain text, append-only. A file stays open and
keeps accumulating output across print jobs; a **new file opens after ~5
minutes of print inactivity** (session boundary), and independently the
file **rotates daily** even mid-session. Exact filename scheme (timestamp
vs. sequence number) is open for the implementation pass — the two rules
(idle-gap rotation, daily rotation) are the fixed part.

## Consequences

- Stage order: **RAM → FDC read (NEWDOS/80 boots) → FDC write → Percom/DD →
  RS-232 → Centronics sink** — each stage golden-verified before the next.
- The SD loader's one-shot FAT reader grows into a small random-access file
  layer shared by ROM loading, disk images, and print spooling.
- `wifi_en` stays low (ADR-lite in the top level); nothing here needs the
  ESP32, keeping the debug-server companion a clean post-M3 project.
- The 40-pin Model 1 expansion connector semantics (TEST* bus handover)
  stay faithfully modeled in `m1_core`, which is exactly what the future
  debug adapter will dock onto.
