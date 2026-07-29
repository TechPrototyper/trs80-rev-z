# Resources

Links, not copies: Tandy documentation and third-party manuals remain under their
copyrights. This list identifies each source precisely enough to find it in the canonical
archives.

## Primary documentation (Tandy / Radio Shack)

| Document | Identification |
|---|---|
| TRS-80 Micro Computer Technical Reference Handbook, **2nd edition** | 1982 — the Rev G reference; full schematic set |
| TRS-80 Technical Manual: Theory / Parts / Schematics | 1978 — theory of operation, section by section |
| TRS-80 Technical Manual: Troubleshooting | 1978 |
| Expansion Interface Service Manual | 1979, cat. 26-1140 (first generation) |
| Expansion Interface Service Manual **[Redesigned PCB]** | final generation — our EI reference |
| Level II BASIC ROM Kit Service Manual | cat. 26-1120 |

Canonical archives: **Ira Goldklang's TRS-80 Revived Site** (trs-80.com),
**trs-80.org** (Matthew Reed), archive.org.

## Machine-readable hardware sources

- **RetroStack — TRS-80-Model-I-G-E1** (github.com/RetroStack/TRS-80-Model-I-G-E1, MIT):
  KiCad recreation of the Rev G mainboard, one sheet per subsystem (clock, CPU, address
  decoder, RAM/ROM interface, keyboard, cassette, card-edge interface …), including a
  documented errata list of the original board. Cross-check against the Tandy originals.
- **RetroStack — TRS-80-Model-I** (github.com/RetroStack/TRS-80-Model-I, hub for
  their Model 1 ecosystem, essentially all MIT). Beyond the Rev G recreation above,
  the org carries: mainboard replicas of **six revisions** (A, D, E, G, two Japanese
  variants) · an **Expansion Interface Rev D** replica · keyboard projects (ALPS
  replica PCB, modern MX replacement, TEC/Tandy adapter) · **3D-printable Model 1
  parts** and a **65%-scale Mini Monitor case** for 8″ LCDs — the obvious starting
  points when rev-z gets an enclosure · a Character Generator Adapter plus a
  character-ROM collection (candidate source for mask-exact glyph verification,
  provenance to be checked — see chapter 2 open items) · an Arduino library and
  **test harness for exercising a real Model 1** — interesting for hardware
  bring-up cross-checks · shared KiCad symbol/footprint libraries.
- **RedskullDC — TRS-80-Omikron-Mapper**: Omikron mapper archive — original manual, boot
  ROM dumps + disassembly, CP/M boot disk images. (Z10 source material.)
- **Jeff Sponaugle — Supermodel1** (github.com/jeffsponaugle/supermodel1, **MIT**):
  a replacement Model 1 motherboard in real silicon (through-hole, Z80 DIP-40, ATF150x
  CPLDs) — deliberately *enhanced*: banked 512K SRAM/flash, 1–16 MHz, 80×24 and bitmap
  video, RTC, VGA/NTSC, while staying compatible with the original keyboard and the
  original Expansion Interface edge port. Effectively another author's independent answer
  to "what would an improved Model 1 look like" — direct input for the Rev-Z discussion,
  and MIT-licensed CPLD address-decode logic as a cross-reference. Also contains a large
  character-font collection and a substantial datasheet/document library.
- **Arno Puder — NextTRS** (github.com/apuder/NextTRS, unlicensed → reference only):
  abandoned 2022 KiCad design for an FPGA (Tang Nano 20K) + ESP32 TRS-80 board with a
  real **50-pin expansion edge connector** — including KiCad footprints/connector
  libraries for the Model 1 *and* Model 3 edge (`EDGE50`, `TRSEDGE`, `trs-io-m1/-m3`).
  Machine-readable physical pinout of the expansion bus; architecture precedent for the
  FPGA+ESP32+edge trinity. Pinouts are facts of the hardware; the design files themselves
  are not reused.

## People whose published work this project stands on

This project would not have been possible without many individuals hard work over years. The following is a reference to the people most relevant without this project would not have been possible, and their primary contributions to the community: 

