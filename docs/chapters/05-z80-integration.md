# Chapter 5 — The Z80 Joins the Chain: A Brain for the Machine

*Sources: TRS-80 Technical Manual (Theory/Parts/Schematics, 1978), "The CPU",
"CPU Control Group" (RD\*/WR\*/IN\*/OUT\*), "Data Bus Access Control"
(DBIN\*/DBOUT\*, TEST\*), "MUX, CAS\*, RAS\*" (pp. 8, 174–179, 187–199, 265–295)
and Schematic Sheet 1; the Level-II wiring is cross-checked pin by pin against
RetroStack's Rev G KiCad recreation (`CPU.kicad_sch`, `ROM.kicad_sch`,
`RAM.kicad_sch`, `RAM_ROM_Interface.kicad_sch`), extracted with
[`tools/kicad_nets.py`](../../tools/kicad_nets.py). The Z80 itself is the
vendored **tv80** core — see
[ADR-0003](../decisions/0003-z80-core-selection.md). RTL:
[`rtl/m1_cpu.v`](../../rtl/m1_cpu.v) (wrapper + strobes),
[`rtl/m1_rom.v`](../../rtl/m1_rom.v), [`rtl/m1_ram.v`](../../rtl/m1_ram.v);
testbench: [`sim/tb_m1_cpu.sv`](../../sim/tb_m1_cpu.sv).*

Four chapters built a display that renders whatever sits in the video RAM.
Nobody has been *writing* that RAM except a testbench pretending to be a CPU.
This chapter retires the pretender: a real Z80 fetches instructions from ROM,
computes, and pokes the screen — and the picture at the end of the run is drawn
by a program, not by the bench.

## 1. Whose Z80? (and why we didn't write one)

Writing a cycle-accurate Z80 is a project, not a chapter. The pinned decision
(ADR-0003) is to vendor **tv80** — Guy Hutchison's MIT-licensed Verilog port of
the same Daniel Wallner T80 core that PACE, big80 and the MiSTer core all build
on. Three things earned it the slot: it is *Verilog*, so it drops into the
single-simulator `-Wall` regime the whole project lives in (the VHDL T80 would
force a mixed-language flow); its own regression suite runs on Cocotb +
Verilator, i.e. against our exact simulator; and `tv80_core` has a clock-enable
input that lands precisely on our single-clock-domain/enable discipline
([ADR-0001](../decisions/0001-synchronous-model-of-ripple-counters.md)).

