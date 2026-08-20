# ULX3S GPIO budget — dongle mode, Centronics, RS-232

**Status:** working document, 2026-08-20. Plans the ULX3S header pins
*before* any connector or interposer is ordered. Decisions that survive
contact with hardware graduate into an ADR; sourced constraints below cite
their records. Header pin *sites* are deliberately not assigned here —
they get fixed against the published ULX3S pinout in the board LPF when
each consumer is actually built (same discipline as `ulx3s_v20.lpf`:
constrain only what the top-level uses).

## What does NOT come out of the header budget

Already carried by dedicated board resources (see `boards/ulx3s/ulx3s_v20.lpf`):

| Function | Resource |
|---|---|
| Video | GPDI (DVI) pads |
| Keyboard | US2 USB (D+/D− + pull control) |
| ROM/disks/spool | micro-SD pads (shared with ESP32, ADR-0008 §4) |
| RS-232-C **egress, chosen path** | FT231X `ftdi_txd`/`ftdi_rxd` (ADR-0005 §6) |
| Centronics **sink, chosen path** | SD spool (ADR-0005 §7) |
| Debug host link | same FTDI UART (ADR-0006) |
| ESP32 companion link | on-board ESP32 pins (ADR-0008) |

The committed M5/M6 designs therefore need **zero** header pins. The
header budget below is entirely about the *optional/physical* variants.

## Header consumers

### 1. Debug-dongle interposer (ADR-0009 Phase 0) — the priority consumer

Per ADR-0009 (post-level-shifter, 74LVC245 banks on the interposer):

| Signals | Pins |
|---|---|
| A0–A15 | 16 |
| D0–D7 | 8 |
| RD\*/WR\* | 2 |
| TEST\* out | 1 |
| INT\* out (IM-2 entry) | 1 |
| SYSRES\* sense | 1 |
| shifter DIR | 1 |
| **Baseline** | **30** |
| optional IN\*/OUT\* (I/O watchpoints) | +2 |
| optional WAIT\* | +1 |
| **Full** | **33** |

### 2. GPIO Centronics (ADR-0005 §7 option b) — optional, for period printers

D0–D7 (8) + STROBE\* (1) + BUSY (1) = **10**; +ACK\*/PE/SELECT if wired
fully = **13**. 5 V TTL side → needs its own 74LVC245-class shifting
(printer side is an output-heavy port; one shifter bank + pull-ups).

### 3. GPIO RS-232 via MAX3232 (ADR-0005 §6, purist path) — optional

TXD + RXD = **2**; +RTS/CTS = **4**. Level shifting is the MAX3232
module's job; no direction logic needed.

## The budget

The ULX3S exposes 56 header GPIO signals nominally (GP/GN 0–27); a
subset is shared with other board functions — **verify the usable count
against the published ULX3S pinout before committing pin sites** (same
caveat as ADR-0009's connector note). Worst case demand:

| Scenario | Pins |
|---|---|
| Dongle full | 33 |
| + Centronics full | +13 → 46 |
| + RS-232 w/ handshake | +4 → 50 |

50 of ~56 nominal is *arithmetically* possible but leaves no margin once
shared-function pins are subtracted — and it buys nothing, because the
three consumers never need to coexist:

## Recommendation

1. **The dongle interposer owns the header.** It is the only consumer
   with a committed roadmap link (ADR-0009 Phase 0) and the only one
   that needs the wide bus. Reserve the full 33-pin allocation for it.
2. **Centronics-GPIO and RS-232-GPIO are alternative bitstreams, not
   roommates.** A machine acting as a debug dongle is not simultaneously
   driving a daisy-wheel printer. Both options, if ever built, reuse
   pins from the dongle allocation with their own LPF variant — no
   partitioning, no permanent reservation.
3. **Nothing is ordered before ADR-0009's open verifications close:**
   EI J3 vs keyboard-edge pinout/pitch from the service manuals, and the
   usable-header-pin count from the ULX3S pinout.
4. When the dongle interposer PCB is designed, its pin map lands in a
   dedicated LPF include and this document graduates into the ADR-0009
   follow-up record.
