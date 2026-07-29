# Chapter 6 — One Port to Rule Them All: 0xFF, Cassette and Mode Select

*Sources: TRS-80 Technical Manual (Theory/Parts/Schematics, 1978), "Port
Addressing", "Cassette Recorder Control", "Cassette Audio Output/Input",
"INSIG\*" (pp. 519-552) and Schematic Sheet 2; wiring cross-checked pin by pin
against RetroStack's Rev G recreation (`Cassette.kicad_sch`), extracted with
[`tools/kicad_nets.py`](../../tools/kicad_nets.py). RTL:
[`rtl/m1_io.v`](../../rtl/m1_io.v); testbench:
[`sim/tb_m1_io.sv`](../../sim/tb_m1_io.sv), plus the system bench
[`sim/tb_m1_cpu.sv`](../../sim/tb_m1_cpu.sv).*

The Z80 can address 256 I/O ports. The TRS-80 Model 1 uses **exactly one** —
port 0xFF — and packs three unrelated jobs into it: the cassette output
waveform, the cassette motor relay, and the 64/32-character video mode. This
chapter builds that one register. Its reward is closing chapter 1's last open
item: `MODESEL` finally has something driving it, and the CPU can switch screen
modes.

## 1. Decoding the only port there is (Z54, Z52, Z25)

I/O cycles put the port number on the low eight address bits. Port 0xFF means
all eight are high. Z54 (a 74LS30 eight-input NAND) watches A1–A7 and Z52c the
A0 line; when the address is 0xFF, their combination pulls **FF\*** low. Two
"backward" OR gates (Z25) gate that with the CPU's I/O strobes from chapter 5:

- **OUTSIG\*** = OR(OUT\*, FF\*) — low during an `OUT (0FFh)`
- **INSIG\*** = OR(IN\*, FF\*) — low during an `IN (0FFh)`

Both float high for every other port, so the rest of the 256-port space reads as
open bus and writes nowhere. In the RTL the whole decode is one line —
`ff_n = ~(&a)` — because a NAND of eight highs is exactly "all bits set."

## 2. The write latch (Z59, a 74LS175)

An `OUT (0FFh),A` clocks four data bits into Z59 on the **rising** edge of
OUTSIG\* — i.e. at the *end* of the output cycle, once the data is settled:

| bit | Z59 output | job |
|---|---|---|
| D0 | Q0 | cassette output level, bit 0 (into the R53–R56 ladder) |
| D1 | ~Q1 | cassette output level, bit 1 (the inverted tap is the one wired) |
| D2 | Q2 | cassette motor relay (Z41), 1 = running |
| D3 | **~Q3** | **MODESEL** |

That last inversion matters: **MODESEL = NOT(latched D3)**.
Write D3 = 0 and MODESEL is high — 64-character mode, the power-on default (Z59
clears to 0 on reset, so the machine boots in 64-char). Write D3 = 1 and MODESEL
goes low — 32-character mode. In our single clock domain (ADR-0001) the "rising
edge of OUTSIG\*" is detected on the dot clock instead of being a real latch
clock; the captured value is identical.

`MODESEL` runs straight into `m1_video_timing` (chapter 1), whose Z43 mux it
steers. Nothing else about the video chain changes — the mode was always a
one-wire input; chapter 6 is just the wire's other end.

## 3. The read buffer (Z44) — and what floats

An `IN (0FFh)` enables Z44 (a 74LS367 tri-state buffer) onto the data bus. Only
two bits are actually driven:

- **D7** = the cassette-input flip-flop (Z24)
- **D6** = MODESEL — the current video mode reads *straight back*

D5–D0 are connected to nothing, so the bus floats and the CPU reads them as 1.
The whole byte is therefore `{cassette, mode, 1,1,1,1,1,1}`: **0x7F** in 64-char
mode with no tape, **0x3F** in 32-char mode. (This is exactly what trs80gp
returns — §6 leans on it.)

The cassette flip-flop Z24 is a NAND set/reset latch: a cassette-input edge sets
it, and OUTSIG\* resets it. During a `CLOAD` the ROM pulses OUTSIG\*, waits, and
reads D7 to sample one bit — the "did a pulse arrive since I last reset?" trick.
Here it is modeled minimally: with no cassette the input stays low and D7 reads
0. The analog front end (Z4's filter/rectifier/level-detector turning tape audio
into those edges) is the M2 cassette milestone; this chapter provides the
digital register it will feed.

