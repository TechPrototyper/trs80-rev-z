# Research Notes — what is already settled, and how

This project did its survey homework before writing RTL. This document exists so that
reviewers spend their time on the *open* questions, not the answered ones — and so that
every settled claim can be attacked with sources. Corrections welcome (see
[CONTRIBUTING](../CONTRIBUTING.md)).

## 1. Survey of existing TRS-80 FPGA work

Five candidates were evaluated against the acceptance criteria in [SPEC.md §5](SPEC.md).
**Result: none qualifies as the base; several are valuable as references or delta
sources.** This is not a criticism of their authors — each project had different goals.

| Core | Strengths | Why not the base | License status |
|---|---|---|---|
| **PACE / trs80 m1** (Mark McDougall) | By far the most faithful Model 1: real ROM/RAM separation, correct address decode, unpatched Tandy ROM, the **only PCG-80 HDL implementation anywhere**, flux-level WD179x | Xilinx/Altera targets; FDC hard-wired to DD (can't do mixed density); no snow | No license file — **author granted permission by e-mail (2026-07-17)** to use as a basis for this MIT project, credit requested. See [permissions](../licenses/permissions/). |
| **big80** (Brad Robinson) | Most complete *documented* implementation — the accompanying articles explain the *why*; proper ROM/RAM split, cassette handling, OSD | Spartan-6 (Mimas V2) target — port required; no snow, no mixed density | Apache-2.0; **dual-licensed MIT by the author on request (2026-07-17)** — now formalized in his repo. |
| **ulx3s_trs_80 / ulx3s_z80_trs80** (Lawrie Griffiths) | The only cores that run **natively on the ULX3S with the open toolchain**; HDMI path, ESP32 integration, build flow | Flat preinitialized 64 K array, patched ROM, no snow | No license; inquiry sent, response pending. |
| **TRS-80 MiSTer core** | Mature ecosystem | Based on the HT1080Z **clone**, JV1-only disk model (no per-track density) | No license file. |
| *(evaluated for methods)* **trs80gp, xtrs, MAME** | Golden models for verification; xtrs documents the dual-controller/doubler logic in detail | Emulators, not HDL | — |

Also secured as source material: **RetroStack's TRS-80-Model-I-G-E1** — an MIT-licensed
KiCad recreation of the Rev G mainboard, sheet-per-subsystem, including documented errata
of the original board. Machine-readable cross-check against the Tandy schematics.

## 2. ROM forensics

- Version discrimination without checksum folklore: **1.3** prompts `MEM SIZE?` /
  `R/S L2 BASIC`; earlier versions `MEMORY SIZE?` / `RADIO SHACK LEVEL II BASIC`
  (prompts were shortened in 1.3 to free space). Difference 1.3 vs. early: 154 of
  12288 bytes.
- A widely circulated 14336-byte "Level II" image (`BOOT.ROM` / `trs80.mem`) turned out
  to be an early Level II with the **banner patched out**, an autoboot patch, and 2 KB of
  third-party keyboard-routine code at `$3000` — where the real machine has **no ROM at
  all**. Not usable as a reference; anything derived from it inherits fiction.
- A secondhand claim that a common image was a "Video Genie ROM" was checked and is
  **false** — no Genie/System-80 markers exist in it; it is patched Tandy code.

## 3. Hi-res: three corrected misconceptions

1. **There was never a Tandy hi-res board for the Model 1.** 26-1125 is Model III
   (1982), 26-1126 is Model 4. For the Model 1, only third-party solutions existed —
   and of those, only the programmable-character-generator family (80-GRAFIX, PCG-80)
   ever had a real software base.
2. **The famous 128×192 full-screen technique is a Model 3 achievement** (George
   Phillips), not Model 1. For the Model 1 he wrote only a few beam-synced programs —
   because the machine lacks any automatic beam-sync means. That *lack* is precisely
   documented in his write-ups (48k.ca) — which is the justification for the optional
   Rev-Z raster interrupt (Z8), and simultaneously the reason the stock timing must be
   good enough to support beam hacks unaided (test criterion, SPEC §6).
3. **No hardware bitmap port.** An earlier draft of this spec specified one ($FB, paged
   12 K); it was rejected: hardware replacing a software trick, with no historical
   software, destroying the timing proof.

Snow and beam-hack capability are the same circuit property (CPU wins the VRAM
arbitration; video reads get blanked) — implement the arbitration correctly and both
follow.

## 4. Floppy findings

The load-bearing facts (1771-vs-179x data address marks, "all doublers kept the 1771",
the two incompatible density-switch protocols, per-track mixed density on real NEWDOS/80
disks, DMK vs. JV1) are specified in [SPEC.md §4](SPEC.md) — primary sources: Tim Mann's
format documentation and FAQ, both EI service manuals, xtrs source.

## 5. Corrections log (spec errors found and fixed)

Kept deliberately public — this is the quality bar working as intended:

- big80 was initially recorded as *unlicensed* because only a `LICENSE` file was searched
  for; the Apache-2.0 grant lived in the README. Rule since: search the whole README.
- An earlier spec draft attributed George Phillips' 128×192 to the Model 1 (see §3.2) — corrected.

