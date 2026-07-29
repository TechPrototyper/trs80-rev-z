# Credits

This project stands on the shoulders of giants! Their prior work was used either under its 
license or with the author's explicit permission. Per-file provenance is additionally recorded in source headers.

## Code lineage

- **Mark McDougall** — *PACE* (TRS-80 Model 1 platform: PCG-80, address decode,
  flux-level WD179x approach). Used as a basis with his explicit permission, released
  here under MIT with credit — thank you, Mark.
- **Brad Robinson** — *big80* and its accompanying article series. Dual-licensed
  Apache-2.0/MIT by Brad on request (2026-07-17). The articles are cited throughout the
  documentation regardless of code lineage.
- **Guy Hutchison** — *tv80*, an MIT-licensed Verilog port of Daniel Wallner's
  T80. Vendored unmodified as the CPU core under `rtl/vendor/tv80/` — see
  [ADR-0003](docs/decisions/0003-z80-core-selection.md).
- **Daniel Wallner** — *T80* Z80 core (BSD-style); reaches this project through
  tv80 (above), the Verilog port of his design.
- **Lawrie Griffiths** — *ulx3s_trs_80 / ulx3s_z80_trs80*, the proof that a TRS-80 on
  the ULX3S with the open toolchain works at all. (License inquiry pending; no code
  derived unless/until granted.)
- **RetroStack** — *TRS-80-Model-I-G-E1* (MIT), KiCad recreation of the Rev G board,
  used as machine-readable schematic cross-check.
- **Tim Mann** — *xtrs* (MIT): the character generator bitmap data (`trs_chars.c`,
  set CG 1) is the source of `rtl/mcm6670_cg1.hex` — see
  [ADR-0002](docs/decisions/0002-character-generator-font-data.md).

## Knowledge lineage

**George Phillips** (trs80gp, 48k.ca timing documentation) · **Tim Mann** (disk formats,
DAM analysis, xtrs) · **Ira Goldklang** (trs-80.com archive) · **Matthew Reed**
(trs-80.org histories) · **RedskullDC** (Omikron mapper archive) · 
**Goran Mahovlić / Radiona** (the ULX3S board and its ecosystem) — see [docs/RESOURCES.md](docs/RESOURCES.md).

## Media credits

- **Thomas Gutmeier** ([8bit-Homecomputermuseum](http://www.8bit-homecomputermuseum.at/computer/tandy_trs80_model1.html), Wien) — photograph of the TRS-80 Model I system (`assets/trs80_model1.jpeg`). Many thanks to Thomas for his excellent online collection and for sharing this photograph. Thomas' photo actually looks almost identical to my own machine in
the days, which was sold, unfortunately, because we still had and kept the Model III, which btw still exists but needs repairing.

The golden-model verification methodology (byte-exact VRAM comparison, simulation before
silicon) was developed in a predecessor Space Invaders project against trs80gp.
