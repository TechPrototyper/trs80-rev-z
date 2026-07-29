# Specification — Reference Configuration

**Status:** v1.0 draft (distilled from the project research notes, 2026-07 — see
[RESEARCH.md](RESEARCH.md))
This document defines **which historical machine is being rebuilt** and serves as the
acceptance standard for all RTL. Deviations are bugs.

---

## 1. Reference machine

| Element | Definition | Reasoning |
|---|---|---|
| **Mainboard** | **Model 1, Revision G** | Last US revision; Tandy's own Technical Reference (2nd ed.) documents D/E/G only. 12K ROM on board. |
| **CPU** | Z80 @ 1.774 MHz (10.6445 MHz ÷ 6) | Original clock, derived from the master oscillator like the real board. |
| **ROM** | **Level II BASIC 1.3** (~July 1980) | Last official release (keyboard debounce in ROM, cassette timing fix). Identifiable without checksum tables: 1.3 prompts `MEM SIZE?` / banner `R/S L2 BASIC`; earlier versions prompt `MEMORY SIZE?` / `RADIO SHACK LEVEL II BASIC`. |
| **RAM** | 48 KB (16K board + 32K expansion interface) | Historical maximum. |
| **Video** | 64×16 characters, block graphics, 6-bit character generator | Character cells 6×12 dots; every character row is read **12 times, once per scanline** — this property is load-bearing (see §3 and §6). |
| **Expansion Interface** | Final ("redesigned") PCB generation | Generates RAS*/MUX/CAS* locally instead of over the unbuffered ribbon cable. |
| **FDC** | **WD1771 + WD1791 in parallel** (Percom-Doubler principle) | See §4 — neither chip alone is sufficient. |
| **Provenance** | **Tandy/Radio Shack. No clones.** | No Video Genie, System 80, Komtek — as *reference*. (Clone compatibility may fall out for free; it is never the yardstick.) |

Rev-G features explicitly carried over: steppable clock / TEST* (the original debug
hook), 7/8-bit character-set jumper (as config bit), exchangeable character generator.

### ROM policy

Level II BASIC is copyrighted (Tandy/Microsoft). **ROM images are never part of this
repository or bitstream.** The design loads ROM at runtime (SD/ESP32); `roms/README.md`
documents legal sourcing and identification (size 12288, version discrimination via
banner text; reference is 1.3).

---

## 2. Two operating modes: Goldstandard and Rev Z

The machine is not a compromise between authentic and improved — it is **both,
switchable**:

- **Goldstandard** = Model 1 Rev G as it stood in the shop in 1980. All quirks in, all
  retrofits out. This mode is the verification anchor.
- **Rev Z** = the revision Tandy never built: Rev G plus every sensible correction and
  extension. Each individually switchable, plus an en-bloc master switch.

> **The rule:** every Rev-Z switch, when off, must yield **bit-exact** Goldstandard
> behavior. A switch that can't is not a switch but a fork.

### Switch catalog

