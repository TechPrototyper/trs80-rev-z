# ADR-0006 — Debug architecture: core, protocol, and the road to real hardware

**Status:** proposed · 2026-07-25

## Context

The base system is complete: the machine boots TRSDOS from SD on the ULX3S,
all stages golden-verified (chapters 1–8, EI stages 0–6). The next committed
vision item is a debug core with editor integration — a debugger that can
hold, inspect, and steer this machine the way an ICE held a real Z80.

Three assets shape the decision:

1. **trszog** ([TechPrototyper/trszog](https://github.com/TechPrototyper/trszog),
   a DeZog fork) already debugs TRS-80 programs in VS Code against a
   debug-enabled trs80gp over a small JSON-RPC protocol; symbol handling
   (zmac `.bds`) works. The protocol is small, line-delimited, and fully
   distilled in [docs/DEBUG-PROTOCOL.md](../DEBUG-PROTOCOL.md).
2. **This machine's seams** make debugging almost unfairly easy: `cpu_cen`
   (ADR-0001) freezes the CPU between T-states; BRAM is dual-ported (memory
   inspection without stealing the bus); every strobe of the bus idiom is
   observable in the `m1_core` wrapper.
3. **The real Model 1 exposes almost everything at its expansion edge** —
   and the Expansion Interface passes the complete bus through 1:1 at its
   "Screen Printer Bus" card edge (J3), including TEST\* and WAIT\* (EI
   Service Manual 1979, schematic sheet 3). Missing at the edge: NMI\*,
   M1\*, CLK, BUSRQ\*/BUSAK\* (Technical Reference Handbook 1982, p. 91).
   So a debug adapter for a *real* TRS-80 is feasible — with the specific
   primitive set below, not with an emulator's omniscience.

## Decisions

### 1. Wire protocol: trszog JSON-RPC first, GDB-RSP later (maybe)

The backend speaks the trszog protocol as specified in
[DEBUG-PROTOCOL.md](../DEBUG-PROTOCOL.md): one debugger, interchangeable
backends (trs80gp, this machine, later a real TRS-80). A GDB remote-serial
stub was considered as the "standard" choice and deferred: Z80 support in
GDB lives in forks, DeZog/trszog is the ecosystem's working editor
integration, and a second frontend can be added later as a thin adapter
over the same internal API — nothing below the protocol layer is
JSON-specific.

### 2. Layering: debug core in the FPGA, protocol server on the ESP32

```
VS Code / trszog  ──TCP/JSON-RPC──  ESP32 debug server
                                        │  (narrow framed link, single owner)
                                    m1_debug core (RTL)
                                        │  cpu_cen · bus taps · BRAM port B
                                      m1_core
```

The RTL debug core implements *mechanism only*: halt/resume/step,
comparators, memory port, register capture. Protocol, symbol files, session
state, and file access live on the ESP32. The FPGA↔ESP32 link gets exactly
one owner process; how the debug server coexists with the other planned
ESP32 services (disk sources, telemetry, sound events) is the subject of
the upcoming ESP32 services ADR — this ADR only claims the link's debug
frames.

### 3. Debug-core primitives on this machine

- **Halt/resume/step:** gate `cpu_cen`. Instruction-granular stepping runs
  to the next opcode fetch (the wrapper's M1 strobe), so a "step" is one
  instruction, not one T-state — with a T-state mode kept for RTL-level
  forensics.
- **Breakpoints:** PC comparators on the fetch strobe (table in BRAM,
  effectively unlimited entries, works in ROM). **Watchpoints:** address
  (+direction) comparators on the data strobes. Both halt the machine
  *before* the cycle completes its architectural effect where feasible.
- **Memory:** reads/writes through the second BRAM port — non-intrusive,
  works while the program runs. VRAM/ROM/EI-RAM are all reachable this way.
- **Registers:** captured by **instruction stuffing under halt** — the core
  feeds the frozen CPU a short save/restore sequence (PUSH/LD/…) on the bus
  while capturing the write-backs, then restores state and PC. Considered
  alternative: tapping tv80's internal register file. Rejected for now
  because it would end the "vendored unchanged" status of the core
  (ADR-0003) — and because stuffing is *exactly* the mechanism the
  real-hardware adapter must use anyway (a real Z80 has no register taps),
  so the FPGA path exercises the code we will need again at the edge
  connector. If stuffing turns out fragile in practice, tapping is the
  documented fallback (as a scoped, waivered deviation like the lint one).

### 3a. The debugger outlives the target's reset (portability rule)

A debugger must survive the target pressing its own reset button — a real
ICE does, because it is a separate box with its own power. On real
hardware this is automatic: the adapter (a board, or this FPGA driving a
ribbon cable) is powered independently of the TRS-80, so a target reset
never touches it. To make the FPGA model *faithful to that reality* — not
to bolt on an FPGA-only quirk — the debug subsystem (`m1_debug` + its host
link) lives in the FPGA power-on reset domain, **not** the machine reset
domain: a warm/cold machine reset (front-panel button, cold-start reload)
leaves the debugger standing.

The debugger then treats the machine reset as an *observed event*, not as
its own reset:

- `m1_debug` takes an abstract **target-reset input**. On the FPGA it binds
  to the machine's reset (`core_rst_n`); on the real-hardware adapter it
  binds to **SYSRES\*** on the expansion edge (Technical Reference pin
  list, PLAN-DEBUG-ADAPTER-BUS §2). Same port, different source, chosen at
  the board/wrapper level — never inside the protocol.
- On that edge the core drops any freeze/breakpoint state to "target
  running free", raises a transport-agnostic **target-reset event** to the
  host, and sets a sticky "reset since last seen" bit in the status reply.
- Recovery *below* the event differs by target and stays below the
  protocol: the FPGA just re-arms comparators; the real Model 1 adapter
  must re-inject its IM-2 stub (§4) because the target's reset clears I and
  IM. This makes reset-detection not a nicety but a **requirement** for the
  real-hardware path — the adapter has to know its debug foothold was wiped
  so it can rebuild it. Building it now on the FPGA exercises exactly that
  logic.

The rule that keeps this portable: the target-reset input and the
target-reset event are **target-agnostic**; only their binding (which wire,
which re-arm sequence) is chosen at the wrapper. The same `m1_debug` serves
the internal machine and, later, an external TRS-80 over GPIO/ribbon — the
target interface (internal `m1_core` vs. external bus) becomes a
board-level selection, and the reset input switches source with it.

### 4. Real-hardware stage: the adapter, in two honest tiers

- **Model 1 (committed direction):** the adapter docks at the EI's Screen
  Printer Bus (or the keyboard edge when no EI is fitted), electrically
  polite (one TTL load, 5 V ↔ 3.3 V translation). Primitives: WAIT\* to
  hold the CPU, TEST\* to take the bus (the adapter then drives the 4116
  RAS\*/MUX/CAS\* sequencing itself for DRAM access); a memory-mapped
  presence in the machine's free 0x3000–0x37DF window for stub code and
  mailbox; and — since INTAK\* is on the edge — the **IM-2 vector trick**:
  the adapter drives the interrupt vector byte itself, normally steering to
  the stock heartbeat path and, on a pending break, to the debug stub. With
  I = 0x30 the vector table and stub live entirely in the adapter's window:
  zero bytes of machine RAM. Limits, stated plainly: INT is maskable (DI
  defers a break until EI; the hard stop remains WAIT\*+TEST\*), and
  activation needs one initial code injection (DOS command or DMA-injected
  bootstrap).
- **Model 3/4 (explicitly not now):** the 50-pin I/O bus exposes no memory
  bus and is software-gated (ENEXTIO, port 0xEC) — without resident
  software nothing moves. That stage is real but is its own chapter, with
  its own ADR, later.

### 5. Order of work

1. **D1 — debug core + ESP32 server on this machine**, verified by a
   spec-driven conformance suite (DEBUG-PROTOCOL.md §Verification).
   Deliberately *not* a golden against the debug-enabled trs80gp: its
   server has known defects, and adopting its behavior would freeze
   them in. For the first time in this project the spec itself is the
   reference — trs80gp informs, the document decides.
2. **D2 — Model 1 adapter hardware** (level shifting, edge connector,
   IM-2/WAIT\*/TEST\* primitives), reusing the D1 stub and server.
3. **D3 — Model 3/4**, separate ADR when D2 exists.

## Consequences

- tv80 stays vendored and untouched; the debugger works through
  architectural seams (`cpu_cen`, bus, BRAM ports) that already exist.
- The trszog protocol becomes a compatibility contract of this repo;
  changes to it are spec changes, golden-verified like everything else.
- The ESP32 firmware becomes a real subproject with its own service
  architecture — this ADR deliberately leaves that design to the ESP32
  services ADR and claims only the debug frames on the link.
- The Model 1 adapter inherits verified building blocks (stub, server,
  protocol) instead of being designed from scratch at the edge connector.
