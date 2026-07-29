# The chapters — one per RTL module

Each chapter is self-contained and tied to one RTL module: schematic walkthrough
(IC by IC, against the 1978 Tandy manual), the signal contract the RTL exports, what
the testbench *proves*, and a waveform guide for watching it happen in GTKWave. They
don't expire — `cd sim && make` regenerates every trace and frame at any time, long
after the code moved on. Every claim in them is re-checkable on your machine; if a
run disagrees with a chapter, that's a bug worth reporting.

| # | Chapter | One thing it proves | Watch it |
|---|---|---|---|
| 1 | [The Clock and the Divider Chain](01-clock-and-dividers.md) | Why a line is 112 character times and a frame 264 lines — and that HDRV/VDRV are just the top counter bits | `make wave` |
| 2 | [From RAM Byte to Dot Stream](02-character-generation.md) | Seven RAMs + one NOR gate = eight bits; pixels lag the counter by exactly two characters; the character gap is a grounded pin | `make wave-gen`, `make frames` |
| 3 | [The Video RAM and the Arbitration That Isn't One](03-vram-and-arbitration.md) | The CPU just takes the RAM (no WAIT — one resistor is the whole protocol); streaks are subtractive, blanking-timed access is free: snow and beam hacks are one property | `make wave-vram`, `make frames` |
| 4 | [The Address Decoder: Six Bits Rule the Map](04-address-decoder.md) | One open-collector decoder + a DIP shunt you program with wire cutters; open bus at 0x3000, four keyboard mirrors, and MEM\* only exists for reads | `make` prints the anchor table |
| 5 | [The Z80 Joins the Chain](05-z80-integration.md) | A real (vendored) Z80 fetches from ROM and pokes the screen; ~MREQ *is* RAS\*, DBIN\*/DBOUT\* are complementary, `HALT` trampolines through NMI — and VRAM matches trs80gp byte-exact (`make golden`) | `make wave-cpu`, `make golden` |
| 6 | [One Port to Rule Them All: 0xFF](06-io-ports.md) | The machine's single I/O port carries cassette + the 64/32 mode bit; MODESEL = ~D3, IN 0xFF reads mode back on D6 — CPU mode-switch verified byte-exact vs trs80gp | `make wave-io`, `make golden` |
| 7 | [The Keyboard That Thinks It's Memory](07-keyboard.md) | 53 switches read as memory: address bits drive rows, data bits sense columns, multi-row reads OR — SPACE and 'A' read through the matrix, byte-exact vs trs80gp `-ik` | `make wave-kbd`, `make golden` |
| 8 | [The Machine, Composed](08-integration.md) | All seven blocks wired into one synthesizable `m1_core` (bus mux, external surface); same golden test, and it synthesizes clean for the ECP5 | `make synth`, `make golden` |

The story has since moved past chapter 8: the board top-level (ULX3S — PLL,
DVI, USB-HID, SD-card ROM loader) and the Expansion Interface (48K RAM,
WD1771/1791 FDC with mixed-density DMK, up to a TRSDOS boot on real
hardware) exist and carry the same proof discipline — testbenches under
`sim/` and `boards/ulx3s/sim/`, byte-exact goldens per stage (`make
golden-ram`, `-ei`, `-fdc*`, `-boot`). Their chapters are not written yet;
until they are, the commit messages and [ROADMAP.md](../../ROADMAP.md) are
the narrative, and the benches are the truth.
