# TRS-80 Rev Z — Interactive Verilator Emulator (`sim/emu/`)

This directory builds a self-contained interactive emulator that runs the full
`m1_core` RTL simulation under Verilator **without any FPGA hardware**.

| ULX3S board module | Emulator replacement |
|--------------------|----------------------|
| `m1_scan_fb.v` + DVI stack | `emu_display.cpp` — SDL2 window (384×192 × scale) |
| `m1_hid_keys.v` + USB host | `emu_keyboard.cpp` — SDL2 keyboard events |
| `m1_dmk_fetch.v` + `m1_sd_fs.v` + `sd_spi_host.v` | `emu_disk.cpp` — DMK files from the host filesystem |
| `m1_cass_sd.v` (SD tape deck) | `emu_cass.cpp` — .cas/.wav files from the host filesystem |
| `m1_pll.v` | Fixed Verilator clock (optionally throttled to 10.6 MHz) |

No RTL is modified.  The existing `sim/tb_*.sv` tests remain unaffected.

## Prerequisites

```
# Debian / Ubuntu
apt install libsdl2-dev

# macOS (Homebrew)
brew install sdl2
```

Verilator (≥ 5.x) is already installed as part of oss-cad-suite.

## Build

```
cd sim/emu
make
```

This produces `build/emu/Vm1_core`.

## Running

```
./build/emu/Vm1_core --rom=/path/to/rom.hex
./build/emu/Vm1_core --rom=/path/to/rom.hex --disk0=/path/to/newdos.dmk
```

Or via Make:

```
make run ROM=/path/to/rom.hex DISK0=/path/to/newdos.dmk
```

### ROM image

The Level II ROM (12 KiB) is **not** included in this repository — see
`roms/README.md` for provenance and identification.  The file must be in
Verilog `$readmemh` format (one hex byte per line, no address tags).

### DMK disk images

Standard DMK binary files (raw bytes, not the hex format used internally by
the testbenches).  Pass with `--disk0` … `--disk3`.  The hardware supports
drives 0–3 only; drive numbers above 3 do not exist.

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `--rom=<file>` | *(required)* | 12 KiB Level II ROM in `$readmemh` hex format |
| `--disk0=<file>` | (none) | DMK image for drive 0 |
| `--disk1=<file>` | (none) | DMK image for drive 1 |
| `--disk2=<file>` | (none) | DMK image for drive 2 |
| `--disk3=<file>` | (none) | DMK image for drive 3 |
| `--wp0` … `--wp3` | off | Force write-protect on the drive |
| `--scale=<n>` | `2` | SDL2 window pixel scale (2 = 768×384, 3 = 1152×576) |
| `--throttle[=f]` | off | Pace the simulation: `--throttle` = real time, `--throttle=0.6` = a constant 0.6× machine. The model tops out ≈ 0.75× on current hosts, so pinning a sustainable factor gives a rock-steady pace — and with it rock-steady audio pitch |
| `--no-ei` | off | 16K machine (no Expansion Interface or FDC) |
| `--ei16` | off | 32K machine |
| `--ei32` | **default** | 48K machine (full Expansion Interface) |
| `--cas=<file>` | (none) | Insert a cassette: `.cas` (pulses synthesized at 500 baud) or `.wav` (Z4 detector: peak-relative threshold + hysteresis + refractory). Motor-gated by port 0xFF D2 |
| `--cas-baud=<n>` | `500` | Baud rate for `.cas` pulse synthesis |
| `--no-sound` | off | Disable program sound (default: the cassette output ladder — the Model 1's only voice — plays through SDL audio) |
| `--volume=<n>` | `60` | Program-sound volume 0–100. Applies to the program channel only; drive sounds (M7 stage 2) will keep a fixed period-correct loudness relative to it |
| `--no-drive-sounds` | off | Disable the drive sounds (four synthesized voices on the m1_drives event stream: per-drive detuned motor with spin-up and the one-shot's 3 s run-out, step clicks; all disks spin on the shared motor line). Fixed loudness relative to the program channel by design |
| `--sound-dump=<file>` | (none) | Mirror the program-sound output into a 44.1 kHz WAV (listen/measure without a remote-desktop audio path in the way) |
| `--cas-save=<file>` | (none) | Record what the machine writes: each motor-on stretch is decoded (500 baud) and saved as `.cas` bytes or a synthesized `.wav`; later saves get `-1`, `-2`, … suffixes |
| `--kbd=<layout>` | `us` | Host keyboard layout (`us` or `de`) — scancodes are physical, so this decides which legend a key produces (QWERTZ swaps Y/Z, `:` sits on shift+`.`, …) |
| `--debug-pty` | off | Expose the `m1_debug` binary-v0 link on a pseudo-tty |
| `--pctrace=lo:hi:file` | off | Log every instruction-fetch PC in `[lo,hi]` (hex) to *file*, one `@xxxx` line each — diffable against `trs80gp -tr lo:hi` (this is how the NEWDOS lookup and aj6 boot divergences were root-caused) |
| `--enter-until=<frame>` | off | Hold ENTER from power-on until the given frame (some DOS mods skip boot prompts on a held ENTER) |

## Debugging with DeZog (`--debug-pty`)

The emulator build includes the full debug core (`m1_debug`, ADR-0006).
With `--debug-pty` its binary-v0 byte stream is exposed on a pseudo-tty —
the emulator-side stand-in for the board's FTDI serial port. The slave
path is printed at startup:

```
emu_debug: binary-v0 debug link on /dev/ttys012
```

Point the unchanged reference bridge at it:

```
python3 tools/trszog_bridge.py --serial /dev/ttys012
```

and attach DeZog/trszog exactly as for the physical board (ADR-0007's
`revz` remote; the baud rate is meaningless on a pty). Same protocol,
same bridge, same launch.json — only the device path differs.

## Keyboard mapping

Matches `boards/ulx3s/rtl/m1_hid_keys.v` — glyph-faithful, not
position-faithful.

| PC key | TRS-80 key |
|--------|------------|
| A–Z | A–Z |
| 0–9 | 0–9 |
| Shift+2 | @ (unshifted) |
| Shift+8 | \* (Shift+:) |
| Enter | ENTER |
| Backspace | LEFT (erase) |
| Esc | BREAK |
| Home | CLEAR |
| Arrow keys | UP / DN / LT / RT |
| `=` | Shift+- (equals) |
| Shift+`=` | Shift+; (plus) |
| `;` | ; (unshifted) |
| Shift+`;` | : (unshifted) |

Keys with no Model I equivalent (`^`, `_`, `[`, `]`, `\`) are silently
ignored. **F12** presses the front-panel RESET button (held = the Z80
reset line grounded, like the real button on the keyboard unit).

The matrix is rebuilt from the complete SDL keyboard state once per
frame ("current report wins" — the same architecture as
`m1_hid_keys.v`), so shift-translated chords cannot leave stuck keys
behind, regardless of release order.

## Backlog / ideas

- **CRT bezel skin.** Project the 384×192 frame into a photographed
  TRS-80 Model 1 monitor, with barrel distortion like a real tube. Two
  skins: the original grey monitor (white phosphor, red power key) and
  the later revision (green phosphor, bezel, three front knobs).
