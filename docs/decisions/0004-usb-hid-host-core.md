# ADR-0004 — USB-HID host core for the keyboard front end

**Status:** accepted · 2026-07-19

## Context

`m1_keyboard` (chapter 7) exposes the machine half of the keyboard: a 64-bit
`keys` matrix-state input. The board half (milestone M1, `boards/ulx3s/`) must
set those bits from a real keyboard. The ULX3S has two USB host ports with
D+/D− wired to FPGA pins, so a USB-HID host core in the FPGA is the primary
path (a self-contained FPGA core, no ESP32 dependency — the standing rule
that the base machine works without an external MCU). The pinned
criteria mirror ADR-0003:

1. **License.** MIT-compatible with clean provenance. This is the criterion
   that killed A-Z80 (GPL) and it applies unchanged to board-level IP.
2. **Verilator suitability.** Verilog source; the single-simulator `-Wall`
   regime extends to `boards/` where practical (vendor code gets a scoped
   waiver like tv80).
3. **Fit.** Low-speed HID keyboard support, small footprint, no
   vendor-specific primitives, evidence of use with yosys/nextpnr on ECP5.

### Candidates

| Core | Language / license | Verdict against the criteria |
|---|---|---|
| **usbh_host_hid** (Emard, `ulx3s-misc`) | VHDL primary (vhd2vl-translated Verilog exists), **GPL** (header: `(c)EMARD License=GPL`; companion `usb11_phy` files also carry `License=GPL` markings on Usselmann-derived code; only minor helper files are BSD) | The ecosystem default — proven on the ULX3S in many retro cores (nes_ecp5, zx_spectrum, …). But GPL is incompatible with releasing this repository under MIT (same verdict as A-Z80, ADR-0003), and the primary source is VHDL, which breaks the single-simulator regime. Fails criteria 1 and 2. |
| **usb_hid_host** (nand2mario, `github.com/nand2mario/usb_hid_host`) | Verilog, **Apache-2.0** | Compact low-speed HID host (keyboards, mice, gamepads): <300 LUTs, <250 FF, 1 BRAM; explicitly avoids vendor-specific primitives; sample projects on ECP5 boards (IceSugar-Pro, Schoko) with yosys/nextpnr. Derived from hi631's work, relicensed and maintained by nand2mario (integration is three files: `usb_hid_host.v`, `usb_hid_host_rom.v`, `.hex`). Apache-2.0 is MIT-compatible (NOTICE/attribution preserved in `rtl/vendor/` + CREDITS.md, as with tv80). **Recommended.** |
| **hi631's original** (Tang Nano lineage) | Verilog, license unclear upstream | The ancestor of the above; nand2mario's repackaging *is* the cleaned, licensed form of it. Use that instead. |
| **PS/2 via GPIO** (own code) | our MIT | ~20 lines, robust; needs 5 V↔3.3 V level care. Kept as the bring-up fallback if USB proves fiddly — not the end goal (USB keyboards are what people own). |
| Own low-speed USB host | — | A worthwhile adventure (and chapter), wrong milestone. The `keys` seam keeps this option open forever. |

## Decision

Vendor **nand2mario/usb_hid_host** (Apache-2.0, pinned commit) into
`boards/ulx3s/vendor/usb_hid_host/`, unmodified, with upstream license text and
a provenance README — the tv80 pattern. Our own glue module translates the
core's HID keyboard reports into the 64-bit `keys` matrix state; that lookup
table (HID keycode → TRS-80 row/col, two SHIFTs on row 7, BREAK/CLEAR/arrow
mapping) is where the "physical key map" open item from chapter 7 is resolved,
and it is our code under MIT.

To verify during integration (not blockers, just facts to pin): required core
clock, which of the two ULX3S USB ports (US1/US2) is wired for host duty, and
report format quirks per keyboard. On ghosting: USB-HID rollover is better
than the original matrix — a feature, honestly documented.

## Consequences

- The board keyboard path stays MIT/Apache-only; no GPL enters the repo.
- `rtl/` remains board-agnostic: `m1_keyboard` never learns where `keys`
  comes from.
- The PS/2 fallback and the Model-1 matrix adapter (RetroStack keyboard
  projects, see [RESOURCES.md](../RESOURCES.md))
  remain open as parallel `boards/` paths; nothing here forecloses them.
