# The Toolchain — from Verilog to a running chip

*How `make bit` and `make prog` turn the `.v` files into a TRS-80 on the
Lattice ECP5. Short version; each section links to the authoritative docs.*

**Try it yourself.** The left branch below needs no board: `cd sim && make`
runs every testbench, `make golden` re-runs the byte-exact VRAM comparison
against trs80gp, `make frames` renders PNG frame dumps. The right branch
(`cd boards/ulx3s && make bit && make prog`) needs a ULX3S-85F. A build
that breaks on your toolchain versions, or a golden that diverges, is
exactly the kind of issue worth opening.

Two separate pipelines start from the same RTL:

```
                 ┌── Verilator ──────────────► C++ simulation (sim/, TBs, goldens)
  rtl/*.v ───────┤
                 └── yosys ──► netlist (JSON)
                        nextpnr-ecp5 ──► placed & routed design (.config)
                              ecppack ──► bitstream (.bit)
                        openFPGALoader ──► ECP5 configuration SRAM
```

The left branch never touches hardware; the right branch never verifies
anything (repo rule: *synthesis is not verification*).

## 1. Synthesis — yosys

`yosys` reads the Verilog and **compiles it into a circuit description**:
first into generic logic (adders, muxes, registers), then *technology
mapping* rewrites that into the primitives the ECP5 actually has — 4-input
lookup tables (LUT4), flip-flops, carry chains, 18 kbit block RAMs
(`DP16KD` — our ROM/RAM/VRAM/track buffer), and 18×18 multipliers. The
result is a **netlist**: a parts list plus wiring — which LUT computes
which truth table, which output feeds which input. "Virtual circuit" is
exactly right: at this point the design has components and connections
but **no locations** yet. That's `build/ulx3s_top.json`.

- Yosys manual: <https://yosyshq.readthedocs.io/projects/yosys/>
- The classic intro talk (Claire Wolf, 32C3, the birth of the open
  FPGA flow): <https://media.ccc.de/v/32c3-7139-a_free_and_open_source_verilog-to-bitstream_flow_for_ice40_fpgas>

## 2. Place & Route — nextpnr-ecp5

`nextpnr` takes the location-free netlist and the pin constraints
(`ulx3s_v20.lpf`, which says "signal `sd_clk` lives on ball H2") and does
two jobs: **place** — assign every LUT/FF/BRAM to one concrete physical
site on the LFE5U-85F die — and **route** — connect them through the
chip's prefabricated wiring grid by setting routing switches. Afterwards
it runs **static timing analysis**: the longest signal path between two
flip-flops determines the maximum clock rate; the `Max frequency ...
PASS` lines mean every path is faster than the clock we demand. A design
that fails timing *may* still run — sometimes, at some temperature. We
don't ship those.

- nextpnr: <https://github.com/YosysHQ/nextpnr>
- Project Trellis — the reverse-engineered, fully documented ECP5
  bitstream/fabric database nextpnr builds on:
  <https://prjtrellis.readthedocs.io/>

## 3. Bitstream — ecppack

The placed-and-routed design is still a text description. `ecppack`
serializes it into the **configuration bitstream**: one long bit string
that contains, literally, every LUT's truth table, every routing switch
position, every BRAM's initial contents (our font, the self-test image),
every I/O pad's mode. That's `build/ulx3s_top.bit` — not a program, but
a *wiring plan* in binary.

- Bitstream format details: the Trellis docs above; ECP5 sysCONFIG
  usage guide (Lattice FPGA-TN-02039) via
  <https://www.latticesemi.com/Products/FPGAandCPLD/ECP5>

## 4. Loading — openFPGALoader

`make prog` sends the bitstream over USB/JTAG into the ECP5's
**configuration SRAM**. The chip's fabric latches every bit into the
cell it configures — from that instant the LUTs *are* our gates. SRAM is
volatile: power-cycle and it's gone (that's fine for development).
`openFPGALoader -b ulx3s -f build/ulx3s_top.bit` writes the on-board SPI
flash instead; the ECP5 then configures itself from flash at every
power-up — the "finished device" mode.

- openFPGALoader: <https://trabucayre.github.io/openFPGALoader/>

## 5. What "it's on the chip" actually means

Nothing executes the bitstream. After configuration there is no
interpreter, no CPU running our design — the design **is the hardware**:
a few thousand LUTs whose truth tables happen to compute a Z80, a video
timing chain and a floppy controller, all switching in parallel on every
edge of the 10.6445 MHz clock from the on-chip PLL. Reconfigure, and the
same silicon is a different machine. That's the whole FPGA idea: a chip
whose circuit is data.

- ECP5 family page (datasheet, memory/PLL/sysCONFIG usage guides):
  <https://www.latticesemi.com/Products/FPGAandCPLD/ECP5>
- ULX3S board docs (pinout, peripherals):
  <https://ulx3s.github.io/>

## 6. The other branch — Verilator

`verilator` compiles the same RTL into C++ and runs it as a program:
that's every testbench and golden compare in `sim/`. Fast, cycle-based,
and completely ignorant of LUTs and timing — which is why both branches
exist and neither replaces the other.

- Verilator guide: <https://verilator.org/guide/latest/>

## Wanting more

- Shawn Hymel's *Intro to FPGA* video series (Digi-Key) — the same
  flow, end to end:
  <https://www.youtube.com/playlist?list=PLEBQazB0HUyT1WmMONxRZn9NmQ_9CIKhb>
- nandland — bite-sized FPGA/Verilog fundamentals:
  <https://nandland.com/>
- The F4PGA/open-tools ecosystem overview: <https://f4pga.org/>
