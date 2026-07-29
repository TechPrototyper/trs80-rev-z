# Roadmap

Two tiers, honestly labeled. **Committed** means: specified in
[docs/SPEC.md](docs/SPEC.md) and actively built toward — not a promise of dates. The
whole base machine now sits in this tier and is verified: it boots TRSDOS 2.3 from SD
card to `DOS READY` on the physical board. **Vision** means the direction — the
reasoning is real, the specification is deliberately still open.

---

## Where it stands (2026-07-29)

The base system is functional: chapters 1–8 (the machine core) plus the Expansion
Interface with the full FDC chain, all golden-verified, and the whole thing boots
all tested OS from SD card on the ULX3S. On top of that, the debug core and its
editor integration ([ADR-0006](docs/decisions/0006-debug-architecture.md),
[docs/DEBUG-PROTOCOL.md](docs/DEBUG-PROTOCOL.md)) is my quiet pride — 
pulled forward from the Vision tier because a machine you can hold, inspect,
and single-step is the best test instrument for everything that follows, and, of course
closes the loop to my original impulse: use a modern toolchain to develop and debug
software on the TRS-80 as a first class citizen in VS Code.
You actually can press F5 right in Visual Studio Code with your Z-80 Aseembly Language
source code on your screen and single-step on the real hardware using the TRS-80 Rev Z,
your ULX3S-85F FPGA board and the finest Z-80 Debugger available for your
VS Code Environment, the TRS-80 edition of maziac's [DeZog](https://github.com/TechPrototyper/trszog)
How cool is that!!!!!

Everything above is re-runnable: `cd sim && make` for the testbenches, the
`make golden*` targets for the byte-exact comparisons (they need a local
trs80gp), `cd boards/ulx3s && make bit` for the bitstream. If your run
disagrees with a checkmark, please open an issue — the checkmark is wrong
until proven otherwise.

**Next up, in that order:** finish Cassette (M2 — the last gap in the base
machine), then RS-232-C (M5), then Centronics (M6). See below for what
"finish" means precisely for each.

---

## Committed Tier

### M1 — Level II BASIC prompt (simulation first, then silicon)

The machine boots to `MEM SIZE?` — first in the Verilator harness with byte-exact
VRAM comparison against trs80gp, then on the ULX3S over HDMI with a USB keyboard.

- [x] Verilator harness running (first testbench + VCD waveforms — see
      [chapter 1](docs/chapters/01-clock-and-dividers.md)); frame dumps render to
      PNG since chapter 2 (`make frames`); byte-exact golden-model diff against
      trs80gp wired up in chapter 5 (`make golden`)
- [x] Clock generation from the 10.6445 MHz master (÷6 CPU clock enable, dot clock),
      derived from the schematics — verified in simulation (chapter 1)
- [x] Video counter chain: character/scanline/row counters, both screen formats,
      HDRV/VDRV blanking taps — verified against the documented timing:
      672 dots = 112 T-states/line, 264 lines, 60.0001 Hz frame rate (chapter 1)
- [x] Character generator & shift path (Video Latch / VideoGen): data latches,
      sneaky bit 6, MCM6670P glyphs, block graphics, VCLR* streaks — every dot of a
      full frame verified against an independent model in both screen modes
      ([chapter 2](docs/chapters/02-character-generation.md))
- [x] VRAM arbitration with authentic CPU-priority behavior (**snow**, Z1): three
      muxes, seven 2102s, no WAIT — the CPU wins instantly, streaks emerge
      subtractively, and blanking-timed accesses leave no trace (the beam-hack
      property, SPEC §6) — verified per dot under CPU fire
      ([chapter 3](docs/chapters/03-vram-and-arbitration.md))
- [x] Model 1 address decode (ROM A/B $0000–$2FFF, open bus $3000–$37FF,
      KBD $3800 with mirrors, VRAM $3C00, RAM $4000–$7FFF, MEM* read gating) —
      all 262 144 decoder states verified exhaustively against the SPEC §3 map,
      plus 16-bit bus cycles through to the video RAM
      ([chapter 4](docs/chapters/04-address-decoder.md))
- [x] Z80 core integration (**tv80**, vendored — [ADR-0003](docs/decisions/0003-z80-core-selection.md)),
      1.774 MHz, driving the decoder and strobe layer (RAS*/RD*/WR*/IN*/OUT*, TEST*,
      DBIN*/DBOUT*, HALT→NMI). A hand-assembled test program runs from ROM and draws
      the screen; **VRAM verified byte-exact against trs80gp** (`make golden`,
      1024/1024 cells, incl. the HALT→NMI marker) — SPEC §6 milestone
      ([chapter 5](docs/chapters/05-z80-integration.md))
- [x] Level II 1.3 ROM loaded at runtime (never bundled), real ROM/RAM separation
      — `m1_sd_fs` mounts a FAT32 SD card and loads `TRS80/LEVEL2.ROM` behind a
      second reset (own SPI host + streaming FAT reader, no vendored FS core);
      simulation-proven (`tb_sd_loader`, byte-exact across a fragmented cluster
      chain) and verified on the board (LED reports the load; the self-test
      banner is the no-card fallback)
