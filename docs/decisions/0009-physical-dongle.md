# ADR-0009 — Physical debug dongle: form factors, electricals, connectivity

**Status:** proposed · **Vision tier — exploratory, no commitment, no dates** · 2026-07-28

## Context

[ADR-0006](0006-debug-architecture.md) established the debug *mechanism* and
promised "the road to a dongle that debugs a **real** TRS-80 over a ribbon
cable." This record opens that road as a **physical-realization** side-strand:
how the dongle is actually built — as a cable to the ULX3S, and as a standalone
board — and what it costs in chips, level-shifting, and connectivity. **The bus
mechanism is ADR-0006's; nothing here changes it.** The protocol is
[DEBUG-PROTOCOL.md](../DEBUG-PROTOCOL.md)'s two layers; the debugger integration
is [ADR-0007](0007-trszog-integration.md)'s `revz` remote; the network/server
split is [ADR-0008](0008-esp32-companion.md)'s ESP32.

### The electrical reality (the one non-negotiable)

- **Attach point (per ADR-0006):** the Expansion Interface passes the full Z80
  bus 1:1 at its **"Screen Printer Bus" card edge (J3)**, including **TEST\*** and
  **WAIT\*** — but **NMI\*, M1\*, CLK, and BUSRQ\*/BUSAK\* are *not* present at the
  edge** (EI Service Manual 1979 sheet 3; Technical Reference Handbook 1982
  p. 91). So the dongle **gains the bus via TEST\*** (not a Z80 DMA request),
  **enters debug via INT\* + an IM-2 vector** (not NMI), and must work **without
  M1\*/CLK at the edge** — which shapes how breakpoint-on-fetch is realized (see
  ADR-0006). An EI-less keyboard unit exposes the bus at its own 40-pin
  expansion edge instead; pinout/pitch to verify against the service manual
  before ordering connectors.
- **5 V vs 3.3 V — the hard constraint.** The TRS-80 bus is **5 V TTL**; every
  candidate FPGA (ECP5, GateMate, iCE40) is **3.3 V and *not* 5 V-tolerant**. **A
  bare ribbon cable would risk the FPGA.** Every variant therefore needs
  **bidirectional level shifting** — 74LVC245 banks with direction gated by the
  bus-master state (observe → inputs to the FPGA; master → outputs), roughly
  **4–6 shifter ICs** for A0–A15 / D0–D7 / the control strobes. This is the part
  that turns "just a cable" into "a small board."

## Two form factors

### A) Cabled interposer → ULX3S  *(Phase 0 — cheap, do first)*

A 40-pin IDC ribbon from the EI J3 card edge to a **small 2-layer level-shifter
interposer PCB** that lands on the ULX3S GPIO. The **ULX3S is the dongle brain**
— it already runs `m1_debug`. This proves the real-bus mechanism on real silicon
**before any custom product exists**. Off-the-shelf ribbon + IDC; the only
sourcing pain is the **40-pin 0.1″ card-edge connector** for the TRS-80 side
(Sullins / salvage). Answer to "can I get such a cable made?": yes — but as a
tiny interposer board (KiCad → JLCPCB), not a naked cable, because of the level
shifting above.

### B) Standalone dongle board  *(Phase 1 — the product)*

A KiCad board carrying:

- **A small FPGA** (debug logic + comparators, optional soft RISC-V). The debug
  core *alone* measured ~1.1–2k LUT4 + ~700 FF (`m1_debug` synth, 2026-07-28) —
  a fraction of the whole machine (which was ~13 % of a GateMate A1). Candidates:
  - **GOWIN GW1NR-9 / Sipeed Tang Nano 9K** — **cheapest** (~$10–15 as a full
    board), and the **open flow already exists** (Project Apicula + yosys +
    nextpnr + openFPGALoader — the "Trellis for GOWIN"). 8640 LUT4 / 6480 FF /
    468K BSRAM **and 64 Mbit on-chip SDRAM** → 4–5× headroom over the debug core
    even with a soft RISC-V, and the SDRAM is exactly what the **flight recorder**
    wants (a capability the iCE40 lacks). Could even **replace the ULX3S as the
    Phase-0 brain**. *Caveats:* still needs the ESP32 (no WiFi/LAN) and level
    shifters (3.3 V); **GPIO budget on the small board is the thing to verify
    before buying** (HDMI/SDRAM/LCD consume pins; the 40-pin bus needs ~30). As a
    bare QN88 chip on a Phase-1 board, IO is ample. *Off the sovereignty message*
    (Chinese vendor) — great for a cheap functional dongle, not for the EU-demo.
  - **iCE40UP5K** — tiny, cheap, most battle-tested open flow (icestorm); ample
    for the debug core alone, but only 5280 LUT4 and **no SDRAM** (no flight
    recorder). Simplest bare chip to lay out.
  - **GateMate A1** — the **sovereignty** tie-in (EU chip, open flow), fit already
    proven with enormous headroom; room for a soft RISC-V + flight-recorder on
    the dongle if wanted. Makes *the dongle itself* the portability/EU demo — the
    on-message counterpart to the GOWIN's cheap-and-capable.
  - **ECP5-12F** — maximum code reuse with the ULX3S board top.

  `rtl/` is board-agnostic, so **more than one dongle chip can be supported at
  once** (GOWIN = cheap/capable, GateMate = sovereignty showcase) — each is just
  another board wrapper. Pick per goal, not one-size-fits-all.
