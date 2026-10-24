# ADR-0013 — The Expansion Interface on the real bus: three operating modes, the bus front end, and the window loader

**Status:** accepted as design · 2026-10-25 · **implementation not started** (scheduling is the
maintainer's call; nothing in M4 is ticked by this record)

## Context

[INTERPOSER-PLAN.md](../INTERPOSER-PLAN.md) (2026-10-24) gave the physical dongle of
[ADR-0009](0009-physical-dongle.md) a concrete 42-pin map and a level-shifter design for the
Model 1's 40-pin expansion edge. Working out how that dongle would actually be *tested* on a
real Model 1 raised three facts that together change the plan:

1. **A bare keyboard unit has 16 K.** Nothing worth debugging fits comfortably; 48 K software
   needs an Expansion Interface, and original EIs are the least reliable part of the system.
2. **Our EI is already a bus device.** [ADR-0005](0005-expansion-interface-architecture.md)
   built `m1_ei` (0x37E0 register, drive-select latch, motor one-shot, heartbeat, INT\*),
   `m1_fdc` (WD1771 + Percom doubler), `m1_drives` and `m1_ei_ram` (the A15 region) as a
   container that speaks only the chapter-3 bus idiom: `a[15:0]`, `din`, `rd_n`, `wr_n`,
   `dout`, `dout_en`, plus `ras_n` as the memory-cycle qualifier. Its 1 MHz timebase is a
   phase accumulator off the dot clock, not the Z80. The whole media stack (`m1_sd_fs`,
   `m1_dmk_fetch`, `m1_sd_arb`, DMK write-back) is board-side and reaches the EI only through
   the track port. **That signal set is exactly what the 40-pin edge carries.**
3. **The keyboard unit cannot tell 0x3000–0x37DF from 0x37E0–0x37FF.** Its address decoder
   (Z21/Z73b, modeled in `rtl/m1_addr_decode.v` after the 1978 Technical Manual pp. 8–11)
   sees only A10–A15; 0x3000–0x37FF is one undivided "selects nothing" block. Every EI since
   1978 has its registers and the FDC *inside* that block and is read by the CPU through the
   bus buffers. Therefore external reads in 0x3000–0x37DF reach the CPU the same way. This
   closes the open item in INTERPOSER-PLAN §10 ("confirm the data-bus buffer turns inward for
   reads in 0x3000–0x37DF") by argument from the schematic rather than by re-sighting it.

## Decisions

### 1. Three operating modes, one bitstream

Selected by DIP switch; the EI population switch that already exists (`ei_ram_cfg`, with
`m1_ei.en = (ei_ram_cfg != 0)`) is reused unchanged.

| Mode | Name | Bus source | EI container | What the Z80 is |
|---|---|---|---|---|
| 1 | Full machine | internal `m1_core` | serves the internal core | tv80 in the FPGA (today's bitstream) |
| 2 | EI + dongle | external 40-pin edge via the interposer | serves the real machine | a real Z80 in a Model 1 keyboard unit |
| 3 | Dongle only | external 40-pin edge via the interposer | `en = 0` (the "bare keyboard unit" population) | a real Z80, machine stays 16 K |

In Mode 2 the real Rev G gets 48 K, a WD1771 with all four data address marks, Percom
double density, DMK images from the SD card, and the 40 Hz heartbeat — LDOS / NEWDOS/80 boot
on the replica. The core's own CPU, ROM, RAM, keyboard and video sit idle. Mode 3 is the
pure dongle test: the window at 0x3000–0x37DF and the debug path, nothing else on the bus.
Modes 2 and 3 differ by one switch position, so the same program can be run on the same
silicon at 16 K and at 48 K.

### 2. A bus front end, and no change to the EI modules

New RTL (one module, board side): two-flop synchronizers for RD\*, WR\*, RAS\*, IN\*, OUT\*,
INTAK\*, SYSRES\* into the 10.6445 MHz domain; address and data sampled against the
synchronized strobes; per-cycle data drive (`data_drv_n` in the pin map) derived from the
EI's and the dongle's `dout_en`; INT\* via the open-drain driver. A bus-source mux in
`ulx3s_top` selects the internal core or the external port.

**Acceptance criterion:** `m1_ei`, `m1_fdc`, `m1_drives` and `m1_ei_ram` are not modified.
The same RTL then serves the FPGA Z80 in Mode 1 and the real Z80 in Mode 2; any behavioral
divergence between the two machines is thereby pinned to the CPU/keyboard-unit side. That
differential setup is the point of the whole exercise for a project called *verified*.

**Timing budget (to be proven by an asynchronous-bus testbench, then by oscilloscope):**
the tightest external cycle is the M1 opcode fetch, RD\* low ≈ 1.5 T ≈ 845 ns at 1.774 MHz.
Against that: synchronizer 2–3 dot clocks (188–282 ns), BRAM registered read (94 ns), two
74LVC245 propagations (~20 ns), Z80 data setup before the rising edge of RD\* (tens of ns
per the Z80A data sheet). Margin is several hundred nanoseconds; WAIT\* stays unused. Writes
latch on the synchronized rising edge of WR\*. The read side effects (`m1_ei`'s trailing-edge
pre-clear of 0x37E0, the FDC data register) must be exercised by that testbench with
realistic strobe skew. **Measured numbers go to docs/RESEARCH.md when they exist.**

### 3. The window loader: the Z80 loads itself

Because the window is CPU-readable memory supplied by the FPGA, a **Z80 loader stub
(~150 bytes) lives in the window** and does what a DOS would do:

- reads a byte stream from a **mailbox FIFO** in the window (handshake registers plus a
  ~1 KB ring),
- parses **/CMD load-module records** (type 01 object block with length and load address,
  type 02 transfer address, type 05 module name) on the Z80 itself,
- writes the blocks to 0x4000 upward (Mode 3) or anywhere in 0x4000–0xFFFF (Mode 2),
- sets **IM 2 and I = 0x30** on the way — the ADR-0006 vector table and the debug stub live
  in the same window — so the debugger's INT\* entry is armed for the rest of the session,
- jumps to the transfer address.

Entry from the Level II prompt: `SYSTEM`, then `/12288` (0x3000). The stub may print the
CMD directory of the SD card and take a digit; the TRS-80 is then its own loader UI.

**Producers behind the FIFO seam** — none of them knows the file format:

| Producer | Path | Why |
|---|---|---|
| SD card | a 7th `m1_sd_fs` slot, `TRS80/CMD/`, streamed into the FIFO | the congress-table case: no laptop, no network |
| Host | the debug UART (`dbg_uart`) / trszog | the debugger loads binaries anyway |
| ESP32 | its link to the FPGA, bytes from WiFi/HTTP | ADR-0008's *provider* role, never a second SD master |

The stub and the FIFO attach to the **internal** core in Mode 1 as well, so the loader is
golden-tested against tv80 in simulation before it touches silicon.

### 4. Loading paths considered and not chosen

- **CLOAD from a virtual tape.** `m1_cass_sd` already generates the 500-baud waveform; an
  output stage and a DIN cable to the cassette jack would make the FPGA a tape deck for the
  real machine. 16 K takes ~5 minutes. Not a loader, but a **later verification target**
  for the real cassette front end (Z4 comparator, the XRX issue) against our model.
- **Poking RAM via TEST\* bus mastering.** While the Z80 is off the bus nobody refreshes the
  keyboard unit's 4116s (bursts < 2 ms, or the dongle refreshes itself), and whether RAS\*,
  CAS\* and MUX may be driven from the edge under TEST\* is unverified. This is Phase-1
  debugger territory (write memory while halted), not the way to load programs.

### 5. Staging (replaces INTERPOSER-PLAN §8)

1. Perfboard interposer, observe-only — live bus of a real Model 1 in the trszog panel.
2. **Mode 3 loader:** window + mailbox + stub; `SYSTEM /12288` loads a /CMD from the SD slot
   into the real 16 K. This is the complete dongle-only test: opcode fetches from the window
   are the shortest cycles the machine has; the mailbox exercises read side effects; the
   load exercises write capture; the stub arms IM 2.
3. **Mode 2:** bus front end + mux; the EI container serves the real machine; `MEMORY SIZE?`
   answers 48 K; a DOS boots from DMK.
4. Debugger backend for the real Z80 (ADR-0009 Phase 0 → 1): INT\* entry, then TEST\*/WAIT\*.
5. KiCad board, boxed, for the congress.

## What is *not* an extraction

`m1_debug` controls tv80 through `freeze`, instruction stuffing and byte feeding. A real Z80
has none of those handles. The host protocol, `dbg_uart` and trszog stay; the debug core
needs a **second backend** (bus observation, then TEST\*/WAIT\*). Memory views of
0x8000–0xFFFF come for free in Mode 2 because that RAM is in the FPGA; 0x4000–0x7FFF need
bus mastery. This was always ADR-0009's content and remains the larger piece of work.

## Consequences

- The interposer as drafted (five 74LVC245, `data_drv_n`, open-drain INT\*/TEST\*/WAIT\*)
  needs **no hardware change** for any of the three modes.
- INTERPOSER-PLAN §8/§10 are revised accordingly; RESEARCH.md §5 records the decoder
  argument.
- The 40C3 showcase is: the same EI RTL driving silicon and FPGA side by side on the
  oscilloscope, a breakpoint in the real Level II ROM, and a repository where every
  divergence is logged.

## Open

- **ROM listing check:** what bare Level II BASIC does on INT\* — interrupt mode after reset
  and the contents of the RAM vector at 0x4012. Decides whether INT\* entry works *before*
  the stub has run once, or only after `SYSTEM /12288` armed IM 2.
- The asynchronous-bus testbench (`tb_m1_extbus`, name provisional) and its scope
  confirmation.
- The remaining VERIFY items in INTERPOSER-PLAN §10 (ULX3S header geometry, edge keying,
  connector part, LPF include).

## Sources

- `rtl/m1_addr_decode.v` header (TRS-80 Technical Manual 1978, pp. 8–11; RetroStack Rev G
  `AddressDecoder.kicad_sch`); `rtl/m1_ei.v`, `rtl/m1_ei_ram.v`, `rtl/m1_fdc.v`,
  `rtl/m1_core.v` port lists as of 2026-10-25.
- Technical Reference Handbook (1982) p. 91 — the 40-pin edge; EI Service Manuals (1979,
  redesigned) — see RESEARCH.md §5, 2026-10-24.
- ADR-0005 (bus idiom, EI container), ADR-0006 (IM-2 vector trick, window at I = 0x30),
  ADR-0008 (ESP32 as provider, FPGA sole SD master), ADR-0009 (phases, electricals).
- /CMD load-module record format: LDOS/TRSDOS programmer documentation (types 01/02/05).
