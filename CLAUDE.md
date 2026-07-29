# Working notes for AI-assisted sessions in this repository

This project is built with heavy AI assistance (Claude Code), openly. These are the
standing rules for any such session — they mirror GOVERNANCE.md and SPEC.md, which
always win on conflict.

## Ground rules

- **docs/SPEC.md is normative.** Code contradicting it is a bug in one of the two;
  resolve explicitly, cite sources. Substantial decisions get an entry in
  `docs/decisions/` (ADR style, numbered).
- **Evidence discipline:** claims about the historical machine cite the Tandy manuals,
  the RetroStack KiCad recreation, golden models (trs80gp/MAME), or measurements.
  Unverified statements are marked as such. Corrections go to the log in
  docs/RESEARCH.md §5.
- **Verification before checkmarks:** ROADMAP boxes are ticked only when behavior is
  verified (simulation against documented numbers or golden models). "It synthesizes"
  is not verification.
- **No ROMs, no copyrighted docs in the repo — ever** (see roms/README.md). PRs
  containing them are closed.
- **Provenance:** files informed by third-party code carry a header naming source and
  license/permission; CREDITS.md is kept current.

## Code style

- Verilog (RTL) targeting yosys; single clock domain (10.6445 MHz dot clock), slower
  rates as one-cycle enables — see ADR-0001. Full `-Wall` clean under Verilator;
  lint waivers only in testbenches, justified inline.
- Module headers state which schematic parts (Z-numbers, sheet) are modeled and where
  the model deliberately deviates in structure.
- Each RTL module ships with a testbench in `sim/` and a documentation chapter in
  `docs/chapters/` (schematic walkthrough → signal contract → waveform guide).

## Build & test

```
cd sim && make        # build + run all checks (Verilator)
cd sim && make wave   # open the VCD in gtkwave
```

Toolchain: oss-cad-suite (verilator, yosys, nextpnr-ecp5, gtkwave) in /opt/oss-cad-suite.

## Context

Maintainer planning and research notes live outside this repository. The reference
ROM identification and local document archives are described in docs/RESOURCES.md.
