# Model 1 Bus Interposer — ULX3S ↔ TRS-80 40-pin expansion edge

**Status:** build plan, draft 2026-10-24 · realizes ADR-0009 Phase 0 ("cabled
interposer → ULX3S") · target: a working demo at 40C3 (Hamburg, 27–30 Dec 2026).

This document is written so that somebody who has never seen this repository
can build the hardware from it. Everything electrical here is traceable to the
Tandy manuals named in [RESOURCES.md](RESOURCES.md); items still to be checked
against physical hardware are marked **VERIFY**.

## 1. What it is, in one paragraph

A small two-layer PCB in a box. On one side a 40-way IDC box header; a short
ribbon cable runs from there to a 40-position 0.1″ card-edge connector that
plugs onto a real TRS-80 Model 1 (the keyboard unit's expansion edge, or the
original Expansion Interface's screen-printer bus). On the other side two IDC
box headers with ribbons to the ULX3S GPIO headers J1/J2. In between: five
74LVC245 level shifters (the TRS-80 bus is 5 V TTL, the ECP5 is 3.3 V and **not**
5 V tolerant) and three open-drain drivers for the lines the dongle may pull low
(TEST\*, WAIT\*, INT\*). The ULX3S runs the existing `m1_debug` core; the board
makes the real machine's bus look to it like the simulated one.

**Why not "just a cable":** a bare ribbon would put 5 V TTL highs on ECP5 pins
(absolute max 3.6 V) and would give no way to keep the FPGA off the bus while it
is unconfigured. The shifters are what turn a cable into a safe device. The box
is not decoration either: at a congress table the thing gets plugged, bumped and
re-plugged all day; a bare PCB on a ribbon dies by Day 2.

## 2. Where it plugs in — three Model 1 configurations

| Machine | Attach point | Works? |
|---|---|---|
| Keyboard unit only (16 K, cassette) | 40-pin expansion edge on the back of the keyboard | **Yes — primary target for 40C3.** Pinout: TRS-80 Micro Computer Technical Reference Handbook, 2nd ed. (1982), "Pin Connections for Expansion-Port Edge Card", p. 91 |
| With **original** Expansion Interface (PCB 1700077A, Service Manual 1979, 26-1140) | EI card edge **J3 "Screen Printer Bus"** — labelled in the schematic "TO TRS-80 INTERFACE BUS (J2)", an unbuffered 1:1 copy of the bus including TEST\* and WAIT\* | Yes, same cable |
| With **redesigned** Expansion Interface (0K units from serial 035000, "[Redesigned PCB]" Service Manual) | — | **No passthrough.** On the redesigned board J3 is a 34-pin "Buffered Interface Bus" with printer-style signals (DATA STROBE\*, D1–D8, BUSY, FAULT\*…), and the manual states the Screen Printer is the one peripheral no longer supported. The bus edge J2 is occupied by the keyboard cable. Attaching here would need a Y-interposer between keyboard edge and EI cable — out of scope for Phase 0. |

Consequence for the congress: ask for a Model 1 **keyboard unit**; an EI is nice
to have but not needed. If someone brings an original (1979) EI, the same
cable goes onto its J3.

The redesigned EI's J2 table (viewed from the front of the EI) is pin-for-pin the
keyboard edge table, with pins 1, 3 and 16 (RAS\*, CAS\*, MUX) marked "Not
Connected" — the redesigned EI regenerates those locally. Everything the
dongle needs is on both.

## 3. The 40-pin edge, signal by signal

Source: Technical Reference Handbook 2nd ed., p. 91 (table reproduced in
[`boards/ulx3s/interposer/pinmap.csv`](../boards/ulx3s/interposer/pinmap.csv)).
Mates with AMP 88103-1 card-edge connector "or equivalent" (0.100″ pitch,
2 × 20, IDC). Direction is from the TRS-80's point of view.

| Pin | Signal | Dir | Pin | Signal | Dir |
|---|---|---|---|---|---|
| 1 | RAS\* | out | 2 | SYSRES\* | out |
| 3 | CAS\* | out | 4 | A10 | out |
| 5 | A12 | out | 6 | A13 | out |
| 7 | A15 | out | 8 | GND | — |
| 9 | A11 | out | 10 | A14 | out |
| 11 | A8 | out | 12 | OUT\* | out |
| 13 | WR\* | out | 14 | INTAK\* | out |
| 15 | RD\* | out | 16 | MUX | out |
| 17 | A9 | out | 18 | D4 | bidir |
| 19 | IN\* | out | 20 | D7 | bidir |
| 21 | INT\* | **in** | 22 | D1 | bidir |
| 23 | TEST\* | **in** | 24 | D6 | bidir |
| 25 | A0 | out | 26 | D3 | bidir |
| 27 | A1 | out | 28 | D5 | bidir |
| 29 | GND | — | 30 | D0 | bidir |
| 31 | A4 | out | 32 | D2 | bidir |
| 33 | WAIT\* | **in** | 34 | A3 | out |
| 35 | A5 | out | 36 | A7 | out |
| 37 | GND | — | 38 | A6 | out |
| 39 | +5 V (limited) / **GND on Level II** | — | 40 | A2 | out |

Facts from the same page that shape the design:

- **Each line drives one TTL load.** The LVC245 input is a CMOS high-impedance
  input — far below one LS load. Good.
- **TEST\* low tri-states** A0–A15, D0–D7, WR\*, RD\*, IN\*, OUT\*, RAS\*,
  CAS\*, MUX on the keyboard. That is how the dongle takes the bus if it ever
  needs to (ADR-0006 §3a). INTAK\* and SYSRES\* are *not* tri-stated — they are
  always outputs of the machine.
- **Pin 39 is +5 V on Level I and GND on Level II machines.** Never connect it
  to anything. The interposer takes its 3.3 V from the ULX3S header.
- **Not on the edge:** NMI\*, M1\*, CLK, BUSRQ\*/BUSAK\*, MREQ\*/IORQ\*, RFSH\*.
  RD\*/WR\* are memory strobes, IN\*/OUT\* are port strobes; address is valid
  while they are low. All consequences for the debug primitives are in
  ADR-0006 and ADR-0009; nothing here changes them.

## 4. Electrical design

### 4.1 Level shifting

One supply, 3.3 V from the ULX3S. 74LVC245 inputs are 5 V tolerant, and a 3.3 V
LVC output (V_OH ≥ 2.4 V) is a legal TTL high (V_IH 2.0 V), so the same single
chip shifts both ways. No TXB/TXS auto-direction parts: they cannot source the
current of LS inputs and misbehave on a bus with pull-ups.

**Side convention:** TRS-80 on the **A** side, FPGA on the **B** side of every
'245. With DIR = H the chip drives A→B, i.e. *TRS-80 → FPGA* (observe). The ULX3S
LPF pulls all header pins up by default, so an unconfigured or crashed FPGA
leaves every bank in observe direction. Additionally every OE\* has a 10 k
pull-up to 3.3 V: unconfigured FPGA = all banks disabled. The FPGA must actively
pull OE\* low after configuration. These two choices are the whole safety
concept; do not "simplify" them away.

| Ref | Part | A side (TRS-80) | DIR | Note |
|---|---|---|---|---|
| U1 | 74LVC245 | A0–A7 | `addr_drv_n` | H = observe, L = FPGA drives (only under TEST\*) |
| U2 | 74LVC245 | A8–A15 | `addr_drv_n` | shared with U1 |
| U3 | 74LVC245 | D0–D7 | `data_drv_n` | L only while the dongle answers a read of its own window, or writes as bus master |
| U4 | 74LVC245 | RD\*, WR\*, IN\*, OUT\*, RAS\*, CAS\*, MUX, (spare) | `addr_drv_n` | these are exactly the strobes TEST\* tri-states, so they share the address bank's direction |
| U5 | 74LVC245 | SYSRES\*, INTAK\*, INT\*, WAIT\*, TEST\*, 3 × spare | tied H | inputs only, always enabled (OE\* to GND). Reading back INT\*/WAIT\*/TEST\* lets the core see when the *EI* asserts them |
| Q1–Q3 | 2N7002 (or one 74LVC07A) | TEST\*, WAIT\*, INT\* | — | open-drain pull-down, gate driven high to assert; 10 k gate pull-down so an unconfigured FPGA never asserts. INT\* is wire-OR'ed with the EI's 40 Hz heartbeat on a real machine — push-pull would fight it |

All chips: 100 nF at each VCC pin. One 10 µF bulk on the 3.3 V rail entry.
Ground: edge pins 8, 29, 37 all to the board ground plane, and all ULX3S GND
pins on both ribbons. The TRS-80 and ULX3S must share ground before any signal
pin touches — the IDC connectors guarantee that only if the GND pins are at the
ends of the connector as well as the middle; **VERIFY** on the chosen ULX3S
header pinout and consider a separate ground lead for belt and braces.

### 4.2 Timing (why this is relaxed)

Z80 at 1.774 MHz: one T-state is 564 ns, a read cycle keeps RD\* low for about
1.5 T ≈ 850 ns. LVC245 propagation is ~5 ns, the ribbon adds ~1 ns per 20 cm.
The FPGA synchronizes the bus into its own clock (two flops at 10–50 MHz) and
has hundreds of nanoseconds to present data for a read of the dongle's
memory-mapped window. WAIT\* is wired for the day that is not enough.

### 4.3 Bus loading and cable length

The Model 1 bus is unbuffered beyond the keyboard's own '367/'243 drivers — the
"flaky EI cable" folklore is real. Keep the edge-to-interposer ribbon
**≤ 20 cm**, keep the box right behind the machine, and let the ULX3S ribbons be
the long ones (30–40 cm is fine; those lines are 3.3 V CMOS point-to-point).
Optional 33 Ω series resistors in the FPGA-side lines of U1–U4 tame ringing on
longer ULX3S ribbons; footprint them, populate 0 Ω first.

### 4.4 Power sequencing

1. ULX3S on, bitstream loaded (all OE\* high, all drives off).
2. Plug/unplug the edge connector **only with the TRS-80 off**.
3. TRS-80 on.
4. Core enables the banks (OE\* low) and starts observing.

Reverse insertion of the edge connector mirrors odd and even pins; the three GND
pins land on A10, OUT\* and WAIT\* — annoying (machine stalls in WAIT), not
destructive. Still: mark pin 1 on the ribbon, the hood and the silkscreen.
**VERIFY** whether the keyboard edge has a polarizing slot and key the hood.

## 5. ULX3S pin map (draft)

42 FPGA pins: 16 address + 8 data + 7 bidirectional strobes + 5 read-backs +
3 open-drain drives + 3 bank controls. They fit on **GP/GN 0–10 (J1, 22 pins) and
GP/GN 18–27 (J2, 20 pins)** exactly, which deliberately avoids GP/GN 11–13
(shared with the ESP32's `wifi_gpio` 25/26/32–35) and GP/GN 14–17 (shared with
the ADC inputs). J1 carries data, strobes and read-backs; J2 carries the address
bus and the master-mode controls.

Sites are from `ulx3s_v20.lpf`. The full table is
[`pinmap.csv`](../boards/ulx3s/interposer/pinmap.csv); the LPF fragment is
[`interposer.lpf`](../boards/ulx3s/interposer/interposer.lpf). **VERIFY** the
physical J1/J2 header geometry and pin order against the ULX3S pinout drawing
for your board revision before the IDC footprints are placed; the LPF sites are
not in doubt, the header-to-ribbon ordering is.

| ULX3S | Signal | ULX3S | Signal |
|---|---|---|---|
| GP0/GN0 | D0 / D1 | GP18/GN18 | A0 / A1 |
| GP1/GN1 | D2 / D3 | GP19/GN19 | A2 / A3 |
| GP2/GN2 | D4 / D5 | GP20/GN20 | A4 / A5 |
| GP3/GN3 | D6 / D7 | GP21/GN21 | A6 / A7 |
| GP4/GN4 | RD\* / WR\* | GP22/GN22 | A8 / A9 |
| GP5/GN5 | IN\* / OUT\* | GP23/GN23 | A10 / A11 |
| GP6/GN6 | RAS\* / CAS\* | GP24/GN24 | A12 / A13 |
| GP7/GN7 | MUX / `data_drv_n` | GP25/GN25 | A14 / A15 |
| GP8/GN8 | `oe_n` / SYSRES\* (in) | GP26/GN26 | `addr_drv_n` / `test_drv` |
| GP9/GN9 | INTAK\* (in) / INT\* (in) | GP27/GN27 | `wait_drv` / `int_drv` |
| GP10/GN10 | WAIT\* (in) / TEST\* (in) | | |

GPIO-BUDGET.md allocated 33 pins for this consumer; the extra nine are the
RAS\*/CAS\*/MUX strobes (needed under TEST\* for DRAM sequencing, cheap to wire
now), INTAK\* (the IM-2 vector trick, ADR-0006), and the three read-backs. Still
within the budget's conclusion that the dongle owns the header.

## 6. Mechanical

- PCB ≈ 80 × 55 mm, two layers, all through-hole possible (SN74LVC245AN is
  available in DIP-20) — a perfboard prototype is realistic.
- J_TRS: 40-way 2.54 mm **boxed** IDC header, keyed.
- J_U1, J_U2: boxed IDC headers matching the ULX3S J1/J2 ribbon pinout (**VERIFY**
  count and keying; the ULX3S designers explicitly support "male vertical on
  bottom and flat cable").
- Three LEDs on the box lid, driven from the FPGA side via spare U5/U4 pins or
  simply from the control lines: POWER (3.3 V present), BUS (OE\* low),
  MASTER (TEST\* asserted). At a congress table the LEDs *are* the explanation.
- Enclosure: Hammond 1593-class ABS box or a printed case; the ribbons leave
  through slots on opposite short sides. RetroStack publishes 3D-printable
  Model 1 parts under MIT if a "Tandy-grey" look is wanted.
- The TRS-80 ribbon ends in the 40-position card-edge IDC connector with a
  strain-relief hood, exactly as Tandy's own EI cable did (parts list: "Hood,
  Connector, 40-pin").

## 7. Bill of materials (prototype)

| Qty | Part | Note |
|---|---|---|
| 5 | 74LVC245 (SN74LVC245AN DIP-20, or SOIC) | level shifters |
| 3 | 2N7002 (or 1 × 74LVC07A) | open-drain drives |
| 8 | 100 nF 0805/axial | decoupling |
| 1 | 10 µF | bulk |
| 6 | 10 kΩ | OE\* pull-ups ×? (one per bank), gate pull-downs ×3 |
| 32 | 33 Ω (optional) | series, FPGA side |
| 1 | 40-pos 0.100″ card-edge IDC connector + hood | TRS-80 end; AMP 88103-1 class, 3M 346x class, or retro-supplier "Model 1 expansion connector" |
| 1 | 40-way boxed IDC header | board, TRS-80 side |
| 2 | boxed IDC headers to match ULX3S J1/J2 | **VERIFY** size |
| ~1 m | 40-way ribbon (1.27 mm) | 20 cm TRS-80 side, rest for ULX3S side |
| 3 | LED + 1 kΩ | status |
| 1 | enclosure | |

Everything is stock at the usual distributors; the only part that needs a
specialist source is the card-edge connector.

## 8. Staging

Revised 2026-10-25 by [ADR-0013](decisions/0013-ei-on-the-real-bus.md): the interposer
is also the minimal Expansion Interface. Same board, no hardware change — the
EI RTL of ADR-0005 speaks exactly the signal set this edge carries.

1. **Perfboard prototype** (one evening with the BOM above). Bring-up goal:
   observe-only — the ULX3S shows the live Z80 bus of a real Model 1 in the
   trszog panel. No TEST\*, no drives populated yet (leave Q1–Q3 off).
2. **Mode 3 — dongle only, window loader.** Memory-mapped window 0x3000–0x37DF
   (the keyboard's decoder sees only A10–A15, so this is the same block the EI's
   37Ex registers live in — see §10), a mailbox FIFO, and a Z80 stub in the
   window that loads a /CMD from the SD card into the real 16 K after
   `SYSTEM` / `/12288`. Opcode fetches from the window are the shortest bus
   cycles the machine has: this is the complete dongle test.
3. **Mode 2 — EI + dongle.** Bus front end + source mux in the top; the EI
   container serves the real machine: 48 K, WD1771 + Percom, DMK from SD,
   heartbeat. `MEMORY SIZE?` answers 48 K; a DOS boots.
4. **Debugger backend for the real Z80**: INT\* entry (Q3), then TEST\*/WAIT\*
   bus mastering — Phase 0 → 1 of ADR-0009. Wired, not promised for December.
5. **KiCad board** for the congress: same schematic, boxed, LEDs. Order from a
   European fab (Aisler) to keep the loop under two weeks.

## 9. How you can help (the shareable part)

- **You own a TRS-80 Model 1 in or near Hamburg** (keyboard unit is enough; an
  Expansion Interface is *not* needed — in Mode 2 the FPGA is the EI) and would
  bring it to **40C3, 27–30 December 2026**, or lend it for a day beforehand.
  We will not modify it: the interposer is observe-only unless told otherwise,
  and its pull-ups keep an unconfigured FPGA off the bus (§4.1).
- **No Model 1 around? We are considering building one** from RetroStack's
  MIT-licensed Rev G replica — mainboard, MX keyboard, printed case — together
  with people who like soldering, at home, in a hackerspace, **or on the
  congress itself if that sounds like fun**. Cost, effort and the division of
  labour are worked out in [REPLICA-OPTION.md](REPLICA-OPTION.md); five PCBs
  come in the minimum order, co-builders keep one.
- **You like soldering**: build step 1 above from the BOM. The pinout table,
  the CSV and the LPF in this repository are everything you need; no Verilog
  required. The electrically interesting bits are the direction/enable safety
  rules in §4.1 — please keep them.
- **You know the Model 1 bus better than the manuals say** (buffered-cable
  mods, edge-connector keying, Japanese variants): corrections go to
  [RESEARCH.md §5](RESEARCH.md); that log is public on purpose.

Contact: issues in this repository. German is fine.

## 10. Open items (tracked here until they close)

- [ ] ULX3S J1/J2 header geometry and ribbon pin order (**VERIFY**)
- [ ] Keyboard edge polarization slot — yes/no, position (**VERIFY**)
- [ ] Exact card-edge connector part and supplier
- [x] ~~Confirm from the keyboard schematic that the data-bus buffer turns
      inward for reads in 0x3000–0x37DF~~ — closed 2026-10-25 by argument:
      the decoder (Z21/Z73b, `rtl/m1_addr_decode.v`) sees only A10–A15, so
      0x3000–0x37FF is one block, and every EI since 1978 is read by the CPU
      at 0x37E0/0x37EC inside it (ADR-0013 §Context, RESEARCH.md §5).
- [ ] **ROM listing check** (new, ADR-0013): interrupt mode of bare Level II
      BASIC after reset and the contents of the RAM vector at 0x4012 — decides
      whether INT\* entry works before the window stub has armed IM 2.
- [ ] Asynchronous-bus testbench for the EI container behind synchronized
      strobes (read side effects of 0x37E0 and the FDC data register), then
      oscilloscope confirmation of the fetch-from-window timing.
- [ ] LPF include wired into an `m1x_*` top-level port list once the perfboard
      exists