## 4. What this chapter deliberately leaves for M2

The cassette **output** level (2 bits) and **motor** are latched and exported,
but nothing consumes them yet — no DAC, no tape model. The cassette **input**
is a stubbed flip-flop. That is the honest scope line: chapter 6 is the *port*,
not the *cassette*. Everything video-relevant (MODESEL) and everything about the
port's digital contract (decode, latch, read-back) is complete and verified; the
analog tape path is a milestone of its own.

## 5. The signal contract (what the RTL exports)

| Signal | Meaning | Hardware origin |
|---|---|---|
| `a[7:0]`, `in_n`, `out_n` | port number + I/O strobes | CPU address bus / Z23 |
| `din` | write data (only D0–D3 latched) | data bus |
| `cass_in` | cassette input level | Z4 (M2) — stubbed low here |
| `dout`, `dout_en` | IN 0xFF read data + Z44 enable | Z44 |
| `modesel` | 64-char = high → `m1_video_timing` | Z59 ~Q3 |
| `cass_out[1:0]`, `cass_motor` | cassette level + motor | Z59 Q0/~Q1/Q2 |
| `ff_n`, `insig_n`, `outsig_n` | decode observability | Z54/Z52 / Z25 |

## 6. What the testbenches prove (and how to watch it)

Two levels. **`sim/tb_m1_io.sv`** is the unit check — the schematic is
authoritative for a one-port register, so the bench drives port cycles directly
and asserts the whole truth table: only 0xFF decodes; OUTSIG\*/INSIG\* are
exclusive; `OUT` latches D0–D3 with MODESEL = ~D3; a write to any other port
changes nothing; `IN 0xFF` returns `{cass, mode, 0x3F}` and drives the bus only
while INSIG\* is low; the cassette flip-flop sets on an input edge and resets on
OUTSIG\*.

**`sim/tb_m1_cpu.sv`** then proves it through the real CPU and the golden model.
The test program reads `IN 0xFF`, branches on the MODESEL bit, and writes a
**quirk-invariant tag character** to the screen — `'6'` or `'3'` — then switches
to 32-char mode with `OUT 0FFh,08h`, reads back again (now `'3'`), samples the
cassette bit (`'0'`, no tape), and switches back to 64-char with `OUT 0FFh,06h`
(which also turns the motor on). Row 1 of the screen ends up reading `>?630`:
the checksum digits from chapter 5, then the three port read-back tags.

Because those tags are ordinary digits (bit 6 clear, quirk-invariant), they
survive into the byte-exact `make golden` comparison. So the port's **read path
and mode switch are verified end-to-end against trs80gp** — the emulator agrees
that `OUT 0FFh,08h` selects 32-char mode and that it reads back on D6. `make`
runs both benches; `make golden` prints `MATCH 1024/1024`; `make wave-cpu` shows
`modesel` toggling on the `outsig_n` edges.

## 7. A note on the golden model's reach (the bit-6 finding)

Verifying the port turned up something worth recording about the *reference*.
trs80gp's `-it` VRAM dump returns the **raw written byte** — it does **not**
model the Model 1's "sneaky bit 6" (chapter 3: the video RAM has no D6 pin, so a
read reconstructs D6 = NOR(D5, D7)). Our RTL does model it. For every byte real
software actually puts on screen — ASCII text, the block-graphics codes, these
digit tags — the two agree, because those bytes all satisfy D6 == NOR(D5, D7)
and are invariant under the quirk. They diverge only for a deliberately
constructed byte like 0x7F (reads back 0x3F on real hardware and in our sim,
but 0x7F in trs80gp). The golden comparison is therefore authoritative for real
content and *more* faithful than the reference at the one bit where they differ
— a bound worth knowing, not a bug. Tracked in chapter 3's open items.

## 8. Open items

- [ ] **Cassette analog path (M2).** Z4 filter/rectifier/level-detector →
      cassette-input edges; the 2-bit output ladder and motor consumer; `.cas`
      loading from SD. The digital register is ready for all of it.
- [ ] **32-char display golden check.** The mode *switch* is golden-verified via
      the D6 read-back; the doubled-width *rendering* is verified per-dot in the
      video benches (chapters 1–3, both modes) but not yet screenshot-compared to
      trs80gp. A pixel-level golden of a 32-char frame would close the loop.
- [ ] **Bit-6 divergence from trs80gp** — see §7; a chapter-3 note, harmless for
      real content.