| Who | What |
|---|---|
| **George Phillips** | [48k.ca](https://48k.ca) — trs80gp (primary golden model), beam-hack/timing write-ups, Model 1 video timing numbers, zmac Macro Assembler, documentation and inspiration |
| **Tim Mann** | [tim-mann.org](https://www.tim-mann.org) — xtrs, disk format documentation (DMK/JV1/JV3), the 1771/179x DAM analysis, TRS-80 FAQ |
| **Ira Goldklang** | [trs-80.com](https://www.trs-80.com) — the archive |
| **Matthew Reed** | [trs-80.org](http://www.trs-80.org) — peripheral and revision history (doublers, hi-res boards, lowercase kits) |
| **Mark McDougall** | PACE — most faithful Model 1 HDL to date, the only PCG-80 implementation; [github.com/tcdev42](https://github.com/tcdev42) · [retroports.blogspot.com](https://retroports.blogspot.com) |
| **Brad Robinson** | big80 + article series explaining the design reasoning; [github.com/toptensoftware](https://github.com/toptensoftware) · [toptensoftware.com](https://www.toptensoftware.com) |
| **Lawrie Griffiths** | First TRS-80 cores running natively on the ULX3S; [github.com/lawrie](https://github.com/lawrie) |
| **Goran Mahovlić** | The ULX3S board itself and the Radiona (Zagreb) ecosystem around it; [github.com/goran-mahovlic](https://github.com/goran-mahovlic) |
| **Daniel Wallner** | T80 — the Z80 core everyone stands on |
| **Guy Hutchison** | TV80 — Verilog translation of the T80 Z80 core originally written in VHDL by Daniel Wallner |
| **Arno Puder** | TRS-IO / RetroStore (GPL-3.0), PocketTRS (ESP32 Model III/4 incl. a software model of the 50-pin expansion interface), NextTRS, TRS-80-Arduino (I/O-bus tutorial); [github.com/apuder](https://github.com/apuder) |
| **Jeff Sponaugle** | Supermodel1 — enhanced replacement Model 1 motherboard (MIT), real-silicon counterpart to this project's Rev-Z idea; [github.com/jeffsponaugle](https://github.com/jeffsponaugle) |
| **RetroStack** | Rev G hardware replica in KiCad; [github.com/RetroStack](https://github.com/RetroStack) |
| **RedskullDC** | Omikron mapper archive (manual, ROMs + disassembly, boot disk); [github.com/RedskullDC](https://github.com/RedskullDC) |

## Communities

The TRS-80 ecosystem is distributed across traditional forums, project-specific groups, Facebook, Discord, events, and FPGA-development communities. Forums and repositories are best for durable technical discussions; Facebook and Discord are often better for reaching active users, emulator authors, collectors, and hardware owners quickly.

- **[VCFed — Tandy/Radio Shack Forum](https://forum.vcfed.org/index.php?forums/tandy-radio-shack.59/)** — Broad and technically experienced vintage-computing community. Particularly useful for hardware behaviour, repairs, undocumented details, peripherals, and historical questions.

- **[TRS-80.com](https://www.trs-80.com/)** — Major TRS-80 archive and news site covering machines, software, documentation, emulators, disk formats, preservation projects, and modern developments.

- **TRS-80 Facebook groups** — Several active groups cover the Model I/III/4 family, games, repairs, software preservation, emulators, and the wider Tandy ecosystem. These are often the fastest way to locate original-hardware owners and people with highly specific practical experience.

- **TRS-80 Discord servers** — General and project-specific servers provide direct access to developers, emulator users,
collectors, and hardware specialists. Relevant conclusions should subsequently be documented in a repository, issue tracker, or forum because Discord discussions are difficult to preserve and cite.

- **[Tandy Assembly](https://www.tandyassembly.com/)** — The principal recurring gathering for the wider Tandy and Radio
Shack computer community. Useful for personal contacts, demonstrations, original-hardware testing, technical talks, and contact with long-term users and developers.

- **Emulator communities** — Projects such as `trs80gp`, SDLTRS, xtrs, MAME, browser emulators, and related disk or
 cassette utilities each have their own repositories, issue trackers, Facebook groups, or Discord channels. Emulator-specific findings should be discussed with the corresponding maintainers rather than only in general TRS-80 groups.

- **[TRS8BIT](http://www.trs-80.org.uk/) and [TRS-80 Trash Talk](https://trs80trashtalk.com/)** — Newsletter and podcast channels for longer technical reports, historical material,
 interviews, project announcements, and contact with established members of the TRS-80 community.

- **[ULX3S / Radiona](https://ulx3s.github.io/)** — Board-specific community around ULX3S, ECP5 development, SDRAM,
 video, programming, and open FPGA projects. Communication takes place through GitHub, Discord, Gitter, and Radiona community channels.

- **Yosys / nextpnr / Project Trellis** — The relevant development communities for synthesis, ECP5 technology mapping
 (Project Trellis), place-and-route, timing, and bitstream-generation problems. Technical issues should normally be reduced to a reproducible HDL example and reported through the appropriate repository or YosysHQ discussion channel.

- **[MiSTer community](https://www.retr0bright.com/mister.html)** — Large forum, Discord, and developer ecosystem for 
  FPGA recreations of historical systems. MiSTer is not a primary target of this project, but the community becomes
 relevant for later portability, integration, packaging, and compatibility discussions; see [GOVERNANCE.md](../GOVERNANCE.md).

Because Facebook groups, Discord servers, and invitation links change frequently, their current names and links should be maintained in a separate community registry rather than embedded permanently in this document.


## Tools

- **trs80gp** (48k.ca) — golden model; also documents PCG-80 (`-pcg-80`)
- **xtrs / MAME** — second opinions, doubler logic reference
- **zmac** — Z80 assembler used for test programs
- **yosys · nextpnr-ecp5 · prjtrellis · openFPGALoader/fujprog** — synthesis to bitstream
- **Verilator + GTKWave** — the verification workhorses


## Miscellaneous

- **[Willus Big List of TRS-80 Software](https://willus.com/trs80/?q=)** - the most comprehensive archive of TRS-80 stuff that I am aware of.