- **ESP32-S3** — **WiFi *and* native USB in one cheap chip**, running the Layer-2
  **JSON-RPC server** (the ported `tools/trszog_bridge.py`, per ADR-0008). This
  is the "CPU," so a **soft RISC-V in the FPGA is *optional*** — needed only for
  on-dongle trace/flight-recorder work, **not** for basic debugging.
- **Level shifters** (74LVC245 × ~4–6), the **40-pin edge connector**, and
  **self-power via USB-C** — do *not* run the FPGA off the retro +5 V rail
  (noise/risk); share ground, and **sense SYSRES\*/power** to drive the
  target-reset-detection the core already implements.
- **Optional:** an **SD slot** (RAM-resident disk-image library / snapshots), and
  a **W5500 SPI-Ethernet** for **wired/lab use** — which matters for the
  industrial-showcase angle (labs want Ethernet, not WiFi).

### "Do we build a real retro-style circuit?" — No.

The debug core is thousands of stateful gates; it is an **FPGA design**, not
something to reproduce in discrete 74-series logic. The board can be **styled**
retro (grey, silkscreen, a "Cat. No." plate) — but functionally it is a **modern
small-FPGA + ESP32 board**. Aesthetic is skin; the guts are FPGA + MCU. That is
the honest answer, and it's the right one.

## How it reaches DeZog

**No new protocol.** The dongle is simply another **transport** on the existing
`revz` remote (ADR-0007's four axes): `target = physical`, `dongle = physical`,
`transport = esp32 | lan | serial`. Same two-layer contract — Layer 1 binary v0
on the FPGA, Layer 2 JSON-RPC on the ESP32 — so it appears to DeZog as **another
target**, alongside the FPGA machine and trs80gp.

## Staging (the sane path)

1. **Phase 0:** interposer + ribbon → ULX3S. Prove real-TRS-80 debugging over the
   bus, reusing hardware. Cheapest possible validation of the mechanism.
2. **Phase 1:** spin the standalone board once Phase 0 works. **Do not** commit a
   custom PCB before the real-bus debug is proven on reused hardware.

## Pin budget (Tang Nano 9K, ~32 free GPIO) — fits, but on the edge

Post-level-shifter, the FPGA needs: A0–A15 (16) + D0–D7 (8) + RD\*/WR\* (2) +
TEST\* out (1) + INT\* out, IM-2 entry (1) + SYSRES\* sense (1) = **29 bus pins**;
plus 1 shifter-DIR line (the rest of the 74LVC245 direction is derived
combinationally *on the interposer*, not from FPGA pins) and 2 for the ESP32
UART = **~32 total**. That **fits the Tang Nano 9K's ~32 free GPIO with zero
margin.** Adding real-hardware I/O watchpoints (IN\*/OUT\*, +2), WAIT\* (+1), or
SPI-to-ESP32 (+2) pushes to ~35 → **Tang Nano 20K** (~34 free, SDRAM + OTG) or
**Tang Primer 20K** (>50 free) for headroom. **Conclusion:** the 9K is viable for
a minimal tethered dongle; a *product* board should budget for the Primer-class
IO or a bare GW1NR-9/GW2A on a custom PCB.

**Tethered vs wireless (maps to ADR-0007's `transport` axis):** the Tang Nano's
onboard **BL702 already provides USB-C UART**, so the *tethered* case may need
**no ESP32 at all** — the debug protocol rides the existing USB-C serial;
the **ESP32-C3** (e.g. XIAO, UART, ~2 pins) is added only for **wireless**.
Verify against the board's BL702↔FPGA UART routing.

## Consequences & open questions

- Verify J3 vs keyboard-unit edge **pinout/pitch** from the service manuals
  before ordering the 40-pin card-edge connector.
- Bus-master timing **without CLK/M1\* at the edge** — how far ADR-0006's
  fetch-breakpoint approach carries; may need cycle inference from the strobes.
- **Model scope:** the 40-pin bus + EI J3 is **Model 1**; Model 3/4 have
  different buses → a per-model connector adapter over shared debug logic
  (ADR-0006 stages M1 first).
- **Chip choice** (iCE40 vs GateMate A1 vs ECP5-12) trades sovereignty narrative
  vs assembly ease vs code reuse — decide at Phase 1.
- Manufacturing: KiCad → JLCPCB/PCBWay (assembly for the FPGA + ESP32 module +
  passives); the interposer is a trivial cheap 2-layer board.

*Exploratory by design: this exists so the "real dongle" in ADR-0006 §3a has a
concrete physical sketch, and so the side-strand can be resumed later without
re-deriving it. Nothing here is committed.*