- [x] Port 0xFF: video 64/32 **mode select** (MODESEL) + cassette output/motor latch
      + IN read-back (`m1_io.v`). CPU mode-switch verified byte-exact vs trs80gp;
      closes chapter 1's MODESEL item. Cassette *analog* path is M2
      ([chapter 6](docs/chapters/06-io-ports.md))
- [~] Keyboard matrix (`m1_keyboard.v`): the 8×8 read-as-memory matrix is done and
      verified — exhaustive unit test + byte-exact vs trs80gp `-ik` (SPACE, 'A')
      ([chapter 7](docs/chapters/07-keyboard.md)). USB-HID front end implemented
      and simulation-proven (nand2mario `usb_hid_host` vendored per
      [ADR-0004](docs/decisions/0004-usb-hid-host-core.md), glyph-true
      HID→matrix map in `m1_hid_keys`, `tb_hid_keys`); remaining: verification
      with a physical keyboard on the board's US2 port
- [x] Whole machine composed into one synthesizable module (`m1_core.v`) — the
      bus mux + all seven blocks; the full-system golden test runs through it and
      it synthesizes clean for the ECP5 (`make synth`, 0 problems, ~20k LUT of 84k)
      ([chapter 8](docs/chapters/08-integration.md))
- [x] Memory → EBR and place & route: registered reads steer all four memory
      arrays into DP16KD block RAM (16/208, logic down to 3%), nextpnr-ecp5
      closes timing at 63.24 MHz vs the 10.6445 MHz dot clock — testbenches and
      golden unchanged and green ([chapter 8 §5](docs/chapters/08-integration.md))
- [x] ULX3S bring-up: board top-level around `m1_core` — PLL, DVI out (own
      capture framebuffer + TMDS encoder, decode-identity proven), USB-HID →
      `keys`, power-on self-test, SD-card ROM loader. Verified on the physical
      board: the machine comes up over HDMI and boots TRSDOS from SD
      (2026-07-25); buttons: warm reset + cold-start "power" button with
      SD re-init

### M2 — Cassette

- [ ] Cassette interface per schematic (Z4 filter/rectifier/level-detector →
      cassette-input edges; the 2-bit output ladder into R53–R56 + motor
      relay consumer — the open items from
      [chapter 6](docs/chapters/06-io-ports.md)); `.cas`/WAV on the SD card
- [ ] Machine-language round-trip: the existing assembly-language WAV corpus
      loads correctly (read path only — these files already exist)
- [ ] BASIC round-trip: `CSAVE` writes a WAV, `CLOAD` reads it back
      byte-exact (write path, too — no assembly-only corpus covers this)
