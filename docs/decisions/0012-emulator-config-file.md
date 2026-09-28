# ADR-0012 — emulator `--config` file: one format shared with the VS Code companion

**Status:** accepted · 2026-09-28

## Context

`sim/emu`'s Verilator emulator is fully configured by CLI flags (`--rom`,
`--disk0..3`, `--ei16`/`--ei32`, `--throttle`, `--debug-tcp`, …). That's fine
for interactive use, but two other consumers need to drive the same machine
programmatically with a *persistent, file-based* configuration instead of a
hand-assembled argv:

- `trs80-dev`'s dev-container (`.devcontainer/scripts/start_trs80.sh`) reads
  a `trs80revz.json` at the workspace root and translates it into the same
  CLI flags, so a Codespace user edits one JSON file instead of an argv.
- `trs80-vscode`, the companion extension, edits and validates that same
  `trs80revz.json` against `schemas/trs80revz.schema.json` and offers it in
  the editor with IntelliSense (`contributes.jsonValidation`).

Both already agree on a key set and a JSONC (JSON + `//`/`/* */` comments)
surface syntax. The emulator itself had no way to read that file directly —
only `start_trs80.sh`'s hand-rolled comment stripper + `argparse`-style
`get(path, default)` walker understood it, which meant the format's only
authoritative *reader* lived in a shell/Python script in a different repo,
not next to the binary it configures.

## Decision

Add `--config=<path>` to the emulator, reading the same keys and structure
as `trs80revz.json` (`schemas/trs80revz.schema.json` in `trs80-vscode` is
the normative schema; this ADR does not duplicate it — see the mapping
table in `sim/emu/README.md`).

- **Precedence: CLI flags > config file > built-in defaults.** The loader
  only touches an option when the corresponding key is *present* in the
  file; it never back-fills the schema's own documented defaults. A config
  file is a partial override layered on the emulator's existing defaults,
  not a full replacement of them — loading an unrelated config that only
  sets `throttle` can't have the side effect of silently turning the debug
  TCP listener on, even though the schema documents `debugDongle.enabled`
  as defaulting to `true`. This is a deliberate divergence from
  `start_trs80.sh`, which *does* apply full schema defaults (right for a
  container whose whole point is a debugger session; wrong for a binary
  whose own CLI defaults already make sense standalone).
- Without `--config`, a `trs80revz.json` in the current directory is loaded
  automatically if present (and announced on stderr) — same default lookup
  as `start_trs80.sh`.
- **JSONC parsing: vendored `nlohmann/json` single header** (MIT,
  `sim/emu/third_party/json.hpp`, provenance in `CREDITS.md`), using its
  `ignore_comments` parse option rather than hand-rolling a stripper a
  third time. No new dependency beyond a header; nothing on the RTL/hot
  simulation path touches it.
- Unknown JSON keys warn to stderr and are otherwise ignored — a config
  file authored against a newer schema (or with a typo) degrades instead of
  refusing to start. A missing/unreadable `--config` path, or invalid
  JSONC, is a hard error (the file was asked for by name; if it isn't
  there, that's a mistake worth stopping for).
- Keys with no CLI equivalent would warn and no-op (matching the unknown-key
  behavior above); in practice every key the schema currently defines maps
  onto an existing flag — see the table in `sim/emu/README.md`.
- Added `--dry-run` alongside it: resolves ROM/config/CLI into the
  effective configuration, prints it, exits 0, without requiring `--rom` or
  touching SDL/audio. Useful standalone (inspect what a config file
  resolves to before pointing a real ROM at it) and doubles as the
  smoke test for `--config` itself.

## Consequences

- Three readers, one format: the schema in `trs80-vscode` stays the single
  normative definition; `start_trs80.sh` and the emulator's own
  `--config` are two independent implementations of reading it, which is
  useful cross-validation (both were checked against the same sample file
  while writing this).
- The emulator's `--config` is intentionally *not* a drop-in replacement
  for everything `start_trs80.sh` does — it doesn't glob `disks/*.dmk`
  when `media.disks` is absent (that's a directory-scanning convention
  tied to a container workspace root, not something a general-purpose
  `--config` should do implicitly), and it doesn't apply the schema's
  `debugDongle`-on-by-default. Both are documented explicitly in the
  mapping table so nobody has to read the source to find out.
- `sim/emu/third_party/` now carries two vendored single headers
  (`stb_image.h`, `json.hpp`); both are unmodified upstream drops with
  their own license files and a `CREDITS.md` entry, following the pattern
  ADR-0002/0003 already established for vendored code elsewhere in the
  repo.

## Evidence

- `cd sim/emu && make clean && make` — `-Wall` clean (VFLAGS already carries
  `-Wall`; the new code adds no warnings).
- Manual smoke test: a sample `trs80revz.json` with all five sections
  populated plus one deliberately unknown key, loaded three ways —
  `--config=<path> --dry-run`, auto-detected from the current directory,
  and a missing `--config` path — confirms unknown-key warning (non-fatal),
  CLI-overrides-file precedence (`--volume=99` over the file's `60`), and
  missing-file exit 1. Full transcript in the Phase E session report.
