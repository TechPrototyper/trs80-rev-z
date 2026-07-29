# ADR-0002 — Character generator font data: in the repo, unlike ROMs

**Status:** accepted · 2026-07-19

## Context

The Model 1's character generator Z29 is a mask-programmed Motorola MCM6670P
(Tandy part 8046670 in the service data; catalog 3108001 in the 1978 Technical
Manual parts list): 64 usable glyphs of 5×7 dots, addressed by 7-bit ASCII plus a
3-bit row select. Rendering anything requires its bit patterns — but this repository
has a hard rule: **no ROMs, ever** (`roms/README.md`).

That rule exists for *software*: Level II BASIC is a copyrighted literary work
(Tandy/Microsoft). The chargen mask is a different kind of object — a bitmap
typeface of a standard character set.

## Decision

Font bitmap data **is committed** to the repository (`rtl/mcm6670_cg1.hex`), and the
no-ROMs rule is explicitly scoped to *software/firmware images*. Two independent
justifications, either of which suffices:

1. **License.** The data is taken from `trs_chars.c` of Tim Mann's *xtrs* (MIT
   license), character set "CG 1" — the standard Model I set. Provenance is
   documented in-file by Mann himself: transcribed from the Motorola MCM6674
   datasheet, with the four arrow glyphs (`0x5B–0x5E`, where ASCII has `[ \ ] ^`)
   reconstructed by him from memory. The sibling set in the same file was checked
   against a real Model I by Ulrich Müller, which validates the layout conventions
   (glyph rows 1–7 of the 12-line cell; one blank line above, four below).
2. **Copyright status of typefaces.** Under US law, typefaces as such are not
   copyrightable (37 C.F.R. § 202.1(e); *Eltra Corp. v. Ringer*, 579 F.2d 294
   (4th Cir. 1978)), and the Copyright Office's 1988 Policy Decision on Digitized
   Typefaces held bitmap fonts to contain no registrable authorship. A 5×7 dot
   rendering of ASCII is about as clearly unprotectable as font data gets.
   (German law protects typefaces via the design-law route with its own limits;
   for a 1970s catalog part this changes nothing practical.)

Regeneration is reproducible: `sim/tools/xtrs_font_to_hex.py` rebuilds the hex from
an xtrs checkout; the source file itself is *not* mirrored here.

## Consequences

- The video path renders real Model 1 glyphs in simulation from day one; frame-level
  verification against golden models becomes possible without any user-supplied file.
- `roms/README.md` keeps its absolute tone for software images; this ADR is the single
  documented carve-out, so the boundary stays sharp instead of eroding case by case.
- The four arrow glyphs carry a "reconstructed from memory" caveat. If mask-exact
  arrows ever matter (they would only show in pixel-perfect screenshot comparison),
  verify against a photographed die/screen or a hardware dump — tracked as an open
  item in chapter 2.
- Credit to Tim Mann moves from knowledge lineage to code lineage in CREDITS.md.
