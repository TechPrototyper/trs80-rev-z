# interposer/ — Model 1 bus interposer (ADR-0009 Phase 0)

Build plan: [docs/INTERPOSER-PLAN.md](../../../docs/INTERPOSER-PLAN.md).

- `pinmap.csv` — 40-pin edge ↔ shifter bank ↔ FPGA port ↔ ULX3S GP/GN ↔ site
- `interposer.lpf` — draft LOCATE/IOBUF fragment for the `m1x_*` ports
- `kicad/` — (not yet) schematic and board; the BOM and bank table in the plan
  are the schematic in words until then.

Nothing here is wired into the build yet; `ulx3s_v20.lpf` does not include
this fragment until a top level exposes the ports.
