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
| `--drive-sounds=<dir>` | (synth) | Use real recordings for the drive voices: `seek_step_trs80.wav`/`step.wav` (the arm's clack), `loaded-spin.wav`/`motor_trs80.wav`/`motor_loop.wav` (spindle loop) and `motor_spinup.wav`/`motor.wav` (one-shot spin-up whirr layered under motor start), WAV 16-bit any rate. The names deliberately cover trs80gp's `Resources` directory — `--drive-sounds=/Applications/trs80gp.app/Contents/Resources` plays George Phillips' reference recordings straight from your own trs80gp install (loaded in place, never copied or redistributed; measured reference: broadband 355–830 Hz spindle noise with a 5 Hz rotation wow, a 61 ms step clack centred at 0.9–1.4 kHz). Missing files fall back per-voice to the synthesizer; the repo ships no audio assets |
| `--no-drive-sounds` | off | Disable the drive sounds (four synthesized voices on the m1_drives event stream: per-drive detuned motor with spin-up and the one-shot's 3 s run-out, step clicks; all disks spin on the shared motor line). Fixed loudness relative to the program channel by design |
| `--sound-dump=<file>` | (none) | Mirror the program-sound output into a 44.1 kHz WAV (listen/measure without a remote-desktop audio path in the way) |
| `--cas-save=<file>` | (none) | Record what the machine writes: each motor-on stretch is decoded (500 baud) and saved as `.cas` bytes or a synthesized `.wav`; later saves get `-1`, `-2`, … suffixes |
| `--skin=<s>` | `none` | Monitor front: `grey` (first-series case, white P4 phosphor, red power key) or `green` (later revision: full smoked front plate, BRIGHT/CONTRAST/POWER knobs, P1 green). Photographic bezels of the real Tandy Video Display (`assets/skin_grey.jpg` / `skin_green.jpg`, CC-licensed Wikimedia Commons photos — provenance in CREDITS.md; if the assets aren't found, a procedural drawing takes over). The picture bends over a CRT vertex grid — a gentle outward bulge like the tube's glass (barrel, corners pinned) with a corner vignette — not perfectly straight, but straight enough |
| `--shot=<file>` | (none) | Save one rendered frame as BMP (at `--shot-at`, default frame 600) — works with `--hidden`, used for the skin verification shots |
| `--kbd=<layout>` | `us` | Host keyboard layout (`us` or `de`) — scancodes are physical, so this decides which legend a key produces (QWERTZ swaps Y/Z, `:` sits on shift+`.`, …) |
| `--debug-pty` | off | Expose the `m1_debug` binary-v0 link on a pseudo-tty. Known macOS quirk: on some launches with program sound active, the freshly started CoreAudio thread leaves the process's pty deaf from birth (bytes written to the slave never reach the master; per-launch, not per-access). Use `--debug-tcp` when scripting |
| `--debug-tcp=<port>` | off | Same binary-v0 link on a localhost TCP listener — the robust choice for scripted/CI use; `tools/trszog_bridge.py --serial tcp:<port>` and `tools/emu_screen_dump.py tcp:<port>` speak it directly. The emulator additionally implements the optional KEYS command (DEBUG-PROTOCOL.md): the debugger can inject keyboard-matrix reports, OR-ed with the SDL keyboard — this is what feeds trszog's revz screen view when the window runs `--hidden` |
| `--hidden` | off | No window on screen — scripted runs can't steal focus (a background test window once swallowed a whole chat message as TRS-80 keystrokes). Also mutes sound unless `--volume` is given explicitly: a hidden run is a scripted run, and two machines mixing live in one speaker once produced a memorably awful chord |
| `--click-pitch=<f>` | `1.0` | Playback-rate factor for the step voice (0.2–2.0). Samples play at native pitch by default; the bass fullness comes from a fixed 63 Hz chassis thump under every hit |
| `--pctrace=lo:hi:file` | off | Log every instruction-fetch PC in `[lo,hi]` (hex) to *file*, one `@xxxx` line each — diffable against `trs80gp -tr lo:hi` (this is how the NEWDOS lookup and aj6 boot divergences were root-caused) |
| `--enter-until=<frame>` | off | Hold ENTER from power-on until the given frame (some DOS mods skip boot prompts on a held ENTER) |

## Quick start

```
sim/emu/run.sh                       # boot to Level II BASIC
sim/emu/run.sh nd80aj6.dmk           # boot a disk (positional args -> --disk0..3)
sim/emu/run.sh game.dmk --skin=green # every --option passes through
```

The launcher builds the emulator if needed, finds the ROM (`TRS80_ROM`, else
a short candidate list), defaults to the grey photo skin, `--throttle=0.7`
(pinned pitch near the current real-time ceiling) and plays trs80gp's drive
recordings when the app is installed. Environment overrides: `TRS80_ROM`,
`TRS80_SKIN`, `TRS80_KBD` (QWERTZ users: `de`), `TRS80_THROTTLE`.
`Vm1_core --help` prints the full option summary.

## Debugging with DeZog (`--debug-tcp` / `--debug-pty`)

The emulator build includes the full debug core (`m1_debug`, ADR-0006).
`--debug-tcp=<port>` exposes its binary-v0 byte stream on a localhost TCP
listener (the robust choice — see the macOS pty note in the option
table); `--debug-pty` puts the same stream on a pseudo-tty, the
emulator-side stand-in for the board's FTDI serial port.

The full loop with trszog's `revz` remote (ADR-0007):

```
sim/emu/run.sh --hidden --volume=0 --debug-tcp=5555
```

launch.json (trszog starts the bridge for you):

```jsonc
"remoteType": "revz",
"revz": {
    "transport": {
        "kind": "python",
        "serial": "tcp:5555",       // or the pty path / the board's FTDI device
        "bridge": "/path/to/trs80-rev-z/tools/trszog_bridge.py",
        "autoStart": true
    }
}
```

Same protocol, same bridge, same launch.json as the physical board —
only the `serial` value differs. On top of the debugger basics the
session gets a live **screen view** in VS Code (the panel polls the text
VRAM; with this emulator's non-intrusive reads the polling costs the
machine zero CPU cycles) and a **keyboard**: typing into the panel
injects the matrix via the KEYS command. Games are fully playable in
the panel while the SDL window runs `--hidden`.

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

- **CRT bezel skin — shipped as `--skin=grey|green`** (procedural
  drawing + barrel-warped vertex grid). Possible refinements: photo
  textures instead of the procedural front, scanline/bloom shading,
  a soft power-on fade.