- [ ] TBUG/`SYSTEM` round-trip: a TBUG-written machine-code tape (SYSTEM
      format, distinct from BASIC's tokenized format) loads via BASIC's
      `SYSTEM` command — the executable-loading path most period software
      actually shipped on
- [ ] Acceptance test: a known-good machine-language game loads from virtual tape

### M3 — Expansion Interface & floppy (the long pole)

- [x] **32 KB expansion RAM** (`m1_ei_ram`, ADR-0005 stage 1): 16K/32K/48K
      systems switchable at run time (ULX3S DIP), unpopulated banks float the
      bus like the real EI; module bench + 48K system bench + byte-exact
      golden vs `trs80gp -m1 -mem 48` (`make golden-ram`), 16K golden unchanged
- [x] **EI container** (`m1_ei`): 0x37E0–0x37EF decode, 40 Hz heartbeat
      interrupt, drive-select latch with ~3 s motor one-shot, 1 MHz enable via
      phase accumulator (ADR-0005) — byte-exact golden (`make golden-ei`)
- [ ] EI (final PCB generation) incl. RAS*/MUX/CAS* behavior on a real bus
- [X] **Dual-controller FDC**: WD1771 Type I–III complete — seek/step, Read
      Sector/Address, Write Sector with CRC16 in RTL and dirty-track
      write-back to the SD card, Read Track (raw) and Write Track (format) —
      plus the WD1791 MFM personality behind the Percom Doubler latch at the
      true 32 µs/byte cadence; every stage has its own byte-exact golden
      against trs80gp (`make golden-fdc`, `-rd`, `-wr`, `-trk`, `-dd`).
      Still open: the Tandy 26-1143 density-switch protocol as an
      additionally decodable variant. As I owned a clone of the Percom Doubler,
      I might actually leave that to a contributor if desired!
- [x] **Mixed-density disks** — SD boot track, DD elsewhere, per-track density
      (**DMK** format; JV1 is structurally insufficient): the DD golden reads
      the SD track and the MFM track of the *same* disk, writes DD, and proves
      the density filter (an all-MFM track is invisible to the SD personality)
- [X] TRSDOS and NEWDOS/80 boot — **TRSDOS 2.3 boots to `DOS READY`**, byte-exact
      in the golden harness (`make golden-boot`) *and* on the physical board
      from SD card; NEWDOS/80 2.0 boots nicely, too.

### M4 - the softcore debugging "dongle" "sitting" on the TRS-80 Model 1 40-pin expansion port.

- [X] **Debug core.** A softcore (RISC-V) beside the Z80 speaking a VS-Code-debuggable
      protocol ([docs/DEBUG-PROTOCOL.md](docs/DEBUG-PROTOCOL.md)): hardware breakpoints, memory inspection without stopping the Z80,
      single-step. The bridge between 1980 hardware and a modern IDE (via [trszog](https://github.com/TechPrototyper/trszog), which supports this debug protocol). The board's 32 MB
      SDRAM would serve this rather than inflating the machine: a **flight recorder**
      (gapless bus-cycle trace, minutes deep — reverse debugging on 1980 hardware),
      **machine snapshots/rewind**, and a RAM-resident disk-image library. The flight
      recorder would export standard **VCD/FST** — real-hardware traces opening in the same
      waveform tools as the Verilator traces, making the two *diffable*: golden-model
      verification extended to actual silicon. The Z80 itself stays 48 K — the surplus
      power works *for* the small machine, never inside it.

### M5 — RS-232-C

- [ ] UART register model at 0xE8–0xEB (ADR-0005 §6), line side routed to
      the ULX3S's FTDI UART
- [ ] **Independently configurable TX/RX baud rate** — the period-authentic
      feature (e.g. 1200 baud receive / 75 baud send, a common split-speed
      viewdata-style link of the era); a single shared-baud modern UART
      core is not an acceptable substitute. How genuinely asymmetric rates
      map across the single-rate FTDI USB-serial hop is an open design
      question — the register-level model on the TRS-80 side must be
      correct regardless of how that hop resolves it (see ADR-0005 §6).
- [ ] Golden reference: trs80gp `-r`

### M6 — Centronics (line printer)

- [ ] Register side at 0x37E8 (data latch + ready status) — keeps
      `LPRINT`/`LLIST`/DOS from hanging even with nothing attached
- [ ] SD-card spool sink (ADR-0005 §7): `TRS80/LINEPRINTER_OUTPUT/`,
      plain text, append-only; a new file opens after ~5 minutes of print
      inactivity, and the file additionally rotates daily
- [ ] Golden reference: trs80gp `-p`
- [ ] Vision, not committed: a real GPIO Centronics port for period
      printers. USB host printer support is not planned — the SD spool is
      the primary and likely permanent sink.

---

## Vision (direction, no promises)

Each of these follows the Rev-Z rule: off = bit-exact stock machine. They're written
down so the direction is public — not because I know when, or whether, I'll get there.


- **Audio.** Floppy Drive seek/spindle and keyboard sounds, each with on/off toggles —
 the machine you *hear*.
- **Virtual expansion-card bus.** The Model 1 edge connector as an internal, arbitrated
  bus with virtual "slots" — the Apple II/IBM-PC idea the TRS-80 never got, though the
  aftermarket built bus splitters that pointed exactly this way. Research on historical
  precedents ongoing.
- **TRS-IO / FreHD.** WiFi, RetroStore, virtual hard disk (WD1010 at $C8–$CF) — via ESP32
  integration, compatible with the existing TRS-IO ecosystem.
- **PCG-80 / 80-GRAFIX (Z9).** The one Model 1 hi-res path with a real software base:
  programmable character generator. Reference implementations exist (PACE, trs80gp).
- **Raster interrupt + scanline status (Z8).** Not a historical device — but the
  precisely documented *lack* (per George Phillips' beam-hack write-ups) that made Model 1
  beam-synced graphics needlessly painful. Rev Z would supply it; the beam hacks
  themselves must already work on the stock timing (that's an M1 acceptance criterion,
  not a feature).
- **CP/M package (Z10/Z11).** Two layers: faithful **Omikron mapper** emulation so
  original, unmodified CP/M distributions boot (preservation); and a **Rev-Z 64 KB
  board** — 16 KB at $0000–$3FFF, phantom boot ROM, banked I/O window — for the full-TPA
  CP/M the Model 4 later delivered. Source material secured; no priority.
- **Holmes Sprinter turbo mode.** A period speed-up board (Holmes
  Engineering, 1981, ~$99.50) that switches the Z80 clock. Real historical
  hardware, and mechanically cheap in this architecture — likely just a
  second, switchable `cen` divider (ADR-0001) rather than new circuitry. No
  ADR yet; surfaced during the MiSTer-core comparison (RESEARCH.md §6).
- **MIDI/80.** A modern (2024/2025) homebrew sound/MIDI interface card for
  the Model 1/III/4 that rides the RS-232 port address space. Deferred —
  needs first-hand evaluation (already available in trs80gp) before any
  commitment; likely needs no dedicated hardware work once RS-232-C (M5)
  exists, since it is "just" another RS-232 peripheral.
- **Enclosure.** A Model-1-styled case for the ULX3S. Last, and with love. Inspired by
  [RetroStack](https://github.com/RetroStack/).

---
