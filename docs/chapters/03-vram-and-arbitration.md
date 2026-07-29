# Chapter 3 — The Video RAM and the Arbitration That Isn't One

*Sources: TRS-80 Technical Manual (Theory/Parts/Schematics, 1978), "Video RAM
Addressing", "Video RAMs", "Data Latch", "Video Display RAM Select", "WAIT, INT\*,
TEST" (pp. 6, 16–17, 20) and Schematic Sheets 1–2; cross-checked pin by pin against
RetroStack's Rev G KiCad recreation (`VideoAccessMultiplexer.kicad_sch`,
`VideoRAM.kicad_sch`). RTL: [`rtl/m1_vram.v`](../../rtl/m1_vram.v); testbench:
[`sim/tb_m1_vram.sv`](../../sim/tb_m1_vram.sv).*

Chapter 1 built the beam, chapter 2 turned bytes into light. This chapter supplies
the bytes — and settles the question every shared-memory design must answer: CPU and
display contending for the same RAM. The Model 1's
answer is magnificently blunt: **the CPU simply takes it.** No wait states, no
handshake, no dual porting. Three multiplexers and one pull-up resistor are the
entire "arbitration", and the famous flickering black streaks of a Model 1 hard at
work are the visible cost of that decision. This is also the chapter where the
Rev-Z switch **Z1** from [SPEC §4](../SPEC.md) gets its circuit: snow/streak
behavior and beam-hack capability are one and the same property, seen from two
sides.

## 1. Three multiplexers, ten address lines (Z64, Z49, Z31)

