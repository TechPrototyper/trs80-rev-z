# ADR-0011 — tv80 runs on a glitch-free gated clock instead of clk + cen

**Status:** accepted · 2026-08-27

## Context

ADR-0001 mandates a single clock domain: everything runs on the 10.6445 MHz
dot clock, slower rates are one-cycle enables. The Z80 core (tv80) therefore
received `clk` plus the 1.77408 MHz `cpu_cen` enable.

Profiling the Verilator emulator (gprof, 8-core cloud VM) showed ~60 % of all
wall-clock time inside the CPU-domain evaluation cone: Verilator statically
schedules tv80's sequential blocks *and the inlined decoder/ALU combinational
cone* on `posedge clk`, so the whole Z80 is re-evaluated at dot rate even
though its state can only change on the 1-of-6 enabled edges. On cloud vCPUs
(EPYC 7763 / Xeon 8370C) the emulator reached only 0.16–0.18× realtime.

## Decision

`m1_cpu` drives tv80 from a glitch-free gated clock instead:

```verilog
reg cen_lat;
always @(negedge clk) cen_lat <= cpu_cen;          // race-free capture
wire cpu_gclk = clk & (cen_lat | ~cpu_rst_n);      // open during reset
tv80_core ... (.clk(cpu_gclk), .cen(1'b1), ...);
```

- The negedge capture is the textbook enable gate: `cpu_gclk` rises exactly on
  the dot-clock edges where tv80's `if (cen)` used to fire — same edges, same
  sampled values.
- During reset the gate is forced open so tv80's reset branches see clock
  edges, exactly as with a free-running `clk`. (The first cut omitted this;
  tv80 then woke up un-reset in an illegal all-zero one-hot state and the
  `sim/` suite caught it — tb_m1_ram48 watchdog.)
- Everything else stays in the single `clk` domain; `cpu_cen` continues to
  gate the m1_cpu strobe reconstruction unchanged.

## Consequences

- Verilator binds the entire tv80 cone to the 1.77 MHz trigger: emulator
  throughput on cloud vCPUs +39 % (0.18× → 0.25×; with PGO 0.30×). On Apple
  Silicon the gate is performance-neutral (0.76× → 0.75×; the M-series cores
  absorbed the redundant re-evaluation in cache/branch-prediction), PGO lifts
  it to 0.95× realtime.
- Synthesis: a standard clock-enable gate; FPGA tooling may or may not map it
  to a BUFGCE-style primitive. If a target flow prefers the enable idiom, the
  gate is a two-line local change in `m1_cpu`.
- ADR-0001 stays authoritative for all first-party RTL; this ADR carves out
  the vendored CPU core only.

## Evidence

- Full `sim/` suite passes under Verilator 5.041 (macOS) and 5.051 (linux),
  before and after.
- Instruction-fetch PC trace (`--pctrace`), 808 934 fetches from cold boot:
  bit-identical between the clk+cen build and the gated build.
- gprof profiles before/after are archived in the PR discussion.
