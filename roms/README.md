# ROMs — none here, on purpose

Level II BASIC is a copyrighted work (Tandy/Microsoft).

**No ROM image will ever be committed to this repository, embedded in a bitstream, or accepted in a pull request.**

The design loads ROM images at runtime (SD card / ESP32), which is also why the RTL
implements real ROM/RAM separation instead of a preinitialized memory array.


## So what do you need?

One 12288-byte (12 K) Level II BASIC image, dumped from hardware you own or obtained
from a source you are comfortable with. Reference version is **1.3** (~July 1980).

## Identifying what you have

| You see at boot | Version |
|---|---|
| `MEM SIZE?` and banner `R/S L2 BASIC` | **1.3** — the reference |
| `MEMORY SIZE?` and `RADIO SHACK LEVEL II BASIC` | early (1.0–1.2) — works, but not the verification reference |

Other ** dumps** in circulation:

- **14336 bytes (14 K)** instead of 12288: contains 2 KB of third-party code at `$3000`
  where the real machine has no ROM at all. I haven't looked into that, but for sure it's
  nothing that came out of Fort Worth in the day! It might work, though, and perhaps someone 
  actually built some nice extensions (Keyboard Buffer, anyone?)
- Banner shows `READY` where the copyright banner should be: autoboot-patched image.
- Anything advertised as "Level II" that types differently than the table above.


Place your image as `roms/level2.rom` (gitignored) or point the loader at it — see the
board documentation once M1 lands.

