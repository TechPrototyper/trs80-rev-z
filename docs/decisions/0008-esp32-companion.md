# ADR-0008 — The ESP32 companion: one services host, sorted before it sprawls

**Status:** proposed · 2026-07-26

## Context

Several planned features all want to live on the ULX3S's on-board ESP32,
and they arrived at that conclusion independently:

- the **debug server** (the JSON-RPC ⇄ binary-v0 translation of
  [ADR-0006](0006-debug-architecture.md)/[ADR-0007](0007-trszog-integration.md),
  moved off the PC so debugging is untethered over WiFi);
- **disk sources** — floppy/hard-disk images not only from the SD card but
  from a configurable server (LAN or S3/MinIO), with a small web tool that
  assigns images to drives `:0`–`:3`; later FreHD-style virtual hard disks;
- **telemetry / monitoring** over MQTT (a dashboard of what the machine is
  doing);
- **drive-sound emulation** — the FPGA emits events (step + direction,
  drive-select, motor on/off, R/W gate); the ESP32 mixes samples over I²S,
  authentic separate speakers for drives vs. music;
- **network printing** for the Centronics port (post-M3);
- **settings + a web UI** to configure all of the above;
- ecosystem compatibility (**TRS-IO / RetroStore / network card**, Arno
  Puder's world) that also targets an ESP32 on the same bus.

That is a thicket. Bolted on feature by feature it becomes an unmaintainable
tangle of half-owned resources — which is exactly why this ADR exists
*before* any ESP32 firmware: to sort the services, name the one shared
resource that will bite (the SD bus), and fix the seams, so the firmware is
built against a structure instead of growing into one. It is a direction
document; nothing here is built yet.

## Decisions

### 1. The base machine never depends on the ESP32 (the companion rule)

The TRS-80 is complete without the ESP32 — it boots TRSDOS from SD, debugs
over the FTDI serial link, and outputs cassette audio through the FPGA's own
DAC, all with the ESP32 held in reset (`wifi_en = 0` today). The ESP32 is
**additive**: every service it hosts is an enhancement of a machine that
already works, never a crutch it needs. This is the same rule that keeps the
USB keyboard and the debug core self-contained (ADR-0004, ADR-0006).

Corollary — what stays in the FPGA, never on the ESP32: the cassette analog
output (the ULX3S has an audio DAC; `cass_out` goes straight out), the debug
*mechanism* (halt/breakpoint/memory — the ESP32 only serves the protocol),
and the FDC/track logic. The ESP32 is a companion, not the machine.

### 2. One FPGA↔ESP32 link, one owner, typed frames

There is a single physical link between the FPGA and the ESP32, and on the
ESP32 side a **single link-owner** task. Everything the two chips exchange is
a typed frame multiplexed over that one link:

- **debug frames** — binary protocol v0 (ADR-0006/DEBUG-PROTOCOL.md Layer 1),
  the same bytes the PC bridge speaks today, just over this link instead of
  the FTDI UART;
- **disk-block frames** — the block-source seam: the FDC/track layer already
  speaks to a block source behind a seam (today `m1_sd_fs`'s sector port; the
  ESP32 becomes an alternative provider of the same sectors, sourced from a
  server);
- **sound-event frames** — the step/select/motor/gate events, emitted at the
  module edge where they are already observable;
- **telemetry frames** — counters/state the ESP32 forwards to MQTT.

No service reaches across the link on its own; they publish/subscribe on the
ESP32's **internal event bus**, and the link-owner is the only thing that
touches the wire. This is what keeps five services from fighting over one
link.

### 3. Sound is a subscriber, not a special path

Drive-sound hangs off the same event stream as telemetry — the sound engine
is just another subscriber that turns step/select/motor/gate events into I²S
samples. No mixing with `cass_out` (that stays in the FPGA), and separate
speakers for drives and music are deliberate — that is how a real TRS-80
sounded.

### 4. The SD bus is the one shared resource that will bite — decide it first

The micro-SD lines (`sd_clk`/`sd_cmd`/`sd_miso`/`sd_csn`) are physically
shared between the FPGA and the ESP32's WiFi GPIOs. Today the FPGA owns them
outright by holding the ESP32 in reset (`wifi_en = 0`). Once the ESP32 runs,
that ownership must be resolved. The options, with a leaning:

- **(a) FPGA stays sole SD master; the ESP32 never touches the card.**
  Disk images the ESP32 sources from a server are streamed *to the FPGA over
  the link* as block frames (decision 2), and the FPGA serves them to the FDC
  exactly like local sectors. The ESP32 gets no SD access at all. **Leaning
  toward this** — it keeps the one hard-to-arbitrate resource single-mastered,
  and the block-source seam already exists to make it clean.
- **(b) Arbitrated hand-off** — a protocol on the link where the FPGA grants
  the SD bus to the ESP32 and back. Powerful (the ESP32 could manage the card
  directly) but it introduces exactly the shared-resource contention this ADR
  exists to avoid; deferred unless (a) proves insufficient.
- **(c) Separate storage for the ESP32** (its own flash/second card). Simple,
  but duplicates the image library and splits the source of truth.

Decision: **pursue (a)** — the block-source seam makes the ESP32 a *provider*
that hands sectors to the FPGA over the link, never a second SD master. The
FPGA remains the sole owner of the card. Revisit only if a concrete need
forces the ESP32 to touch the SD directly.

### 5. Service map

Each service is an event-bus participant behind the single link-owner:

| Service | Sources / sinks | Notes |
|---|---|---|
| Debug server | link (debug frames) ↔ TCP/WiFi (JSON-RPC) | ports `tools/trszog_bridge.py`, the reference impl |
| Disk provider | server (LAN/S3/MinIO) → link (block frames) | web tool maps images → `:0`–`:3`; FDC unchanged |
| Sound mixer | link (sound events) → I²S | drives speaker; separate from music |
| Telemetry | event bus → MQTT | dashboard/monitoring |
| Printer | Centronics register → network | post-M3 |
| Web UI / settings | HTTP ↔ all services' config | the one place a human configures the companion |
| Ecosystem (TRS-IO/FreHD/RetroStore) | as their own subscribers | compatibility, not a rewrite |

## Open questions

- The physical link (SPI vs. UART vs. a dedicated protocol) and its framing —
  a firmware-stage decision, constrained only by "one owner, typed frames".
- WiFi provisioning and credential handling (kept out of the checked-in
  debugger config per ADR-0007; the web UI owns it).
- Whether the debug server on the ESP32 caches poll-heavy debugger traffic
  locally (a latency optimization above protocol v0, not a protocol change).

## Consequences

- The ESP32 becomes a real subproject with a defined shape: an event bus, a
  single link-owner, typed frames, and services as participants — not a
  feature pile.
- The SD bus, the one resource that would have caused intermittent chaos, is
  single-mastered by decision, using a seam that already exists.
- Publishing this as a *proposed direction* makes the public roadmap concrete
  — readers see the companion is designed, not hand-waved — without a line of
  firmware existing yet. The firmware is the chapter after publication.
