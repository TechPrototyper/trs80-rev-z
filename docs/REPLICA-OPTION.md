# A real Model 1 to test against: borrow, buy, or build (RetroStack Rev G)

*Written 2026-10-25. Prices are estimates for a buyer in Germany, dated; the BOM numbers
come from RetroStack's own files (US prices, January 2024). Nothing here is ordered or
committed. Companion to [INTERPOSER-PLAN.md](INTERPOSER-PLAN.md) and
[ADR-0013](decisions/0013-ei-on-the-real-bus.md).*

## Why we want one at all

This project calls itself *verified*. So far that means verified against schematics, the
manuals and golden emulators — which were built from the same documents. Silicon next to
the FPGA, same code, same signals on the oscilloscope, turns the claim into a measurement.
The physical dongle (ADR-0009, INTERPOSER-PLAN) and the three operating modes of ADR-0013
all need a real Model 1 **keyboard unit** on the bench. An Expansion Interface is *not*
required: in Mode 2 the FPGA *is* the EI (48 K, WD1771 + Percom, DMK from SD).

Three ways to get one, in order of cost:

1. **Borrow** one around Hamburg for the 40C3 days or a day beforehand (see "Help wanted").
2. **Buy** a used keyboard unit: in Europe roughly 150–400 € untested/defective,
   400–800 € working; US dealers ask well above 1000 USD for "fully tested".
3. **Build** one from Marcel Erz's RetroStack designs — the rest of this page.

## What RetroStack provides (all MIT, github.com/RetroStack)

- **TRS-80-Model-I-G-E1** — 1:1 Rev G mainboard: Gerbers (PCBWay/JLCPCB), BOM (CSV/PDF),
  schematics, a 27-step assembly guide. 74 ICs plus two DIP shunts, 102 BOM lines.
- **TRS-80-Model-I-Keyboard-MX** — a replacement keyboard with MX switches, own PCB,
  3D-printed bezel and shield, 20-pin IDC to the mainboard, keycap print template.
- **TRS-80-Model-I-Keyboard-ALPS** — the original ALPS PCB, for those who have switches.
- **TRS-80-Model-I-Parts** — the complete case as STL: original and "improved" shells for
  resin printing at JLC3DP, plus a split version (≤ 216 × 205 mm) for home FDM printers.
- **TRS-80-Model-I-Power-Supply-New** — mains transformer design (DST-6-16 for 230 V),
  PCB, 3D-printed case. **Mains voltage inside.**
- **2332_2364-ROM_Adapter**, **MCM776x_CharGen_Adapter**, **TRS-80-Model-I-System-ROMs** —
  what replaces the unobtainable mask ROMs.
- **TRS-80-Model-I-Arduino-Library**, **Arduino-M1-Shield**, **TRS-80-Model-I-Test-Harness**
  — hang on the 40-pin bus; a reference worth reading for our interposer.

RetroStack's own store closed in early 2025 and Patreon memberships are paused: there is
nothing assembled to buy. Dusty's Vintage Workshop (eBay) sells PLA cases, power supplies
and ROM upgrades; prices only on the listings.

Not needed: a VGA adapter. The Model 1 puts composite video on pin 4 of its 5-pin DIN
monitor socket; a DIN-to-RCA cable and any composite-capable display or a cheap
composite-to-HDMI converter will do.

## Cost (estimates, EUR, landed in Germany)

The mainboard BOM sums to **266 USD** (RetroStack CSV, January 2024, sockets included at
62 USD, ROMs and character generator excluded). European sourcing and today's NOS prices
push it up: 4116 DRAMs are 2.50–9 € each from EU eBay sellers, the Z80 is still available.

| Item | EUR | Notes |
|---|---|---|
| Mainboard PCB, minimum order of 5 | 180–280 | 407 × 184 mm, gold fingers with chamfer; only an upload gives the real quote; four spare boards |
| Mainboard parts incl. sockets | 280–380 | Mouser, Jameco substitutes, eBay NOS for 4116/2102 |
| ROM + chargen adapters, EEPROMs | 30–50 | plus a programmer (~60 €) or a friend with one |
| MX keyboard: PCB, 69 switches, ICs, shield, cable | 90–130 | |
| Keycaps, custom printed (MaxKeyboard 105 ISO + print fee) | 150–200 | cheap option: a plain beige set ~45 € with wrong legends |
| Case: resin at JLC3DP, both halves, painted | 150–300 | estimate from volume; FDM split version ~30 € material plus a lot of sanding |
| Power supply, RetroStack design | 70–100 | mains; or buy Dusty's, price unknown |
| Video: DIN cable + composite-to-HDMI | 25–40 | |
| Tools for a first-timer | 120–200 | zero if you have a bench |

A **bare test rig** (no case, cheap keycaps) lands around **800–1000 €**; the **full,
faithful machine** around **1100–1500 €**. That is not cheaper than buying a used one. The
value is elsewhere: guaranteed Rev G, new electrolytics, every part known, exactly our
SPEC reference machine — and four spare PCBs for the community.

## Effort

The mainboard has roughly 1600 solder joints, about 1150 of them in sockets. Bring-up is a
staged recipe in Marcel's guide: calibrate the three rails with two chips fitted, then
video, then the character generator, then ROM. Parts come from four suppliers; PCB, resin
case and keycaps each have 4–6 week lead times.

