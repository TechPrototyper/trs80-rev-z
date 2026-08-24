# TRS-80 Rev Z — GitHub Codespace

A full TRS-80 Model 1 development environment in the cloud: the cycle-true
Verilator machine running headless, with the trszog debugger attached to it
as if it were physical FPGA hardware.

## What you get

- **The real RTL** (`m1_core`) evaluated dot-clock by dot-clock under Verilator
- **trszog** (DeZog fork) with the `revz` remote — F5 halts the live Z80,
  single-step, breakpoints, watchpoints, live screen panel, keyboard input
- **No board required** — the debug link runs over localhost TCP (port 5555)

## Setup (one-time, per codespace)

1. Place your Level II ROM at `roms/level2.hex`
   (see [`roms/README.md`](../roms/README.md) for provenance and identification)
2. Open the repository in a Codespace (this branch: `exp/codespace`)
3. The container builds the emulator automatically on first open (~5 min)

## Usage

| Action | How |
|--------|-----|
| Start the machine | Task: **"TRS-80: Start Machine"** (or it auto-starts on folder open) |
| Attach debugger | Select launch config **"TRS-80 Rev Z (Codespace FPGA)"**, press F5 |
| Stop the machine | Task: **"TRS-80: Stop Machine"** |
| Quick screen check | Task: **"TRS-80: Screen Dump"** (text-mode VRAM dump) |
| Rebuild after RTL changes | Task: **"TRS-80: Build Emulator"** |

### With zmac symbols (source-level debugging)

```bash
zmac -j myprog.asm    # produces zout/myprog.cmd + zout/myprog.bds
```

Then use the launch config **"TRS-80 Rev Z (with zmac symbols)"** and set
the `zmac` / `load` paths in `.vscode/launch.json`.

### With a disk image

```bash
bash .devcontainer/scripts/start_trs80.sh roms/level2.hex disks/newdos.dmk
```

Or pass any number of `.dmk` files as positional arguments.

## How it works

```
┌─────────────────────────────────────────────────────────┐
│  VS Code (browser)                                     │
│                                                        │
│  trszog extension ──JSON-RPC──► trszog_bridge.py       │
│       (F5, step,        port 49152      │              │
│        breakpoints)                     ▼              │
│                                    binary v0           │
│                                    TCP :5555           │
│                                        │               │
│                                        ▼               │
│                              Vm1_core (headless)       │
│                              --hidden --debug-tcp      │
│                              [full m1_core RTL]        │
│                              [m1_debug softcore]       │
└─────────────────────────────────────────────────────────┘
```

The same `launch.json` works unchanged against a physical ULX3S board —
only the `serial` value differs (`/dev/tty.usbserial-XXXX` vs `tcp:5555`).

## Limitations

- No audio (headless container; use `--sound-dump` for WAV capture)
- No SDL window (the trszog screen panel is your display)
- ROM must be provided by you (copyright — see `roms/README.md`)
- Simulation runs at ~0.7× real time on typical Codespace hardware