The video RAM has one address port and two masters. Three 74LS157s — quad 2:1
multiplexers — sit in front of it, all twelve sections switched by a single select
signal: **VID\***, the address decoder's "the CPU is addressing 0x3C00–0x3FFF" line
(the decoder itself is chapter 4's subject; here it arrives as the `vid_n` input).

| VRAM address | VID\* high (chain) | VID\* low (CPU) | mux |
|---|---|---|---|
| VA0–VA5 | C1…C32 — the character column | A0–A5 | Z64, Z49a/c |
| VA6–VA9 | R1…R8 — the character row | A6–A9 | Z31 |

The video side is simply the counter chain from chapter 1: the six column bits and
the four row bits, so the display fetches address `row·64 + column` — which is
exactly how BASIC's screen addresses are laid out at 0x3C00, because they are *the
same wires*. The scan line counter L1–L8 is absent: all twelve lines of a character
row re-read the same 64 bytes, twelve times over. And C1 is the bit chapter 1
pinned low in 32-character mode — the RAM keeps all 1024 cells, but only the even
addresses ever reach the screen.

## 2. The fourth function hiding in Z49 (and resistor R49)

Two of Z49's four sections don't carry addresses. They multiplex the *strobes*:

```
~VRD = VID* ? pull-up : ~RD          Z49b — gates the read buffers
~VWR = VID* ? pull-up : ~WR          Z49d — gates R/~W of all seven RAMs
```

While the chain owns the RAM, both inputs hang on R49 (4.7 kΩ to +5 V): the chain
can never write, and the RAM's data can never leak onto the CPU bus. The moment
VID\* drops, the CPU's own RD\*/WR\* pass straight through. It is the cheapest
possible bus protocol — the "who may do what" rules are encoded in one resistor.

## 3. Seven RAMs, always on (Z45–Z48, Z61–Z63)

The store is seven 2102s — 1024×1 static RAMs — with their address pins paralleled
on VA0–VA9 and, notably, **~CE grounded on every chip**: they are never deselected,
their outputs always drive. Six chips (Z48, Z47, Z46, Z45, Z61, Z62) hold data bits
0–5; the seventh (Z63) holds bit 7, the graphic/alpha flag. Bit 6 famously does not
exist in silicon — chapter 2 told that story from the display's point of view; §4
tells it from the CPU's. Writes are equally minimal: each DIN pin is wired straight
to the CPU data bus, and the common R/~W line is just ~VWR from §2. No write
buffer, no byte enables — seven bits in, and whatever the CPU put on D6 falls on
the floor.

The RAM outputs (VD0–VD5, VD7) are the pipeline input chapter 2 consumed: they feed
the Z28/Z27 latches directly, with no buffer in between. The same nets *also* feed
the CPU read path:

## 4. What a PEEK really returns (Z60, Z44, and Z30 again)

Two 74LS367 tri-state buffers — Z44 for bits 0–3, Z60 for bits 4–7 — connect the
RAM outputs back to the CPU data bus, enabled only while ~VRD is low. And sitting
on this sheet, between the RAMs and the buffer, is Z30's fourth NOR gate: the
sneaky bit, `VD6 = NOR(VD5, VD7)`. The synthesized bit goes through Z60 like any
real one — so the CPU reads it too. The structure alone dictates a little table of
Model 1 folklore, each line of which the testbench replays:

| POKE | stored (7 bits) | PEEK | why |
|---|---|---|---|
| 0x40 `@` | 0,000000 | **0x40** | NOR resurrects the dropped bit — `@` survives |
| 0x7F | 0,111111 | **0x3F** `?` | bit 6 dropped, NOR blocked by bit 5 |
| 0x1F | 0,011111 | **0x5F** `←` | control codes read back as the letters they display |
| 0xFF | 1,111111 | **0xBF** | graphics keep bit 7, lose bit 6 |

Screen memory is the one region of the address space where `PEEK(POKE)` is not the
identity — the display and the CPU are subject to the same seven-bit truth.

## 5. The takeover: no WAIT, no mercy

The manual describes WAIT generically ("you may not have any use for them") and
never once connects it to video. When the CPU addresses 0x3C00–0x3FFF, VID\* drops
*whenever the decode says so* — mid-cell, mid-glyph, mid-anything — and the muxes
flip combinationally. The chain keeps counting (it never stops; chapter 1's beam
marches on), but its addresses go nowhere: the RAM now answers the CPU. Whatever
the video side fetches during those cycles is garbage.

The reason the screen shows *black* garbage instead of random garbage is chapter
2's Z7: VID\* low forces VCLR\*, the data latches clear, nothing loads, and the
in-flight cell drains to darkness. The manual owns the artifact in plain words:
*"Ever notice black streaks all over the screen while graphics are being drawn?
These streaks are the result of the counter chain losing control over video RAM."*

A terminology note, for honesty's sake: the community (and our SPEC switch Z1)
says "snow", but on a Model 1 the artifact is strictly **subtractive** — pixels can
only be darkened, never lit. White-dot snow is other machines' problem (the Model
3 waits instead, and CGA cards famously sparkle). The testbench asserts
subtractiveness for every dot of a frame under fire: a streak may erase, it may
never invent.

## 6. The same property, seen from the other side: beam hacks

Because the takeover is instantaneous and the *only* penalty is visual, software
that times its accesses into the blanking intervals pays nothing at all. That is
[SPEC §6](../SPEC.md)'s test criterion (b), and it is subtler than "wait for
HDRV": the pipeline from chapter 2 shifts the danger zone by two cells. The load
for the **last visible column** happens at the latch edge one full cell *into*
horizontal blanking — an access launched exactly at hblank start still bites a
piece out of column 63. The safe window therefore runs from one cell after blank
onset until early enough that VCLR\* is released by the last blanking latch
(chapter cells ~65…109 of 112; vertical blanking is 8000+ dots deep and relaxed).
The testbench drives a full frame of read/write traffic placed inside that window
and demands the frame be **dot-for-dot identical** to an undisturbed one — and a
frame of traffic aimed at the visible region, demanding streaks that are
subtractive, local to each access, and actually present. A mid-frame write ahead
of the beam lands on screen in the same frame, exactly as a beam-racing program
would rely on.

