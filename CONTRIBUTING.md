# Contributing

[GOVERNANCE.md](GOVERNANCE.md) explains what kind of project this is. Short version:
one maintainer, a fixed specification, evidence-driven changes, fork-friendly.
Corrections from people who know this machine are the whole point — I'm genuinely glad
about anyone who spends time here.

## Contributions I'll always be grateful for

- **Corrections with sources.** Schematic readings, ROM version details, timing
  measurements from real hardware, service-manual citations. The research is published
  precisely so you can shoot holes in it — please do.
- **Test cases and golden-model traces.** Software known to exercise edge cases
  (snow-sensitive programs, beam-synced code, mixed-density disks, copy-protection
  schemes), trs80gp/MAME reference dumps, real-hardware captures.
- **Review.** Reading RTL against the Tandy schematics and saying "that's not what the
  board does" is the most valuable thing anyone can do here — and the thing I'm least
  able to do for myself yet.
- **Experience.** You owned, repaired, or expanded a real Model 1 and remember something
  the manuals don't say? That's preservation. Open an issue, even if it's vague.

## Where I'd ask you to open an issue first

- **RTL for the committed tier** — reference the spec section you're implementing, so
  effort doesn't get duplicated or misdirected.
- **Vision-tier research** (Omikron mapper, expansion-bus history, TRS-IO integration…).
  Very welcome; some of it is already underway, so please open an issue first and
  we can coordinate.
- **New build targets to maintain.** The TRS-80 Model 1 is a fine machine, and it
  deserves more targets than the fanstastic ULX3S. I already have a couple of them
  in my mind, to be honest, so let's discuss and bring this machine whereever it fits!
  

## What I'll have to decline

- **Scope extensions and redirections** ("make it a Model 4", "add X to the committed
  tier"). Not because the ideas are bad — often they won't be — but because that's a 
  different project. Please bring them to the **"What belongs in Rev Z?"** discussion
  (genuinely read and considered), or fork with my blessing.
- **ROM images or copyrighted documentation** in PRs. These I have to close immediately —
  it's a legal line, not a preference. See [roms/README.md](roms/README.md).

## Practicalities

- One logical change per PR, referencing an issue.
- RTL changes come with a testbench and, where observable behavior changes, a
  golden-model comparison. "It synthesizes" isn't verification.
- Code style: match the surrounding code; comments state constraints the code can't
  express.
- Provenance: if your contribution is informed by someone else's code, please say so in
  the PR. This project tracks per-file provenance ([CREDITS.md](CREDITS.md)) — it's the
  one area where surprises could really hurt.
- By contributing you agree your contribution is licensed under the project's MIT
  license.
