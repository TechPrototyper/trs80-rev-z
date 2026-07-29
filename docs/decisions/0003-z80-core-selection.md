# ADR-0003 — Z80 core: tv80 (vendored), wrapped behind our own bus layer

**Status:** accepted · 2026-07-19

## Context

Chapter 5 connects a CPU to the verified timing/VRAM/decoder chain. Writing a Z80
core is out of scope for Sprint 1; the golden-model milestone (SPEC §6) needs a
working, trustworthy CPU now. The pinned criteria:

1. **Verilator 5 suitability.** The entire verification methodology is
   simulation-first on Verilator (`-Wall`); a core the simulator cannot ingest
   would break the method, not just the build.
2. **Cycle accuracy sufficient for golden-model comparison.** SPEC §6 demands
   byte-exact VRAM comparison against trs80gp *and* T-state-plausible bus
   behavior: 1 T-state = 6 dots, and the streak artifact depends on *when*
   memory strobes hit the video RAM — i.e. M-cycle/T-state placement of bus
   activity matters, gate-level fidelity does not.
3. **License.** MIT-compatible with clean provenance (CREDITS.md discipline).
   Standing constraints: no Griffiths-derived code until his license reply
   arrives; PACE only with credit (granted 2026-07-17); big80 is MIT.

### Candidates

| Core | Language / license | Verdict against the criteria |
|---|---|---|
| **T80** (Daniel Wallner) | VHDL, BSD-style | The proven lineage — PACE, big80 and the MiSTer core all use it. But Verilator does not simulate VHDL; adopting it would force a GHDL mixed-language flow and abandon the single-simulator `-Wall` regime. Fails criterion 1. |
| **tv80** (Guy Hutchison) | Verilog, MIT | Direct port of T80 — same microcode structure, so the T80 field history largely transfers. Upstream (`github.com/hutch31/tv80`) is alive (last merge 2026-05) and its own regression suite runs on **Cocotb + Verilator**, i.e. the core is maintained against exactly our simulator. `tv80_core` has a clock-enable input (`cen`), which drops straight into our single-clock-domain/enable regime (ADR-0001). `Mode = 0` gives standard Z80 M-cycle/T-state timing. Lawrie Griffiths' ULX3S TRS-80 ports run tv80 on our exact board with the open toolchain — evidence of viability; **no code is taken from his repos**, tv80 comes from upstream under its own MIT license. |
| **A-Z80** (Goran Devic) | Verilog/SV, **GPL-2.0** | Conceptually attractive (derived from Z80 die studies), but GPL-2.0 is incompatible with releasing this repository under MIT. Reference only. Fails criterion 3. |
| Own core | — | Wrong sprint. The wrapper interface below is the standard Z80 bus, so this option stays open without rework elsewhere. |

## Decision

**tv80** is vendored from upstream `hutch31/tv80`, pinned at commit
`66a131c38d05ef58b3d8c4f1507a72e6e4aa5d65` (2026-05-11), files
`tv80_core.v`, `tv80_alu.v`, `tv80_mcode.v`, `tv80_reg.v`, unmodified, into
`rtl/vendor/tv80/` together with the upstream license text and a provenance
README. The stock `tv80s` wrapper is **not** used (it hard-wires `cen = 1`);
instead our own wrapper instantiates `tv80_core` with `cen` driven by the
1.77408 MHz enable from `m1_cpu_clock`, `Mode = 0`, `IOWait = 1`, and derives
the Model-1 strobe layer (RAS\*, RD\*, WR\*, IN\*, OUT\*, Z53 bus direction,
TEST\*) from the schematic — that wrapper is ours, chapter-documented, and
`-Wall` clean.

### Lint carve-out (second documented exception, mirroring ADR-0002)

tv80 is written in a pre-lint Verilog style; under Verilator 5 `-Wall` it emits
~990 warnings, 962 of which are `BLKSEQ` (blocking assignments in sequential
blocks — a whole-core rewrite to "fix"). The house rule "waivers only in
testbenches" gains one scoped exception: `rtl/vendor/` carries a waiver file
(`rtl/vendor/tv80/tv80.vlt`) that silences named warning categories **for the
vendored files only**. Our own RTL stays fully `-Wall` clean; the boundary
stays sharp: waivers live where foreign code lives, nowhere else.

## Consequences

- CREDITS.md: Guy Hutchison moves into code lineage; Daniel Wallner's existing
  entry is updated (his T80 lineage reaches us through tv80).
- Cycle-accuracy caveat, stated honestly: tv80 (like T80) reproduces documented
  instruction timing, not gate-level Z80 behavior. Undocumented-flag and
  interrupt corner cases have historically carried bugs in this family. The
  golden-model comparison is exactly the instrument that will surface any such
  deviation as a byte diff; the fallback ladder is (a) patch with a regression
  test, (b) swap the core behind the unchanged wrapper.
- If this ADR is vetoed, the wrapper interface (standard Z80 bus + `cen`)
  is the contract any replacement must meet; nothing outside `rtl/vendor/`
  and the wrapper's instantiation would change.