The core is vendored unmodified under `rtl/vendor/tv80/`, with the upstream
license, a provenance README, and a **scoped** Verilator waiver file — the
second documented lint carve-out after the font ROM. tv80 predates lint-clean
style and emits ~990 warnings (962 of them "blocking assignment in sequential
logic"); the waiver silences them *for the vendored files only*. Every
first-party module stays fully `-Wall` clean. The boundary is the same one the
whole project keeps: foreign material lives in a named quarantine with a
documented exception, never eroding the rule for our own code.

We do **not** use tv80's stock `tv80s` wrapper — it hard-wires the clock enable
to 1. Our wrapper (`m1_cpu.v`) instantiates the bare `tv80_core` with `cen`
driven by the 1.77408 MHz enable from chapter 1, and around it builds the part
that is actually Model-1 specific: the control-signal layer.

## 2. The control-signal layer (Z23, the "backward" OR gates)

A Z80 announces what it wants with four active-low pins: ~MREQ, ~IORQ, ~RD, ~WR.
The Model 1 turns those into the five strobes the rest of the board understands,
with one 74LS32 (Z23) whose gates the manual describes as *"drawn backward"* —
they're OR gates, but with active-low inputs they behave as ANDs of the live
signals:

| Strobe | gate | fires when |
|---|---|---|
| RD\* | Z23b = ~MREQ ∨ ~RD | memory **read** |
| WR\* | Z23d = ~MREQ ∨ ~WR | memory **write** |
| IN\* | Z23c = ~IORQ ∨ ~RD | port **read** (cassette load, EI in) |
| OUT\* | Z23a = ~IORQ ∨ ~WR | port **write** (cassette save, EI out) |
| RAS\* | Z72d buffer of ~MREQ | *every* memory cycle, incl. refresh |

RAS\* being *"the same signal"* as ~MREQ is the load-bearing fact chapter 4
already leaned on: the decoder only wakes on memory cycles because its strobe is
this line, and dynamic RAM gets refreshed on RAS-only cycles because ~MREQ still
drops during the Z80's refresh T-states. The bench counts those refresh pulses
and there are thousands of them — the R register is live (`+define+TV80_REFRESH`).

The Z80 pins themselves are reconstructed from tv80's M-cycle/T-state outputs
exactly as upstream's `tv80s` does it — but advanced only on the CPU enable, so
each strobe level holds for a whole 1.77408 MHz T-state. This is the one honest
seam between a T-state-accurate core and a dot-accurate board (§6).

## 3. Which direction is the data bus? (Z53, and the TEST\* escape hatch)

The data bus has buffers pointing both ways (Z75/Z76 out, Z55/Z76 in), wired
*"head to toe"* — turn both on at once and they fight. One 74LS132 gate (Z53b)
decides: its output DBOUT\* is low exactly when the CPU should drive the bus
(during a write, ~RD high), and DBIN\* (Z53c) is its complement. Exactly one
direction is ever open. In the RTL these become `dbout_n`/`dbin_n` plus the
`dout` value — the same value+enable idiom chapter 3 used for the video RAM's
tri-states, and the bench asserts the two are always complementary and that the
CPU never drives the bus during its own read.

Z53 also carries **TEST\***: ground it (an external master, or the factory test
jig) and the address buffers tri-state (`addr_en` falls) while the data
direction is forced — the Expansion Interface's way of taking the bus. Here
TEST\* also feeds the Z80's ~BUSRQ directly. The bench holds it high; the escape
hatch is modeled and contract-checked, exercised for real in M3.

## 4. Reset and the HALT trick (Z53a, Z37, the NMI path)

Two resets exist. Power-on (an R/C network, here `por_rst_n`) drives the Z80's
~RESET — the cold start at 0x0000. The front-panel button is *not* wired to
~RESET; it drives ~NMI through Z53a, so it warm-starts at 0x0066. And there is a
genuinely sly bit of hardware: the button gate is NANDed with ~HALT, so **a HALT
instruction triggers its own NMI**. Execute `HALT` and the CPU immediately wakes
at 0x0066 — the machine has no idle state, it has a trampoline. SYSRES\* to the
card edge is the NOR of the two reset sources (Z37a), so a halted CPU also
asserts system reset outward.

The test program uses exactly this: it ends with `HALT`, and the code at 0x0066
writes a marker into the last screen cell. The bench refuses to see that fetch
at 0x0066 unless a HALT genuinely happened first.

## 5. ROM and RAM, and the rule about ROMs

`m1_rom.v` is Z33 (8 K) + Z34 (4 K) as one 12 KiB array behind the ROMA\*/ROMB\*
selects; `m1_ram.v` is the eight 4116s as 16 KiB behind RAM\*. Both expose read
data as value + `dout_en` gated by MEM\* (chapter 4's read-buffer enable), and
the bench's data bus picks exactly one driver each cycle — CPU, ROM, RAM, or
video RAM — and fails on any overlap.

**No ROM ships in this repository** (`roms/README.md`). The ROM array powers up
blank and is filled at runtime through a loader port — the very port the board's
SD/ESP32 loader will drive at milestone M1. In simulation the testbench plays
the loader, streaming in an image built by
[`sim/tools/build_test_image.py`](../../sim/tools/build_test_image.py) — this
project's *own* hand-assembled Z80, not a byte of Tandy code. The RAM omits the
row/column multiplexing and refresh of real DRAM: FPGA block RAM neither
multiplexes nor forgets, and the bus-visible contract (RAS\*/CAS\*/MUX are still
generated, for the waveforms) is unchanged. That MUX→CAS\* sequence (Z69/Z70,
one dot apart after RAS\*) is modeled too, so the DRAM timing chapter's picture
is already on the wire even though our memory doesn't consume it.

## 6. The one seam: T-states vs. dots

Everything upstream of this chapter is dot-accurate (10.6445 MHz). tv80 is
T-state-accurate (1.77408 MHz). The strobes therefore switch on T-state
boundaries; the real Z80 switches on falling clock edges, up to half a T-state
(3 dots) off. Why the video proof survives this intact: chapter 3 established
that CPU access to the video RAM only *darkens* pixels and only in a window
around the access — the streak is subtractive and local. A 3-dot shift in when
the strobe lands moves a streak by at most a few dots; it can never light a
wrong pixel or reach across the screen. The property SPEC §6 demands — snow
appears where hardware shows it, beam-synced code works without dedicated
support — is a property of *where* access lands in the scan, and that is still
governed by the dot-accurate video timing, not by the core's sub-T-state edges.
Byte-exact VRAM comparison against the golden model (§8) is exactly the
instrument that would catch it if this reasoning were wrong.

## 7. The signal contract (what the RTL exports)

| Signal | Meaning | Hardware origin |
|---|---|---|
| `addr[15:0]`, `addr_en` | address bus + buffer enable | Z40 / Z38/Z39 (ENABLE\*) |
| `dout`, `dbout_n`, `dbin_n` | data out + bus direction | Z75/Z76 / Z53b/c |
| `ras_n` | memory cycle (buffered ~MREQ) | Z72d |
| `rd_n`, `wr_n` | memory read / write strobes | Z23b / Z23d |
| `in_n`, `out_n` | port read / write strobes | Z23c / Z23a |
| `intak_n` | interrupt acknowledge | Z73a |
| `sysres_n` | system reset to card edge | Z37a |
| `mux`, `cas_n` | DRAM row/column sequencing | Z69b / Z70 |
| `m1_n`, `halt_n`, `busak_n` | CPU status (observability) | Z40 |

The reset/NMI network takes `por_rst_n`, `reset_btn_n`, `test_n`; interrupts and
`wait_n` come from the card edge.

## 8. What the testbench proves (and how to watch it)

`sim/tb_m1_cpu.sv` wires the whole machine — clock, CPU, decoder, ROM, RAM, and
the chapters 1–3 video chain — on a shared data bus, loads the test image at
runtime, and lets the Z80 run this program:

> clear the screen with `LDIR` through video RAM · copy a 16-char banner to line
> 0 · checksum the banner in an 8-bit `DJNZ` loop, store it in RAM and print it
> as two pseudo-hex digits via a `CALL`/`RET` subroutine with `PUSH`/`POP` ·
> double 0x1234 twice with `ADD HL,HL` into RAM · `OUT (0FFh),A` to the cassette
> latch · `HALT` → NMI → 0x0066 writes a done-marker to the last cell and spins.

Every dot clock, continuous invariants hold: at most one of RD\*/WR\*/IN\*/OUT\*
active, DBIN\* the exact complement of DBOUT\*, the CPU never driving the bus
during its own read, exactly one of {CPU, ROM, RAM, VRAM} driving the bus, no
read strobe on unmapped space, CAS\* never outside RAS\* on a memory cycle,
INTAK\* silent while interrupts are off. After the run it checks the *results*
straight from the arrays: the RAM holds the right checksum and `48D0h`; the video
RAM holds the banner, blanks, the two digits, and the marker (`0xBF`) — proof the
NMI trampoline fired. Then it dumps the CPU-read form of VRAM
(`build/vram_cpu.bin`, 1 KiB) for the golden comparison and renders the screen.

`cd sim && make` runs it; `make frames` writes **`build/frame_cpu.png`** — the
fourth picture of the project, and the first the machine drew *itself*:
`TRS-80 REV Z  OK` over `>?` (the banner checksum, 0xEF, as digits). `make
wave-cpu` opens the trace; the instruction stream on the address bus and the
strobe fan-out are the things to watch.

## 9. The golden-model check (SPEC §6, closed)

The bench dumps VRAM in the CPU-read form (`build/vram_cpu.bin`); the same test
image runs on **trs80gp** (George Phillips' reference Model 1 emulator), whose
`-it` text-VRAM dump is already in that form. `make golden` runs both and
compares byte for byte:

> **`MATCH  1024/1024 cells byte-exact`**

All 1024 cells agree — banner, blanks, the two checksum digits, the 16-bit
arithmetic side effects, and the marker at cell 1023. That last one is the
sharp result: cell 1023 only becomes `0xBF` if the `HALT` triggered an NMI and
the 0x0066 handler ran. trs80gp models the Model 1's HALT→NMI board trick, our
RTL reproduces it, and they land on the same byte. This is the SPEC §6
milestone: verification is byte-exact memory comparison, not a look at the
screen.

One trs80gp gotcha worth recording: a custom `-rom` on Model 1 needs **`-dx`**
(disable the FDC, boot into ROM). Without it the emulator waits for a disk and
never runs the automation loop — it exits cleanly having produced nothing,
which looks like a silent failure. The exact command is in `sim/Makefile`'s
`golden` target; trs80gp is external (macOS app), so `TRS80GP=` points the
target at the binary.

## 10. Open items

- [x] **Golden-model VRAM comparison — closed.** `make golden`, byte-exact.
- [ ] **Cycle-accuracy caveat.** tv80 reproduces documented instruction timing,
      not gate-level Z80 behavior; undocumented flags and interrupt corner cases
      have historically carried bugs in this family. The golden comparison is
      the instrument that will surface any such deviation as a byte diff; the
      fallback is to patch behind the unchanged wrapper interface, or swap cores.
- [ ] **I/O ports.** `OUT (0FFh)` currently only fires the strobe; the port-0xFF
      latch (cassette out + MODESEL, chapter 1's open item) and the IN\* read
      path are the I/O chapter.
- [ ] **INT\* / interrupt mode.** The EI's 40 Hz heartbeat and IM 1 servicing
      arrive with the Expansion Interface (M3); INTAK\*/Z73a is wired and
      contract-checked but never exercised here.
