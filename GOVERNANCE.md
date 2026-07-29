# Some notes on maintaining this

These are the rules I've set for myself as much as for anyone else:

1. **The specification is the anchor.** [docs/SPEC.md](docs/SPEC.md) defines what is
   being built. When code and spec disagree, one of them is wrong, and that gets sorted
   out explicitly — never by quiet accumulation.
2. **Decisions get written down with their reasons.** In the spec or in
   [docs/decisions/](docs/decisions/). If you wonder *why* something is the way it is,
   the answer should be a link — and if the reasoning doesn't survive your reading,
   that's worth an issue.
3. **Evidence beats my opinion. Every time.** Corrections backed by schematics, service
   manuals, measurements, or golden-model traces win. The spec has been wrong before —
   there's a public corrections log in [docs/RESEARCH.md](docs/RESEARCH.md), kept
   deliberately, because being correctable *with sources* is the quality bar I'm aiming
   for. What I ask is only that changes come with evidence, because I often can't judge
   authority by ear yet — sources level the field for everyone, including myself, of course.
4. **Direction questions vs. direction changes.** "Why did you choose X?" is always
   welcome. "This should really be Y instead" may well be right — but if Y is a
   different machine than the one specified, this repository isn't the place to build
   it, and that's exactly what the MIT license is for: take everything, build Y, and
   I'll happily link to it and perhaps celebrate it!
5. **The Goldstandard is inviolable** (a technical rule, not a social one): every
   extension (Rev-Z switch) must, when disabled, yield bit-exact stock Rev G behavior.
   An extension that can't do that isn't a switch but a different machine — see rule 4.

## What "in scope" means

- **Committed tier** (M1–M3, specified): contributions of any kind welcome, from typo
  to verified RTL. In the meantime, most of this has been built, tested and enjoyed on real silicon.
  However, this doesn't mean the system is done. If you find optimizations or even errors which
  just haven't shown up as of now, please let me know and let us correct and optimize!
- **Vision tier** (M4+): direction statements, deliberately under-specified. Discussion
  and research very welcome; implementation PRs only after the relevant part is
  specified.
- **Out of scope**: other target machines (Model 3/4 as such, clones), other FPGA boards
  as primary targets, features that break rule 5. Portability is kept cheap by design
  discipline, but this repo targets the ULX3S-85F.

## Changing the specification

The way it was written: with evidence. State what's wrong or missing, cite sources,
open an issue before code moves. I expect — and hope — that people who owned, repaired,
or designed for this hardware will find things I got wrong. As I've stated earlier, this
is primarily for me to learn about microelectronics, open source hardware and assembly
language programming.
