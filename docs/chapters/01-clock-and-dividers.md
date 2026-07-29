# Chapter 1 — The Clock and the Divider Chain

*Sources: TRS-80 Technical Manual (Theory/Parts/Schematics, 1978), "System Clock",
"CPU Timing", "Video Divider Chain" (pp. 5, 13–16) and Schematic Sheets 1–2;
cross-checked against RetroStack's Rev G KiCad recreation (`Clock.kicad_sch`,
`VideoCounter.kicad_sch`). RTL: [`rtl/m1_cpu_clock.v`](../../rtl/m1_cpu_clock.v),
[`rtl/m1_video_timing.v`](../../rtl/m1_video_timing.v); testbench:
[`sim/tb_m1_timing.sv`](../../sim/tb_m1_timing.sv).*

Everything in the Model 1 beats to one crystal. This chapter covers the whole pulse
chain: from 10.6445 MHz down to the 60 Hz of the vertical sync — and, as a side effect,
derives *why* a line has 112 character times and a frame 264 lines, numbers that
otherwise look arbitrary.

## 1. The oscillator (Y1, Z42)

Y1 is a **10.6445 MHz** fundamental-cut crystal in a series-resonant loop with two
74LS04 inverters (Z42), biased into their linear region by 910 Ω resistors, feedback
through 47 pF (C43). A third inverter buffers the output. That buffered square wave —
the **master clock / dot clock** — feeds three consumers: the CPU clock divider, the
video divider chain, and the video processing (shift register) logic.

One frequency, one source of truth. Every other rate in the machine is an integer
division of it:

```
10.6445 MHz  master / dot clock
    ÷6   →  1.77408 MHz  CPU clock (Z56)          ← "1 T-state = 6 dots"
    ÷6   →  1.77408 MHz  character rate (Z58)      ← one character = 6 dots wide
    ÷12  →  887.0416 kHz "CHAIN"                   ← the divider chain's heartbeat
```

## 2. The CPU clock (Z56, Sheet 1)

A 74LS92 whose ÷6 section divides the master clock; the result (~1.774 MHz) is
buffered (Z72, pulled up by R64 for fast edges) into the Z80's clock pin. The
consequence: **the CPU clock is not tapped off the video chain** — it is a *separate*
divider running from the same crystal. CPU and video therefore always run at exactly
the same rate, but their relative phase is whatever it happened to be when the counters
came out of reset.

> **Modeling note (see ADR-0001):** in RTL both dividers reset together, so the
> CPU/video phase is deterministic — real hardware picks one of six possible phases at
> power-up. Once we model snow (which lives exactly at this boundary), this becomes a
> preservation-relevant parameter: we make the phase explicit and configurable instead
> of accidental.

## 3. Input conditioning: two screen formats (Z70, Z43, Z58, Z24)

The Model 1 has a 64-characters-per-line format and a doubled-width 32-character
format (`MODESEL`). The trick is entirely in the clocking:

- **Z70** (74LS74) divides the master clock by 2.
- **Z43** (74LS157 mux), steered by `MODESEL`, feeds **Z58** either the full master
  clock (64-char mode) or the halved clock (32-char mode).
- **Z58** (74LS92) divides by 12. Its outputs DOT1/DOT2 are NANDed by **Z24** into
  **LATCH\*** — the pulse that grabs the next character from video RAM: one dot wide
  every 6 dots in 64-char mode, two dots wide every 12 in 32-char mode.
- The chain output ("CHAIN", **887.0416 kHz in both modes**: ÷12 of the full clock, or
  ÷6 of the half clock) drives everything downstream — which is why switching formats
  changes character width but *not* line frequency or frame rate.
- **C1**, the least-significant video RAM column address bit, also comes from this
  conditioning block: in 64-char mode it toggles once per character; in 32-char mode it
  is held low, which is precisely why only 512 of the 1024 screen locations are used.

## 4. The divider chain proper (Z65, Z50, Z12, Z32 — with Z66 doing the resets)

Four 4-bit ripple counters, each cut short of 16 by an AND gate (Z66) that detects the
terminal count and clears the chip. The chain, with the numbers from the manual:

```
CHAIN 887.0416 kHz
  → Z65a  ÷4    221.760 kHz   taps C2, C4
  → Z50   ÷14    15.840 kHz   taps C8, C16, C32 · QD = HDRV
  → Z12   ÷12     1.320 kHz   taps L1, L2, L4, L8   (12 scan lines per row)
  → Z65b  ÷2      660.0 Hz    tap  R1
  → Z32   ÷11      60.00 Hz   taps R2, R4, R8 · QD = VDRV
```

