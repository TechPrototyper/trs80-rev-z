# Vendored: usb_hid_host (nand2mario)

Compact low-speed USB HID host core — keyboards, mice, gamepads. Selected in
[ADR-0004](docs/decisions/0004-usb-hid-host-core.md).

- Upstream: <https://github.com/nand2mario/usb_hid_host>
- Author: nand2mario (based on work by hi631), 2023
- License: **Apache-2.0** (see `LICENSE` in this directory)
- Pinned commit: `678b0137bd32d1ca99fb2d48865f4eb1df712c4e` (2025-03-22)
- Files: `usb_hid_host.v`, `usb_hid_host_rom.v`, `usb_hid_host_rom.hex`
  (the UKP microcode ROM), **unmodified**.

Requirements: 12 MHz `usbclk` (provided by `m1_pll_dvi` clkout2), D+/D−
wired to bidirectional pads with host-side 15K pull-downs (on the ULX3S,
US2's `usb_fpga_bd_dp/dn` with the `usb_fpga_pu_*` pins driven low).

The translation from the core's HID keyboard reports to the TRS-80 keyboard
matrix is our own code in `../../rtl/m1_hid_keys.v` (MIT, like the rest of
the repository).
