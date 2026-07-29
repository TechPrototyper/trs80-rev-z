# ADR-0001 — Ripple counters become synchronous enables; phases become explicit

**Status:** accepted · 2026-07-18

## Context

The Model 1's timing is built from 74LS9x ripple counters with asynchronous
terminal-count clears (Z66) and from two independent ÷6 dividers off one crystal (Z56
for the CPU, Z58 for the character rate). Literal RTL mimicry — derived clocks, ripple
cascades, async clears — is hostile to FPGA timing analysis and to the target
platform (ECP5).

## Decision

1. **One clock domain** (the 10.6445 MHz dot clock); every slower rate is a one-cycle
   *enable* (`cpu_cen`, `chain_en`, `latch_n`).
2. Ripple cascades are re-expressed as a single synchronous cascade that advances on
   the same tick the hardware's ripple would settle on. The observable contract —
   count sequences, tap values, period lengths, blanking windows — is cycle-identical;
   the sub-nanosecond ripple *skew* of the original is not modeled.
3. The transient terminal states that the async clears blank out in nanoseconds (Z50's
   "14", Z32's "11", Z12's "12") **never appear at all** in the model. The manual
   itself treats them as invisible ("about 50 nanoseconds… we can ignore it").
4. **Phases that hardware leaves to chance become explicit parameters.** On real
   hardware the CPU-vs-video phase (Z56 vs. Z58, six possibilities) is set by whenever
   the counters left reset. In RTL both reset together, which silently picks one
   phase. Once snow modeling makes this observable, the phase becomes a documented,
   configurable parameter rather than an accident.

## Consequences

- RTL synthesizes cleanly on target platform; simulation and hardware behave
  identically at the contract level.
- Anything verified against golden models compares *states per dot tick*, which is
  exactly what the enable scheme exposes.
- Deviation from literal schematic structure is documented per module in the header;
  the schematic remains the authority for *behavior*, not for *style*.
