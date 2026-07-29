# Chapter 8 — The Machine, Composed (and It Synthesizes)

*RTL: [`rtl/m1_core.v`](../../rtl/m1_core.v); exercised by the full-system
testbench [`sim/tb_m1_cpu.sv`](../../sim/tb_m1_cpu.sv) and synthesized with
`make synth`.*

Seven chapters built and verified seven blocks. This one puts them in a box.

## 1. From testbench wiring to real RTL

Through chapters 5–7 the interconnect — the shared data bus, the module
instantiations, the mux that decides who drives the bus each cycle — lived
inside `tb_m1_cpu.sv`. That is fine for proving the machine works, but a
testbench is not something you can put on an FPGA. `m1_core.v` promotes exactly
that wiring into synthesizable RTL: one module that instantiates the clock
divider, the Z80 (tv80), the address decoder, ROM, RAM, video RAM, the port-0xFF
register, the keyboard matrix, and the video chain, and connects them on one
data bus.

The bus is the only interesting part. Inside an FPGA there is no tri-state
backplane, so `m1_core` does what every FPGA design does: each source exports
`(value, enable)` and the module selects.

```
bus = !dbout_n ? cpu_dout    // CPU driving (write)
    : rom_en   ? rom_dout
    : ram_en   ? ram_dout
    : vram_en  ? vram_dout
    : kb_en    ? kb_dout
    : io_en    ? io_dout
    :            8'hFF;       // open bus
```

Exactly one source is enabled per cycle — the continuous invariant the
full-system bench has been asserting since chapter 5 (`$onehot0` over the
enables). The default `0xFF` is the level a real machine floats to on open bus.

## 2. The external surface

`m1_core` exposes the seams a board top-level connects:

| Group | Signals | Connects to (on hardware) |
|---|---|---|
| clock/reset | `clk`, `por_rst_n`, `reset_btn_n`, `test_n`, `int_n`, `wait_n` | board oscillator + buttons |
| ROM loader | `ld_en`, `ld_addr`, `ld_data` | SD / ESP32 (ROM never bundled) |
| keyboard | `keys[63:0]` | USB-HID or real matrix (chapter 7) |
| cassette | `cass_in`, `cass_out[1:0]`, `cass_motor` | audio front end (M2) |
| video | `pixel`, `hdrv`, `vdrv`, `dot_en`, `modesel`, `col/line/row` | HDMI / composite stage |
| debug | `addr`, `m1_n`, `halt_n`, `cpu_cen` | logic analyzer / LEDs |

The testbench now drives this surface and observes internals hierarchically
(`u_core.rd_n`, `u_core.u_ram.mem`, …) — same golden test, same
`MATCH 1024/1024`, just one level of hierarchy deeper. Refactor with the proof
still green: the machine did not change, only its packaging.

## 3. It synthesizes (`make synth`)

`make synth` runs the whole core through yosys `synth_ecp5` — the ULX3S target.
It elaborates with **0 problems** and maps to roughly:

- ~19.6k LUT4, ~300 FF, ~3.7k distributed-RAM cells, ~50 carry chains

on the LFE5U-85F (84k LUTs) — comfortable headroom. This is an *implementability*
check, not verification: "it synthesizes" is explicitly not proof of correctness
(that is `make` + `make golden`). It tells us the verified RTL maps to the real
part and roughly how big it is.

One honest caveat the numbers exposed at first: ROM, RAM, VRAM and the font
table initially inferred as **distributed** RAM (the 3.7k LUTRAM cells), not
the ECP5's block RAM (EBR). That worked but was wasteful — fixed in §5.

## 4. It routes and closes timing (`make pnr`)

`make pnr` continues from the yosys netlist through nextpnr-ecp5 (LFE5U-85F,
ULX3S pinout class). The design places, routes, and closes timing with wide
margin at the 10.6445 MHz dot clock. Numbers below are *after* the EBR
conversion of §5.

## 5. Memory → EBR

The four memory arrays read combinationally (`assign dout = mem[a]`), which
forces LUTRAM: ECP5 block RAM has a registered read port, so yosys can only
infer EBR when the RTL reads through a register. The fix is one registered
read per array (m1_rom, m1_ram, m1_vram, and the chargen table in
m1_video_gen), each documented as a deliberate deviation in the module header.

Why one clock of read latency changes no observable behavior:

- **Video side (VRAM + chargen):** the counter chain holds a cell's address
  stable for a full character time (six dots) before LATCH* samples, and the
  latched LB/line address is likewise stable for the whole next cell before
  the shift registers load. One dot of latency into a six-dot window moves
  nothing on the dot grid.
- **CPU side (ROM/RAM/VRAM reads):** every bus read strobe spans several dot
  clocks and tv80 samples late in the machine cycle; data arriving one dot
  clock into the strobe is indistinguishable on the bus contract.

The proof, as always, is not the argument but the runs: all seven testbenches
stayed green **unchanged**, `make golden` stayed byte-exact (1024/1024), and
`make pnr` now reports:

| | LUTRAM (before) | EBR (after) |
|---|---|---|
| DP16KD | 0 | **16 / 208 (7%)** |
| logic (TRELLIS_COMB) | 42,071 (50%) | **2,815 (3%)** |
| FF | 302 | 336 |
| Fmax | 34.82 MHz | **63.24 MHz** (PASS at 10.64 MHz) |

The 16 EBRs are exactly the expected budget: RAM 16K×8 = 8, ROM 12K×8 = 6,
VRAM 1K×7 = 1, font 1K×5 = 1. The machine now occupies 3% of the part.

## 6. Open items

- [x] **Memory → EBR.** Registered reads; DP16KD inferred; testbenches and
      golden unchanged and green (this chapter, §5).
- [x] **place & route + timing.** `make pnr` closes timing at 10.6445 MHz with
      ~6× margin (§4/§5).
- [ ] **The board top-level.** `m1_core` is the reusable machine; a per-board
      wrapper adds the oscillator/PLL, the ROM loader (SD/ESP32), the USB-HID →
      `keys` front end, the HDMI/composite stage, and pin constraints. That
      wrapper is the ULX3S bring-up — the first hardware milestone.