Two derivations worth savoring:

**Why 112 character times per line.** One CHAIN period is two characters. The
horizontal counters divide CHAIN by 4 × 14 = 56, so a line is 56 × 2 = **112
characters = 672 dots**. At 1 T-state = 6 dots that is the famous **112 T-states per
line** from George Phillips' beam-hack timing notes — here it falls out of two
counter-clear values.

**Why 264 lines per frame — and where the 72 blank lines live.** Vertically:
12 scan lines × (2 × 11) rows = 12 × 22 = **264 lines**. Rows 0–15 are the visible
16 character lines; rows 16–21 are six full character rows of blanking — 6 × 12 =
**72 blank scan lines**, exactly the "nothing is ever written within these 72 lines"
of the manual. Frame rate: 10.6445 MHz / (672 × 264) = **60.0001 Hz**.

**The elegant part.** The sync taps sit on the counters' top bits: HDRV is Z50's QD — high exactly
when the character count is 64–111, i.e. during the 48 invisible character times of
every line. VDRV is Z32's QD — high exactly during rows 16–21, the blank band. The
horizontal and vertical blanking windows aren't computed by extra logic; **they are
the top bits of the position counters.** (The actual sync *pulses* are shaped from
HDRV/VDRV by the VideoSync section — RC networks and trimmers on the original board;
that's a later chapter, and on HDMI we regenerate sync from the same counters anyway.)

## 5. The signal contract (what the RTL exports)

| Signal | Meaning | Hardware origin |
|---|---|---|
| `clk` | dot clock, 10.6445 MHz | Y1/Z42 (on ULX3S: PLL from 25 MHz) |
| `cpu_cen` | 1-dot enable at 1.77408 MHz | Z56 ÷6 |
| `latch_n` | character latch, low-active | Z58 DOT1·DOT2 via Z24 |
| `chain_en` | 1-dot enable at 887.0416 kHz | Z58 chain output, falling edge |
| `col[6:0]` | character column 0–111 (address taps = `col[5:0]` = C1…C32) | conditioning + Z65a + Z50 |
| `line[3:0]` | scan line within row, 0–11 (L1…L8) | Z12 |
| `row[4:0]` | character row 0–21 (address taps = `row[3:0]` = R1…R8) | Z65b + Z32 |
| `hdrv` | high during columns 64–111 | Z50 QD |
| `vdrv` | high during rows 16–21 | Z32 QD |
| `modesel` | 1 = 64-char, 0 = 32-char | latched CPU write (later chapter) |

## 6. What the testbench proves (and how to watch it)

`sim/tb_m1_timing.sv` runs both modes and asserts: LATCH\* spacing (6/12 dots), CHAIN
at 887.0416 kHz, line length 672 dots, HDRV duty 288/672, frame length 177 408 dots,
VDRV duty 48 384/177 408, CPU enable every 6 dots, C1 pinned low in 32-char mode, and
counter wrap sequences. It writes `sim/build/tb_m1_timing.vcd`.

To *see* the pulse: `cd sim && make wave`, then add `clk`, `cpu_cen`, `latch_n`,
`chain_en`, `col`, `hdrv` and zoom to ~2 µs — the whole ÷6/÷12 hierarchy is visible in
one screen. Then zoom out to ~70 µs for one full line (watch `hdrv` cover exactly the
last 48 columns), and to ~35 ms for two frames of `vdrv`.

## 7. Open items

- [x] ~~Exact DOT1/DOT2 tap polarity and the sub-character phase of LATCH\*~~ —
      resolved via `VideoCounter.kicad_sch`: **LATCH\* = NAND(Z58 QA, Z58 QC)**
      ("BIT 1" · "BIT 3", note *"Every 6th count"*). QA is the ÷2 prescaler, QC the
      ÷6 tap; both are high together exactly in the **last dot of each 6-dot cell**,
      and the chain boundary (QD falling edge; in 32-char mode Z43 taps QC instead —
      "÷12 of the full clock or ÷6 of the half clock") coincides with the end of the
      second latch pulse. The RTL's placement (`phase == 5 | 11`) is hardware-exact.
      Chapter 2 §7 shows what the phase does to the pixel pipeline.
- [x] ~~`MODESEL` write path (port `$FF` latch)~~ — done in
      [chapter 6](06-io-ports.md): `m1_io` latches D3 (MODESEL = ~D3) and drives it
      into this module; the CPU switching modes is verified byte-exact against
      trs80gp (`make golden`).
- [ ] VideoSync pulse shaping parameters — irrelevant for HDMI, documented for
      completeness when we do composite output (if ever).
