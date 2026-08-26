# ADR-0010 — A scoped RTL lint waiver is allowed for a synchronized cross-domain observation

**Status:** accepted · 2026-08-26

## Context

The standing rule (CLAUDE.md, mirroring GOVERNANCE.md) is: the RTL is full
`-Wall` clean under Verilator; lint waivers live **only** in testbenches,
justified inline. Until now the RTL carried zero waivers.

Verilator 5.05x newly (more aggressively) enables the `SYNCASYNCNET` check and,
under `-Wall`, treats the warning as fatal. On unchanged RTL it aborts the
`Vm1_core` build:

```
%Warning-SYNCASYNCNET: rtl/m1_core.v:33:24: Signal flopped as both
                       synchronous and async: 'por_rst_n'
```

The finding is a true positive about net topology, and the design already
resolves it correctly:

- **Async side.** `por_rst_n` is the machine reset. Every submodule consumes it
  as an asynchronous, active-low reset (`always @(posedge clk or negedge
  rst_n)`) — uniformly across the core.
- **Sync side.** Exactly one place samples the *same net* synchronously:
  `m1_debug` observes the machine reset so the debugger can report it. Because
  the debug subsystem lives in the FPGA power-on domain and must **survive** a
  machine reset (ADR-0006 §3a), it cannot take `por_rst_n` as its own reset. It
  instead brings the net across through a 2-FF synchronizer (`trs_sync`) plus a
  falling-edge detect — the textbook safe way to sample an asynchronous signal
  into another domain.

So one net legitimately fans out both async (into the reset trees) and sync
(as a synchronized observable into the debug domain). That is precisely the
pattern `SYNCASYNCNET` names — and here it is already handled safely.

Two rejected alternatives:

1. **Pin an older Verilator** (≈5.040–5.048 that doesn't fatal on
   `SYNCASYNCNET`). This freezes the toolchain away from oss-cad-suite, which
   CLAUDE.md treats as *the* toolchain, and only defers the same version-drift
   collision. It also leaves a skew: local dev on 5.041 (silent) vs. Codespace
   on 5.051 (fatal).
2. **Global `-Wno-SYNCASYNCNET`** in the Makefile. This disables a genuinely
   useful clock/reset-domain lint for *all* present and future RTL — a later
   POR/reset net *without* a synchronizer would then pass silently. Unacceptable
   for a check whose whole job is to catch that mistake.

## Decision

1. Silence `SYNCASYNCNET` **only** at the `por_rst_n` net, with a scoped
   `/* verilator lint_off SYNCASYNCNET */` … `lint_on` pair around its port
   declaration in `rtl/m1_core.v`, carrying an inline justification that points
   at the `m1_debug` `trs_sync` synchronizer and ADR-0006 §3a.
2. This establishes a **narrow exception** to the "waivers only in testbenches"
   rule: an RTL lint waiver is permitted **only** where a lint flags a
   *deliberate, correctly synchronized* cross-domain construct, and only when
   scoped to the single signal with an inline reference to this ADR. It is not a
   license for RTL waivers of convenience; the `-Wall`-clean default stands, and
   the global `-Wno-` form remains disallowed.

## Consequences

- The `Vm1_core` build is clean on both Verilator 5.041 (local) and 5.05x
  (current oss-cad-suite / Codespace); the underlying version drift is resolved
  at the source rather than by freezing the toolchain.
- `SYNCASYNCNET` stays active everywhere else, so a future unsynchronized
  reset-domain crossing still fails the build.
- The exact pragma placement is verified against 5.05x in the Codespace (local
  5.041 does not emit the warning, so it cannot confirm the silence).
- If a second RTL waiver is ever proposed, it is measured against this ADR's
  test (deliberate + synchronized + signal-scoped + ADR-referenced), not waved
  through by precedent.
