# The debug interface

**Status: normative spec, tracks ADR-0006 / ADR-0007.** 

This specification is a ** **debugger-agnostic interface** to the 
TRS-80 rev-z debug core / dongle.

trszog uses this interface to interact with the TRS-80, but it is
no more than our reference client: a different debugger can be attached,
or a different host, at either of the two layers below. Nothing here is
trszog-specific except where explicitly stated.

## The two layers

```
  debugger (e.g. trszog, or your own)
        │  Layer 2:  JSON-RPC 2.0 over TCP  (this doc, "JSON-RPC layer")
   Local Python bridge or ULX3S-ESP32 server
        │  Layer 1:  binary protocol v0  (this doc, "wire protocol")
   debug core (m1_debug, Hardware, in the FPGA or a physical pluggable dongle)
        │  cpu_cen · comparators · dual-port memory · instruction stuffing
   the TRS-80 (RTL machine, or a real one over a ribbon)
```

You can implement against **either** layer:

- **Layer 1 (binary v0)** is the debug core's *native* wire protocol — a
  raw byte stream over the serial link (FTDI today, the ESP32 link later).
  Target this to replace the bridge, or to drive the dongle from anything
  that can open a serial port. It is small, fixed-framed, and transport-
  agnostic (the same bytes run over UART or the ESP32 link).
- **Layer 2 (JSON-RPC)** is what the bridge (`tools/trszog_bridge.py`) or
  the ESP32 server *exposes* to a debugger. Target this to plug in a
  different debugger while reusing our bridge. It is the compatibility
  surface a debug-enabled trs80gp also might speak, so one debugger could then
  drive the integrated siumlator, the goldstandard emulator, this FPGA machine, 
  or a real TRS-80 behind a dongle, interchangeably.

The reference bridge translates Layer 2 ⇄ Layer 1; the ESP32 server will
port exactly that translation. Both layers are versioned independently
(the wire protocol is "v0").

---

# Layer 1 — the wire protocol (binary v0)

The debug core's own protocol: a bidirectional **byte stream**, no length
framing, host-driven. The host sends a command; the core replies with a
fixed-shape response. Multi-byte values are **little-endian**. Transport is
whatever carries bytes — 8N1 serial at 460800 Bd over the ULX3S FTDI today,
the ESP32 link tomorrow.

### Commands (host → core)

| Byte | Command | Payload | Response |
|---|---|---|---|
| `01` | HALT | — | `01 pc_lo pc_hi` (after the freeze) |
| `02` | RUN | — | `02` |
| `03` | STEP | — | `03 pc_lo pc_hi` (one instruction) |
| `04` | GET_REGS | — | `04` + 30 register bytes (below) |
| `05` | SET_REG | `idx val_lo val_hi` | `05 pc_lo pc_hi` |
| `06` | READ_MEM | `a_lo a_hi n_lo n_hi` | `06` + `n` data bytes |
| `07` | WRITE_MEM | `a_lo a_hi n_lo n_hi` + `n` bytes | `07` |
| `08` | SET_BP | `idx a_lo a_hi en` | `08` (idx 0–7) |
| `09` | STATUS | — | `09 flags cause pc_lo pc_hi` |
| `0A` | SET_WP | `idx a_lo a_hi rw` | `0A` (idx 0–3) |
| `0B` | KEYS | 8 matrix bytes | `0B` (see below) |

- **SET_REG idx:** 0 AF, 1 BC, 2 DE, 3 HL, 4 IX, 5 IY, 6 SP, 7 PC, 8 I,
  9 R, 10 AF′, 11 BC′, 12 DE′, 13 HL′. Values are 16-bit; 8-bit registers
  (I, R) take the low byte.
- **SET_BP:** 8 program-counter breakpoint slots; `en` = 1 arm / 0 clear.
  Slot 7 is conventionally reserved by the host for `stepOver`.
