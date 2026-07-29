# Vendored: tv80 Z80 core

- **Upstream:** https://github.com/hutch31/tv80
- **Commit:** `66a131c38d05ef58b3d8c4f1507a72e6e4aa5d65` (2026-05-11)
- **Files:** `tv80_core.v`, `tv80_alu.v`, `tv80_mcode.v`, `tv80_reg.v` — unmodified.
  The upstream `tv80s` wrapper is intentionally *not* vendored; `rtl/m1_cpu.v`
  wraps `tv80_core` with a clock enable instead (ADR-0003).
- **License:** MIT (see `LICENSE` in this directory). Copyright (c) 2004
  Guy Hutchison; based on the VHDL T80 core by Daniel Wallner.
- **Build note:** compile with `+define+TV80_REFRESH` so the R register counts
  and refresh M1 cycles assert ~MREQ (RAS-only refresh, Manual p. 295).
- **Lint:** covered by `tv80.vlt`, the scoped waiver file documented in
  ADR-0003. Do not widen its scope.

Selection rationale, alternatives, and the cycle-accuracy caveat live in
[ADR-0003](../../../docs/decisions/0003-z80-core-selection.md).
