# RTL

Verilog, one module per board subsystem, mirroring the Tandy schematic structure
(clock generation, video timing chain, VRAM arbitration, address decode, keyboard,
cassette, expansion interface, FDC …). Each module comes with a testbench in `sim/`
and a documentation chapter walking through the schematic and the waveforms.

Provenance rule: files informed by third-party code carry a header naming the source
and the license/permission it is used under (see CREDITS.md).

`vendor/` holds unmodified third-party cores under their own license, each in its own
directory with a provenance README and, if needed, a scoped Verilator lint-waiver file.
Currently: `vendor/tv80/` — the Z80 core ([ADR-0003](../docs/decisions/0003-z80-core-selection.md)),
wrapped by `m1_cpu.v`. First-party RTL stays fully `-Wall` clean; waivers never widen
past the vendored files.