| Profile | Effort | Risk |
|---|---|---|
| First-timer | 60–100 h over 3–4 months if done alone | high: 74 ICs as a first project; debugging without a reference stalls; mains PSU is off limits |
| Occasional hobbyist | 40–60 h, 2–3 months | medium: soldering is routine, bring-up is the crux |
| Semi-pro | 20–30 h, 3–4 weekends | low: waiting for parts dominates |

### Where first-timers actually fail, and what this project changes

- **Volume, not skill.** Joint 1200 is made tired on the third evening; a cold joint on a
  74LS socket looks almost right. Discipline: one component group per session, continuity
  check at the four Z18 pads after each group (as the guide says), loupe over every joint
  before the next group.
- **Mix-ups the guide itself warns about:** glass diodes with faint bands, C42 reversed
  relative to the other electrolytics, two positions named C58, 74C vs 74HC.
- **Expensive chips too early.** The 4116s need all three rails in order; a mis-set rail
  kills eight NOS chips at once. They, the Z80, the ROMs and the chargen stay in the drawer
  until the rails have measured stable for a week.
- **Not knowing what "right" looks like.** This is the one we can fix. We have the machine
  as an FPGA model with simulation: for every step of the guide we can state in advance the
  voltage, frequency and waveform expected at a given pin, derived from the Rev G schematic
  and our core. Measure, compare, and a deviation points at one of five functional blocks.
  Nobody building this board for the first time has had that next to them.

**Worst case:** a board that does not come up and sits in a drawer — about 300 € of parts
and some evenings. No fire, no damaged rarity. And a stuffed board with a fault is a
two-hour job for someone experienced; unlike a 45-year-old machine, every fault in a new
build from a verified design is *yours*, which makes it findable.

### Sensible division of labour

First-timer: procurement, the case (order, sand, paint), the MX keyboard (200 joints, big
pads, very forgiving — the ideal first soldering job and the test of whether 1600 more would
be joy or misery), video. 20–30 hours, nothing dangerous. Mainboard and power supply: someone
who has done this before, ideally the person we are looking for anyway. Four spare PCBs plus
the MIT license make a fair offer: whoever stuffs our board keeps a second PCB.

## What has value, and what is only pretty

Value: the machine as ground truth; the debugger on real silicon (source-level debugging of
a 1977 machine from VS Code without touching its ROM — to our knowledge not available for
the Model 1 today); the congress story (reproducible, open, tools instead of nostalgia).

No technical value: the painted case and faithful keycaps (~500 € and weeks for zero
verification value — spring, not December); the EI as a product for other people's machines
(MISE and TRS-IO already cover RAM, disk and network; our angle is Rev G fidelity plus the
debugger, see ADR-0013).

## Help wanted

- **You own a TRS-80 Model 1 (keyboard unit is enough) in or near Hamburg** and would
  bring it to **40C3 (27–30 December 2026)** or lend it for a day beforehand. We will not
  modify it: the interposer is designed to be observe-only unless told otherwise, with
  pull-ups that keep an unconfigured FPGA off the bus (INTERPOSER-PLAN §4.1).
- **You enjoy soldering** and would build the RetroStack Rev G board with us — at home,
  in a hackerspace, or **on the congress itself, assembly-style, if that sounds like fun**.
  We bring the PCBs (five come in the minimum order, you keep one), the parts, and the
  per-step expected measurements from the FPGA model.
- **You have built one already**: tell us what the BOM and the guide got wrong for a
  European build. Corrections go to [RESEARCH.md §5](RESEARCH.md).

Contact: issues in this repository. German is fine.

## Sources

- RetroStack: [organization](https://github.com/RetroStack),
  [Rev G replica](https://github.com/RetroStack/TRS-80-Model-I-G-E1),
  [central Model 1 repo](https://github.com/RetroStack/TRS-80-Model-I),
  [MX keyboard](https://github.com/RetroStack/TRS-80-Model-I-Keyboard-MX),
  [3D parts and case](https://github.com/RetroStack/TRS-80-Model-I-Parts),
  [power supply](https://github.com/RetroStack/TRS-80-Model-I-Power-Supply-New)
- [Hackaday on the Rev G PCB](https://hackaday.com/2024/01/10/brand-new-pcb-makes-replica-trs-80-possible/),
  [Hackster](https://www.hackster.io/news/marcel-erz-brings-back-the-trs-80-model-i-with-a-high-accuracy-open-hardware-pcb-replica-49c3aaec0c71)
- [Dusty's Vintage Workshop](https://dustysvintageworkshop.com/products/model-1-case.html)
- [trs-80.com on the Model I power supply](https://trs-80.com/sub-repairs-model-1-power-supply.htm),
  [composite adapter pinout](https://tinkerdifferent.com/threads/radio-shack-trs-80-model-i-video-to-composite-adaptor-pinout-layout.2244/)
- [4116 NOS on eBay.de](https://www.ebay.de/itm/156719430603) (price sample),
  [JLC3DP](https://jlc3dp.com/), [JLCPCB gold fingers](https://jlcpcb.com/help/article/jlcpcb-gold-fingers)
