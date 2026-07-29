# ADR-0007 — trszog integration: a first-class remote, not an emulator costume

**Status:** proposed · 2026-07-26

## Context

The debug core works end to end: a debugger (trszog) reaches it over the
JSON-RPC layer, a Python bridge translates that to the binary wire protocol
over the FTDI serial link, and the FPGA machine is debugged live
([ADR-0006](0006-debug-architecture.md),
[DEBUG-PROTOCOL.md](../DEBUG-PROTOCOL.md)). It works because the bridge
*impersonates a debug-enabled trs80gp*: trszog's `remoteType: trs80gp`
connects to `localhost:49152` and cannot tell it is talking to our bridge
instead of the emulator.

That impersonation is a hack with real costs already felt:

- The launch config must name an existing `emulator.path` **only** to keep
  trszog from falling back to its mock server — a lie to dodge a lie.
- Connection failures read as "trs80gp on port 49152 can't be loaded",
  which is confusing when there is no emulator involved.
- We must hide capabilities the emulator lacks (real hardware
  breakpoints/watchpoints, non-intrusive memory, target-reset events)
  because the remote type claims to be an emulator.
- Nobody can express *what* is behind the port: the FPGA machine, or a real
  TRS-80 behind a dongle, over serial or over WiFi.

The wire protocol is our own proposal, and trszog is our own fork — so the
honest fix is available: stop pretending to be an emulator.

## Decisions

### 1. A first-class remote type in trszog

Add a new `remoteType` (working name `revz`) — a thin subclass of the
existing trs80gp remote. It reuses the entire JSON-RPC client (same
protocol, [DEBUG-PROTOCOL.md](../DEBUG-PROTOCOL.md) Layer 2) but drops the
emulator baggage: **no emulator launch, no mock-server fallback, no
`emulator.path` requirement**. It advertises the backend's real
capabilities via `initialize` rather than masquerading.

### 2. Configuration: four orthogonal axes

The launch config carries what the emulator type never could. The axes are
independent and compose:

| Key | Values | Meaning |
|---|---|---|
| `target` | `fpga` \| `physical` | the machine being debugged |
| `dongle` | `fpga` \| `physical` | what hosts the debug core |
| `attachTo` | `expansionInterface` \| `mainboard` | where on a physical target (only when `target: physical`) |
| `transport` | see below | how the host reaches the dongle |

Combinations cover the roadmap: `dongle:fpga, target:fpga` (today),
`dongle:fpga, target:physical` (the FPGA driving a real TRS-80 over a
GPIO ribbon), `dongle:physical, target:physical` (a standalone dongle
board). `attachTo` picks the expansion-interface Screen Printer Bus vs. the
bare keyboard-edge (a 16 KB Level II machine with no EI).

`transport` selects how the debugger reaches the debug core — which, for
JSON-RPC, mostly reduces to a host:port, plus whether we spawn the bridge:

```jsonc
"remoteType": "revz",
"revz": {
  "target": "fpga",
  "dongle": "fpga",
  "transport": {
    "kind": "python",                 // python | esp32 | serial
    // kind=python: the local bridge over a serial port (default)
    "serial": "/dev/cu.usbserial-D01374",
    "baud": 460800,
    "autoStart": true                 // see decision 3
    // kind=esp32: connect over the network to the ESP32 debug server
    // "host": "trs80.local", "port": 49152
  }
}
```

WiFi provisioning (`wifiSsid`/`wifiPassword`) is intentionally **not** a
launch-config concern by default — credentials do not belong in a checked-in
file; the ESP32 is provisioned on its own and the client is given only
`host`/`port`. The fields may exist as an opt-in for a throwaway local
setup, with that caveat documented.

### 3. Bridge lifecycle: spawn if configured and absent, never adopt-and-kill

When `transport.kind: "python"` with `autoStart: true`, trszog owns the
bridge lifecycle — but politely:

- **Check first.** If something is already listening on the target port,
  **leave it alone** and just connect. A bridge a developer started by hand
  (for logging, for a shared session, for debugging the bridge itself) must
  not be killed or duplicated.
- **Spawn if absent.** Otherwise start `tools/trszog_bridge.py` from *this*
  repository with the configured serial device and baud, wait for it to
  listen, then connect.
- **Own only what you spawned.** A bridge trszog started, trszog may stop at
  session end; a pre-existing one is never touched.

This removes the whole "forgot to start the bridge" failure class without
taking a hardware-reset button or a manual `preLaunchTask` to do it.

### 4. The bridge stays in this repository

`tools/trszog_bridge.py` lives here, versioned with the wire protocol it
speaks; trszog references and launches it, it does not vendor a copy. The
bridge is the **reference implementation** of the Layer 2 ⇄ Layer 1
translation, and the ESP32 debug server ports exactly it.

### 5. The debug interface is a published, debugger-agnostic contract

Both layers of [DEBUG-PROTOCOL.md](../DEBUG-PROTOCOL.md) are a public
interface, not internal notes: the binary wire protocol (Layer 1) so anyone
can drive the dongle directly or replace the bridge, and the JSON-RPC layer
(Layer 2) so anyone can attach a *different* debugger. trszog is merely the
reference client. This is a deliberate openness decision: the value of an
open debug core is that its interface is documented well enough to build
against without reading our RTL.

## Consequences

- trszog stops lying about being an emulator; error messages, capabilities,
  and config all become honest.
- The launch config now expresses the full matrix the real-hardware
  roadmap needs, years before the hardware exists — the schema is fixed
  now so it does not churn later.
- The `trs80gp` remote type stays exactly as is (it really is for the
  emulator); the `revz` type is additive. Until it ships, the
  impersonation path keeps working, so nothing regresses.
- Publishing both protocol layers invites third-party clients and servers —
  and obliges us to keep the spec truthful as the core evolves (the
  conformance suite of DEBUG-PROTOCOL.md §Verification is what enforces it).
