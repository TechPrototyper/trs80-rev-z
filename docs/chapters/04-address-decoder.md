# Chapter 4 — The Address Decoder: Six Bits Rule the Map

*Sources: TRS-80 Technical Manual (Theory/Parts/Schematics, 1978), "The Memory
Map", "Address Decoder", "Address Decoder Programming", "ROM/Keyboard/Video
Display RAM/RAM Decoding" (pp. 4, 8–11) and Schematic Sheet 1; the manual walks
the Level I configuration — the Level II wiring modeled here is taken pin by pin
from RetroStack's Rev G KiCad recreation (`AddressDecoder.kicad_sch`,
`CPUGating.kicad_sch` for context), extracted with
[`tools/kicad_nets.py`](../../tools/kicad_nets.py). RTL:
[`rtl/m1_addr_decode.v`](../../rtl/m1_addr_decode.v); testbench:
[`sim/tb_m1_addr_decode.sv`](../../sim/tb_m1_addr_decode.sv).*

Chapter 3 ended with `vid_n` arriving from a testbench. This chapter builds the
circuit that really drives it — and with it the entire personality of the memory
map from [SPEC §3](../SPEC.md): why ROM and RAM are genuinely separate devices,
why 0x3000–0x37FF is *nothing*, why the keyboard appears four times. The whole
thing is one decoder chip, four gates' worth of glue, some pull-up resistors —
and a component that is literally a set of shorting bars you program with wire
cutters.

## 1. One chip decodes the top digit (Z21, and its gatekeeper Z73)

Z21 is a 74LS156: a *dual 2-to-4* decoder with open-collector outputs, wired as
a 3-to-8. A12 and A13 drive the two select inputs of both halves; A14 goes to
the two C ("data") inputs — one half is active when A14 = 0, the other when
A14 = 1. So the eight outputs decode A14–A12: the most significant hex digit of
the address, given A15 = 0.

The strobes of both halves hang on one OR gate (Z73b): `A15 | RAS*`. RAS\* is
the buffered ~MREQ — the manual is explicit: *"it is the same signal"*. The
decoder therefore fires only during **memory cycles in the lower 32 K**; during
I/O cycles, refresh, or any address ≥ 0x8000, all eight outputs float high and
this board selects nothing.

| Z21 output | address block | ends up as |
|---|---|---|
| Q0b (pin 9) | `0xxx` | → ROMA\* |
| Q1b (pin 10) | `1xxx` | → ROMA\* |
| Q2b (pin 11) | `2xxx` | → ROMB\* |
| Q3b (pin 12) | `3xxx` | → the keyboard/video window (§3) |
| Q0a (pin 7) | `4xxx` | → RAM\* |
| Q1a (pin 6) | `5xxx` | → RAM\* |
| Q2a (pin 5) | `6xxx` | → RAM\* |
| Q3a (pin 4) | `7xxx` | → RAM\* |

## 2. Programming with wire cutters (X3, the DIP shunt)

How do eight one-hot outputs become three selects? By shorting them together —
which is normally a TTL sin, but Z21's outputs are open collector: tied outputs
wire-OR (in active-low terms: the select goes low if *any* participant pulls).
The joining is done by **X3**, a "DIP shunt" in socket position Z3: sixteen pins
bridged by breakable bars. Snip some bars, leave others, and you have configured
how much ROM and RAM the machine owns — the manual calls this, wonderfully,
*Address Decoder Programming*. Pull-ups R61/R68/R62 (and R48 on the 3xxx line)
make the wire-OR work.

The Rev G sheet carries the **Level II** configuration:

```
ROMA* = 0xxx · 1xxx      8 K  — ROM A, 0x0000-0x1FFF
ROMB* = 2xxx             4 K  — ROM B, 0x2000-0x2FFF
RAM*  = 4xxx·5xxx·6xxx·7xxx   16 K — 0x4000-0x7FFF
```

(The manual's Level I walkthrough has 4 K of ROM and describes growing RAM\*
bar by bar: 4 K, 8 K, 12 K, 16 K. Same circuit, different snips.) The RTL writes
each wire-OR as the AND of the participating outputs — the identical truth
function, minus the solder.

## 3. The 0x3800 window, split by one address bit

Output Q3b (`3xxx`) selects nothing by itself. It meets A11 (inverted by a
spare NOR, Z37b) at OR gate Z36b — the manual's charming *"incorrectly drawn OR
gate"*: both inputs low makes the output low, i.e. the window is
0x3800–0x3FFF. Then A10 splits it:

```
KYBD* = window · (A10 = 0)     0x3800-0x3BFF
VID*  = window · (A10 = 1)     0x3C00-0x3FFF     ← chapter 3's ~VID
```