- **SET_WP:** 4 data watchpoint slots; `rw` bit0 = break on read, bit1 =
  break on write (address comparators on the CPU's data strobes).
- **STATUS flags:** bit0 = halted, bit1 = target-reset-seen (sticky,
  **cleared by reading STATUS**). `cause` is the last stop cause (below).
- **Memory** commands work while halted; `n` is a 16-bit count — the
  reference bridge chunks a whole-bank read into ≤ 32 KiB transactions.
  Issued while running, WRITE_MEM always returns the error byte; for
  READ_MEM the behavior depends on the core:
  - **Baseline** (v0 as originally shipped, and any core on a real TRS-80
    behind the dongle, where the memory is on the machine's bus): error
    byte. Hosts fall back to halt/peek/run — the ICE way.
  - **Non-intrusive read** (optional; cores whose memory is FPGA block
    RAM — the Rev Z machine and its Verilator twin): READ_MEM answers
    normally while the machine runs, served from second BRAM read ports.
    Zero CPU cycles are stolen; the running program cannot tell. The
    served picture is the *memory*, not the bus: ROM, RAM, EI RAM (an
    unpopulated bank reads 0xFF) and video RAM (with its authentic bit-6
    read fold) return their contents, the keyboard matrix region
    (0x3800–0x3BFF) returns the live rows, and the memory-mapped device
    region (0x3000–0x37FF) reads 0xFF — device registers are **not**
    touched, so no read side effects can fire behind the program's back.
    Under halt, READ_MEM keeps using the authentic bus-master path
    (device side effects included) on all cores, unchanged.
  - **Detection** is a side-effect-free probe: send a 1-byte READ_MEM
    while the machine runs — a baseline core answers `EE`, a capable one
    answers data. The reference bridge probes once per session (skipped
    when it attaches to a halted machine; it then adapts on the first
    read-under-run) and surfaces the result as the
    `nonIntrusiveReadMemory` capability (Layer 2, `initialize`).
- **KEYS:** injects keyboard input. The 8 payload bytes are the TRS-80
  keyboard matrix, byte *k* = row *k*, bit *j* = column *j*, 1 = pressed
  (row 0 `@ A…G`, row 1 `H…O`, row 2 `P…W`, row 3 `X Y Z`, row 4 `0…7`,
  row 5 `8 9 : ; , - . /`, row 6 `ENTER CLEAR BREAK ↑ ↓ ← → SPACE`,
  row 7 `SHIFT`). The mask is OR-ed with the machine's physical keyboard
  and follows the HID-report semantics of `m1_hid_keys.v`: **current
  report wins** — each KEYS replaces the previous debug mask entirely, it
  never accumulates; all-zeros releases everything. KEYS works while
  running or halted and does not disturb the CPU. It is optional:
  **probing** for it is safe and side-effect-free — send `0B` followed by
  eight `00` bytes; a backend with KEYS replies a single `0B`, a plain-v0
  backend replies `EE` for the `0B` and one `EE` per trailing `00` (`00`
  is not a command and changes no state). The reference bridge probes
  exactly this way once per session and surfaces the result as the
  `keys` capability (Layer 2, `initialize`).

### GET_REGS — the 30 register bytes

In order: `A F B C D E H L IXh IXl IYh IYl I · R · A′ F′ B′ C′ D′ E′ H′ L′
SP_lo SP_hi PC_lo PC_hi IM IFF`. The two bytes marked `·` (after I and
after R) are the flags left by the capture's `LD A,I` / `LD A,R` and carry
no register data — ignore them. IM is 0/1/2; IFF is 0/1. Registers are
captured by instruction stuffing (ADR-0006 §3), so R has advanced a few
counts, exactly as it would on a real-Z80 ICE.

### Responses out of band

| Byte | Meaning |
|---|---|
| `EE` | error — memory access while running, or a bad index |
| `80 cause pc_lo pc_hi` | **async event**: the machine stopped or reset on its own |

`cause`: 0 host-requested, 1 breakpoint, 2 step, 3 watchpoint, **4 target
reset** (the machine reset out from under the debugger — see ADR-0006 §3a).

**Demultiplexing:** an async `80` event may arrive at any time, including
interleaved with a command's response. A client reads bytes and, whenever
the next byte is `80`, consumes the 4-byte event and keeps reading for the
real response. (The reference bridge does exactly this.)

---

# Layer 2 — the JSON-RPC layer (debugger-facing)

TCP, line-delimited **JSON-RPC 2.0**: every request, response, and
notification is one JSON object terminated by `\n`. The debugger connects as
a TCP client. Requests carry `id`; notifications (server → client) carry
none. This is the surface a debug-enabled trs80gp also exposes, so a
debugger written against it drives the emulator or our backend unchanged.
It is distilled from the [trszog](https://github.com/TechPrototyper/trszog)
client, the debug-enabled trs80gp server, and trszog's mock server; where
those disagree, this document is normative.

## Data conventions

Observed client/server behavior is loose; the backend MUST be liberal in
what it accepts and strict in what it emits:

- **Numbers/addresses inbound:** accept both JSON numbers and hex strings
  (`"0x6000"` and `"6000"` — a bare string is hex). Observed: `readMemory`
  sends the address as a number, `writeMemory` as a hex string.
- **Addresses outbound:** hex string, `0x`-prefixed, four lowercase digits
  (`"0x6000"`).
- **Memory payloads:** plain hex string, two chars per byte, no separators.
- **Register values outbound:** `0x`-prefixed uppercase hex, width-padded
  (16-bit: 4 digits, 8-bit: 2).
- **`readMemory` byte count:** the debug-enabled trs80gp expects `length`;
  trszog's client and mock server use `size`. Normative: **accept both,
  `length` wins if both are present**; echo the count back as `size`.

## Methods

The full method surface, as exercised by trszog:

| Method | Params | Result | Notes |
|---|---|---|---|
| `initialize` | — | `{programName, version, modelName, modelNumber, capabilities?}` | capability handshake, see below |
| `getRegisters` | — | register object, see below | |
| `setRegister` | `{register, value}` | `true` | register name as in the register object |
| `readMemory` | `{address, length\|size}` | `{address, size, data}` | `data` = hex string |
| `writeMemory` | `{address, data}` | `true` | `data` = hex string |
| `continue` | — | `true` | async stop reported via notification |
| `pause` | — | `true` | notification follows |
| `stepInto` | — | `true` | one instruction; notification follows |
| `stepOver` | — | `true` | see divergences below |
| `setBreakpoints` | `{breakpoints: [{address}, …]}` | `true` | full replacement, not incremental |
| `loadObj` | `{filePath}` | `{success, startAddress, endAddress, entryPoint}` | load a program image (`.cmd`) |
| `launch` | `{program}` | `true` | load **and start** a `.cmd` — what the trszog client actually sends (it avoids client-side loading because the emulator's `setRegister` is broken); if a breakpoint sits on the entry (the client arms one for stop-at-entry), the backend stops there and says so |
| `saveObj` | `{startAddress, endAddress, filePath}` | `{success}` | dump memory to a file |
| `configure` | backend-specific flags | echo of accepted flags | optional; unknown flags are an error |

Errors use standard JSON-RPC error objects (`-32601` unknown method,
`-32602` bad params).

### Capabilities (`initialize`)

The ADR-0007 promise — *advertise the backend's real capabilities rather
than masquerading* — is kept in the `initialize` result. `capabilities`
is an optional object; a missing object (the debug-enabled trs80gp emits
none) or a missing key means "assume the trs80gp baseline" so stock
clients keep working. Keys defined so far:

| Key | Type | Meaning |
|---|---|---|
| `setRegister` | bool | `setRegister` actually works (the trs80gp build's is broken) |
| `stepOver` | bool | native `stepOver` (temp hardware breakpoint after CALL/RST/DJNZ) |
| `breakpoints` | number | hardware PC-breakpoint slots (7 usable; slot 8 is the stepOver temp) |
| `watchpoints` | number | hardware data-watchpoint slots (0 = none, see `x-setWatchpoints`) |
| `keys` | bool | keyboard injection via `x-keys` (Layer 1 KEYS probed at session start) |
| `nonIntrusiveReadMemory` | bool | READ_MEM works while running, zero CPU impact (second BRAM ports). Absent when not yet probed (session attached to a halted machine); the bridge adapts either way, so clients need it for display only |

The reference bridge reports
`{"setRegister": true, "stepOver": true, "breakpoints": 7, "watchpoints": 4, "keys": <probed>, "nonIntrusiveReadMemory": <probed>}`.

### Extension methods (`x-…`)

Namespaced methods beyond the trszog/trs80gp surface, negotiated via the
capabilities above. A backend without the capability answers `-32601`.

| Method | Params | Result | Notes |
|---|---|---|---|
| `x-setWatchpoints` | `{watchpoints: [{address, access?}, …]}` | `true` | full replacement (like `setBreakpoints`); `access` ∈ `"r"` \| `"w"` \| `"rw"` (default `"rw"`); at most `capabilities.watchpoints` entries. An empty list clears all. A hit stops the machine and is reported as a `stopped` notification with reason `watchpoint` (the address is the halt PC, not the data address — the comparators fire on the data strobes). |
| `x-keys` | `{matrix}` | `true` | `matrix` = 16 hex chars (8 bytes, row 0 first) — the Layer 1 KEYS payload verbatim, same "current report wins" semantics. Clients SHOULD send an all-zero matrix when their input surface loses focus, so no key sticks. |

### The register object

`getRegisters` returns the full Z80 state as one flat object, 16-bit
composite form:

```
AF BC DE HL IX IY SP PC   — "0x" + 4 hex digits
I R                       — "0x" + 2 hex digits
AF_ BC_ DE_ HL_           — shadow set, 4 hex digits
IM                        — number (0/1/2)
```

The mock server can also emit an 8-bit split form (`A`,`F`,…,`A2`,`F2`,…)
and the client copes with either; our backend emits the composite form
only. `setRegister` accepts the composite names plus the 8-bit halves.

### Target reset

The debug subsystem lives in the FPGA power-on domain and *observes* the
machine reset rather than sharing it (ADR-0006 §3a), so a front-panel or
cold-start reset — or, on the real-hardware adapter, SYSRES\* — does not
take the debugger down with the target. When it happens the backend:

- drops any halt/breakpoint/watchpoint state (the target restarted at its
  reset vector; the old state is meaningless),
- emits an async event with reason `reset` (binary cause 4), and
- sets a sticky "reset seen" flag readable in the status reply, cleared on
  read — a backstop for a host that reconnected after the event.

The bridge turns this into a clean `stopped` for the debugger: it retakes
control (halts the freshly-reset target) and reports the stop, so the
session resyncs instead of acting on stale state. This is a capability the
emulator's debug server does not have at all.

### Stop notifications

After `continue`/`pause`/`stepInto`/`stepOver`, the halt is reported
asynchronously. The debug-enabled trs80gp emits (live-verified):

```json
{"jsonrpc":"2.0","method":"stopped","params":{"reason":"breakpoint", ...}}
```

The mock server instead emits `paused` (reasons `user_request`,
`step_complete`) and `breakpoint`. Normative for our backend: **emit
`stopped`** with `reason` ∈ `breakpoint` | `step` | `pause` | `watchpoint` | `reset`
and, where known, `address` — matching the real emulator, which is what the
client is tested against.

## Known divergences (and what we do about them)

1. **`size` vs `length`** — see above; we accept both. (Against the real
   emulator, a `size`-only client silently reads one byte — worth knowing
   when comparing backends.)
2. **`stepOver`, `status`** — the debug-enabled trs80gp answers "unknown
   method"; the mock implements both. Our backend implements `stepOver`
   natively (temporary breakpoint after the call/repeat instruction — the
   hardware breakpoint comparator makes this cheap) and omits `status`
   until the client actually uses it.
3. **Address encodings** are inconsistent per method in the wild; we accept
   everything, emit canonically (see conventions).

## What the FPGA backend can do better

The protocol above is the compatibility surface. Behind it, this machine
has abilities an emulator process does not expose and a real Z80 cannot
offer non-intrusively — they surface as *quality* of the same methods, not
as new ones:

- **Non-intrusive memory access:** `readMemory` under run uses a second
  BRAM port — no CPU stall, no bus steal; the running program cannot tell.
  (Implemented — see READ_MEM above and the `nonIntrusiveReadMemory`
  capability; on a real TRS-80 behind the dongle the baseline
  halt/peek/run remains, honestly reported.)
- **True hardware breakpoints/watchpoints:** address comparators on the
  fetch/read/write strobes — no code patching, works in ROM, any address.
- **Cycle-exact stepping:** the machine's clock-enable seam (`cpu_cen`)
  halts and resumes the CPU between T-states without touching its state.

Method extensions beyond the trszog surface (e.g. watchpoint conditions,
trace capture) will be namespaced (`x-…`) and negotiated via `initialize`
capabilities, so stock trszog remains fully functional.

## Verification plan

This is the first subsystem of this project **without a golden model** —
deliberately. Parts of the debug-enabled trs80gp server work and stay
useful for *selective cross-checks*; but the defect classes observed so
far rule it out as a reference: some methods are missing, some responses
are malformed JSON, some paths are extremely slow, and memory
breakpoints do not work at all (the `size`/`length` split above is only
the visible tip). A precise defect inventory is still to be written —
until then the rule is: cross-check against trs80gp only where it is
known-good, and never let it arbitrate. **This document is normative.**

The backend therefore earns its checkmark two ways: (1) a spec-driven
conformance suite — scripted sessions (initialize → load → breakpoints →
continue → stopped → registers/memory → step → …) asserting exactly the
responses this document defines, including the liberal-input cases; and
(2) truth-checks of the *content* against the machine's own proofs: the
registers and memory a session reports must match the architecturally
known state of a deterministic test program, the way `tb_m1_debug`
already asserts PC sequences and register values instruction by
instruction.