| # | Topic | Default | Notes |
|---|---|---|---|
| Z1 | **Video snow** (CPU VRAM access blanks the read path) | **ON** (= snow present) | Part of system behavior; many programs look wrong without it. Snow and beam-hack capability are the *same* circuit property seen from two sides. |
| Z2 | Keyboard bounce | **not modeled** | Pure material defect without software meaning; ROM 1.3 debounces anyway. |
| Z3 | **Lowercase** (bit 6 RAM, the classic piggyback mod) | **ON** | Rev G carries the hardware; most widespread period mod. |
| Z4 | XRX cassette fix | **not modeled** | Patch for pre-Rev-G boards; Rev G solves it in circuit. |
| Z5 | **Doubler module** (Double Density) | ON (Goldstandard: OFF) | Standard Expansion Interfaces were SD-only; DD was added via daughterboards (Percom, Tandy 26-1143), modeled as a detachable module rather than part of the base EI core. |
| Z6 | Doubler protocol | **both** (exclusively selectable) | Percom / Tandy / both / none; detection routines (Super Utility) can misread "both". |
| Z7 | DD boot | **OFF** (track 0 = SD) | Historically a user-soldered switch. |
| Z8 | **Raster interrupt + scanline status bit** | **OFF** | Not historical; justified by the precisely documented *absence* (George Phillips' beam-hack notes). Enables beam-synced software rather than replacing it. |
| Z9 | **PCG-80 / 80-GRAFIX** programmable character generator | **OFF** | The only Model 1 hi-res path with real software; references: PACE implementation, trs80gp `-pcg-80`. |
| Z10 | **Omikron mapper** (CP/M) | **OFF** | Preservation: original CP/M distributions were shipped *for* this mapper. Draft — source material secured, spec pending. |
| Z11 | **Rev-Z 64 KB board** (CP/M) | **OFF** | +16 KB at $0000–$3FFF, phantom boot ROM, banked I/O window (Model 4 precedent). Draft. |

**Explicitly rejected:** a hardware bitmap hi-res port for the Model 1. No Tandy hi-res
board for the Model 1 ever existed (26-1125/26-1126 are Model III/4), and the famous
128×192 technique is a *software* trick on stock timing. Building replacement hardware
for it would destroy the timing proof (§6) while serving no historical software.

---

## 3. Memory map (Model 1)

| Range | Contents |
|---|---|
| `$0000–$2FFF` | Level II ROM (12 K) — **real ROM, not a preinitialized flat RAM array** |
| `$3000–$37DF` | open bus (stock) |
| `$37E0–$37EF` | EI: interrupt status, drive select, **FDC `$37EC–$37EF`** (memory-mapped!) |
| `$3800–$38FF` | keyboard matrix |
| `$3C00–$3FFF` | video RAM (1 K) |
| `$4000–$FFFF` | RAM (16 K + 32 K EI) |

A flat 64 K preinitialized array is not an acceptable implementation: ROM/RAM separation,
open-bus behavior, and the memory-mapped FDC window are all observable machine behavior.

---

## 4. FDC and double density (M3)

Verified findings the design rests on:

1. Standard Tandy Expansion Interfaces shipped with only a WD1771 Single-Density controller.
   Double-density support on original Radio Shack hardware was provided via add-on daughterboards —
   either third-party options (such as the Percom Doubler) or Tandy's official Model I 
   Double-Density Disk Kit (Cat. No. 26-1143, released in May 1982, the Model 1 wasn't produced
   anymore at that time), which plugged directly into the WD1771 IC socket with no trace cuts or
   jumpers required. Hence: DD is specified as an optional, detachable Doubler module (switch Z5), 
   separate from the stock base EI core.
2. The **WD1771 cannot be replaced by a 179x**: the 1771 reads/writes four data address
   marks (`FB/FA/F9/F8`); the 179x knows only two and cannot distinguish `FB/FA` or
   `F8/F9` even in FM. **Model 1 TRSDOS uses `FA` on directory sectors.** All historical
   doublers therefore *kept* the 1771 for SD work.
3. Consequently: **two controller cores** (1771 SD, 1791 DD) with **fully independent
   register state**, swapped as a set on density switch (xtrs model).
4. **Percom protocol is primary** (`$37EC` command-register select, `FE`=1771/`FF`=1791);
   the Tandy 26-1143 protocol (`$37EE` sector-register upper bits) is additionally
   decoded. Reset state: SD, side 0, no precomp — a non-doubler DOS sees a stock machine.
5. **Mixed density is a hard requirement:** real-world NEWDOS/80 system disks used
   SD boot sectors + DD elsewhere — density changes per track at runtime. Therefore the
   image format must express per-track density: **DMK is mandatory; JV1 is structurally
   insufficient.**

Later (vision tier): FreHD-style hard disk (WD1010 at `$C8–$CF`) — complements the FDC,
different address space.

---

## 5. Acceptance criteria for any adopted code

**Must** (otherwise not a basis, at most a reference):
ULX3S-85F native with open toolchain · Z80 @ 1.774 MHz cycle-accurate enough for
golden-model comparison · unpatched Tandy Level II ROM loaded at runtime · 48 KB ·
real ROM/RAM separation · address decode per §3.

**Should:** snow behavior present or retrofittable · exchangeable character generator ·
cassette loading.

The survey of existing cores against this list is in [RESEARCH.md](RESEARCH.md).

---

## 6. Verification methodology

- **Simulation before silicon.** Verilator harness first; hardware bring-up is the last
  step of a milestone, not the first.
- **Golden models:** trs80gp and/or MAME. Verification means **byte-exact VRAM/memory
  comparison**, not visual inspection.
- **Timing proof:** the machine's documented video timing (1 T-state = 6 dots,
  112 T-states/line, 12× character reread, CPU wins VRAM arbitration) must emerge from
  the implementation such that (a) snow appears exactly where real hardware shows it and
  (b) documented beam-synced software techniques work on the Goldstandard configuration
  **without any dedicated hardware support**. Beam-hack capability is a test criterion,
  not a feature.

---

## 7. Sources

Primary: Tandy TRS-80 Technical Reference Handbook, 2nd ed. (1982) · TRS-80 Technical
Manual: Theory/Parts/Schematics (1978) · Expansion Interface Service Manuals (both
generations) — referenced, not redistributed; see [RESOURCES.md](RESOURCES.md) for
archives, plus RetroStack's MIT-licensed KiCad recreation of the Rev G board as a
machine-readable cross-check. Key secondary sources: Tim Mann (disk formats, 1771/179x
DAM analysis), George Phillips (48k.ca timing write-ups, trs80gp), trs-80.org and
trs-80.com (revision and peripheral history).