## 7. The signal contract (what the RTL exports)

| Signal | Meaning | Hardware origin |
|---|---|---|
| `col[5:0]`, `row[3:0]` | chain address C1…C32, R1…R8 | chapter 1's counters |
| `vid_n` | CPU is addressing 0x3C00–0x3FFF | address decoder (chapter 4) |
| `rd_n`, `wr_n` | CPU strobes | Z80 bus |
| `a[9:0]`, `din[5:0]`, `din7` | CPU address and write data (no D6 pin exists) | Z80 bus |
| `dout[7:0]`, `dout_en` | read data incl. synthesized bit 6; Z60/Z44 as enable | this sheet |
| `vd[5:0]`, `vd7` | the seven raw RAM outputs | to chapter 2's latches |

Inside: the 10-bit address mux, the strobe mux with its "R49" terms, one 1024×7
array standing for seven chips. Deviations (synchronous write while ~VWR is low,
zero-delay read, tri-state modeled as data + enable) are listed in the module
header; see also ADR-0001.

## 8. What the testbench proves (and how to watch it)

`sim/tb_m1_vram.sv` is the first bench to wire the whole chain — timing → VRAM →
video generation — with a small Z80-shaped bus model (3 T-states of VID\* per
access, strobes centered):

- all 1024 cells written and read back through the muxes; `dout_en` discipline,
- the bit-6 table from §4, all four rows,
- R49 isolation: strobes without VID\* neither write nor drive the bus,
- a full frame rendered from the real RAM, every dot against an independent model
  fed from a shadow array (this pins VA = {R,C}, i.e. address = row·64+col),
- blanking-only CPU traffic → frame dot-identical to the undisturbed one,
- visible-region traffic → streaks: subtractive, local, present; one true write
  landing mid-frame; `build/frame_streaks.pgm` dumped as the third picture this
  project produces (`make frames` → `frame_streaks.png` — instantly recognizable
  to anyone who ever LOADed from tape),
- 32-character mode: even addresses only, full-frame exact.

To *watch* the takeover: `cd sim && make wave-vram`, add `vid_n`, `u_vr.va`,
`u_vr.q`, `u_vg.lb`, `u_vg.sr_alpha`, `pixel`, and find any `vid_n` dip in the
streak-frame region (~50 ms onward). You can see `va` snap from the marching
counter value to the CPU's address, `q` answer with the CPU's cell, `lb` clear a
dot later, and the pixel stream run dry — then refill two cells after release.
The whole story of this chapter is maybe twenty microseconds wide.

## 9. Open items

- [ ] The CPU side is a bus *model* (3 T-states, centered strobes). The real
      takeover length and phase come with the Z80 core and the address decoder
      (chapter 4+); the screen-absolute cross-check against trs80gp remains the
      standing golden-model milestone.
- [x] ~~VID\* is generated here by the testbench; the decode chain of the manual
      (Z21 + Z36/Z37/Z52) is chapter 4.~~ Done:
      [chapter 4](04-address-decoder.md) builds the decoder and drives this
      module through it with full 16-bit bus cycles.
- [ ] **The golden model (trs80gp) does not model this sneaky bit 6.** Its `-it`
      VRAM dump returns the raw written byte; our RTL (and real hardware, per the
      manual) reconstructs D6 = NOR(D5, D7) on read. The two agree for every byte
      real software produces (ASCII, block graphics — all satisfy
      D6 == NOR(D5, D7)); they diverge only for a hand-built value like 0x7F.
      Found while verifying chapter 6; the byte-exact `make golden` check is thus
      authoritative for real content and *more* faithful at that one bit. Harmless,
      but worth knowing when reading a diff.
- [ ] 2102 access time is modeled as zero-delay; the manual gives no speed grade.
      Irrelevant on the dot grid (the pipeline grants six dot times), noted for
      completeness.