Two famous map facts fall straight out:

- **0x3000–0x37FF selects nothing.** Q3b is active but A11 = 0 — no gate
  claims the address. Open bus, exactly as SPEC §3 demands it stay observable.
  (The Expansion Interface later squats at 0x37E0–0x37EF — *its* decode, not
  this board's.)
- **The keyboard appears four times.** Nothing below A10 is decoded here; the
  matrix rows are addressed by A0–A7 inside a 1 K select window, so
  0x3800/0x3900/0x3A00/0x3B00 all show the same keyboard. Partial decoding as
  a feature — one select line saved, four mirrors bought.

## 4. MEM\* — a buffer enable, only for reading

The last output is the subtlest. Z74/Z73c/Z52f compute

```
MEM* = (ROMA or ROMB or RAM selected) AND RD active
```

MEM\* opens the ROM/RAM data-bus buffers toward the CPU. Note what is *not* in
the equation: writes. The manual explains why with disarming directness: *"the
RAM data inputs are on the output side of the buffers"* — write data flows
around the buffers, so only reads need the gate. The keyboard has its own
buffers (enabled by KYBD\* directly), and the video RAM has chapter 3's Z60/Z44
(enabled by VRD\*). Three subsystems, three data doors, one address decoder
deciding which one opens.

## 5. What is deliberately not here

- **RAS\*** arrives as an input; it is the buffered ~MREQ from the CPU sheet
  (Z72 — the buffer layer of `CPUGating.kicad_sch`, which also tri-states
  address and control via TEST\* for the Expansion Interface). That layer comes
  with the Z80 core.
- **I/O ports.** Port 0xFF (cassette latch + MODESEL, the chapter-1 open item)
  is decoded from IN\*/OUT\* by entirely separate logic — the I/O chapter.
- **The upper 32 K.** A15 = 1 disables everything; expansion RAM decode lives
  in the EI (M3).

## 6. The signal contract (what the RTL exports)

| Signal | Meaning | Hardware origin |
|---|---|---|
| `a[15:10]` | the only address bits the decoder sees | CPU address bus |
| `ras_n` | memory cycle (buffered ~MREQ) | Z72 / CPU sheet |
| `rd_n` | CPU read strobe | CPU control group |
| `roma_n`, `romb_n` | ROM chip selects, 8 K + 4 K | Z21 + X3 |
| `ram_n` | RAM select, 16 K | Z21 + X3 |
| `kybd_n` | keyboard window, 0x3800–0x3BFF | Z36d |
| `vid_n` | video window, 0x3C00–0x3FFF → chapter 3 | Z36c |
| `mem_n` | ROM/RAM read-buffer enable | Z74b |

Pure combinational logic — the module is the schematic, gate for gate; the one
liberty (wire-OR written as AND of active-low terms) is noted in the header.

## 7. What the testbench proves (and how to watch it)

`sim/tb_m1_addr_decode.sv` checks **all 262 144 decoder states** — every 16-bit
address × RAS\* × RD\* — against an independently coded map that knows only hex
ranges (SPEC §3's table, not the decoder's equations), asserts that never more
than one select is active, then walks twelve named anchor addresses (ROM A/B
boundaries, open bus, keyboard mirrors, RAM edges, upper 32 K). Finally it puts
chapter 3's `m1_vram` behind the decoder and drives full 16-bit bus cycles:
writes to 0x3C00/0x3FFF land (and read back through the sneaky-bit NOR),
writes to 0x3801 and 0x4000 must not, and a read of a keyboard address must
leave the video RAM's bus buffers shut. The run prints the anchor table —
`cd sim && make` and read it; for a combinational module that table *is* the
waveform guide.

A methodology note: this is the first chapter whose netlist extraction ran
through [`tools/kicad_nets.py`](../../tools/kicad_nets.py) instead of a manual
agent pass — the tool was first validated by reproducing chapter 3's
independently extracted `VideoAccessMultiplexer` netlist exactly.

## 8. Open items

- [ ] `ras_n` and the strobe layer (RD\*/WR\*/IN\*/OUT\* from ~MREQ/~IORQ,
      TEST\* tri-stating, DBIN\*/DBOUT\* bus direction) are testbench-driven;
      they arrive with the Z80 core chapter.
- [ ] Port 0xFF decode and the MODESEL latch (chapter 1's open item) — the I/O
      chapter.
- [ ] Other shunt configurations (Level I 4 K ROM, smaller RAM) are documented
      here but not parameterized; the Goldstandard is the Level II machine.
- [ ] EI-side decode (0x37E0–0x37EF, upper 32 K) — M3.
