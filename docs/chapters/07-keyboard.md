# Chapter 7 — The Keyboard That Thinks It's Memory

*Sources: TRS-80 Technical Manual (Theory/Parts/Schematics, 1978), "Keyboard
Decoding" and "Keyboard" (pp. 244-246, 507-511) and Schematic Sheet 2; the
RetroStack Rev G recreation (`Keyboard.kicad_sch`) models only the 20-pin
connector — the matrix lives on the keyboard PCB — so the layout is taken from
the manual and pinned down against trs80gp's `-ik` injection. RTL:
[`rtl/m1_keyboard.v`](../../rtl/m1_keyboard.v); testbenches:
[`sim/tb_m1_keyboard.sv`](../../sim/tb_m1_keyboard.sv) and the system bench
[`sim/tb_m1_cpu.sv`](../../sim/tb_m1_cpu.sv).*

The Model 1 keyboard sends no ASCII, has no scan controller, no interrupt — it
is 53 switches in a grid that the CPU reads *as if it were memory*. Chapter 4
already carved out its address window (0x3800–0x3BFF, `KYBD*`); this chapter
builds what answers there.

## 1. A matrix you read like RAM

The keys sit at the crossings of an 8×8 grid. The eight low address lines
A0–A7 are the grid's drive ("horizontal") lines; the eight data lines D0–D7 are
the sense ("vertical") lines, held high by pull-ups R1–R8. `KYBD*` from the
decoder enables the tri-state sense buffers Z3/Z4 onto the data bus. Press a key
and it shorts its row's address line to its column's data line — so **a read of
`0x3800 + (1<<row)` returns, on the data bus, the eight keys of that row**, one
per bit, a set bit meaning "pressed."

Because the row is selected by an *address bit*, not a binary row number, the
ROM has a fast trick: read `0x38FF` (all eight address bits high) and every row
is driven at once, so a non-zero result means *some* key is down without
scanning. Then it walks the individual rows to find which. The hardware does
this for free — reading several rows just **ORs** them, which is exactly what
the matrix logic must reproduce.

## 2. The whole module is one equation

`m1_keyboard` is pure combinational logic — the matrix has no state:

```
dout[col] = OR over row of ( a[row] AND keys[8*row + col] )
```

`keys` is a 64-bit pressed-state (bit `8*row+col`), `a[7:0]` the row selects,
`dout_en` follows `KYBD*`. That's the entire chip: for each of the eight sense
lines, OR together the pressed keys of every currently-driven row. The
tri-state buffers become the usual `dout` + `dout_en` pair (chapters 3/5/6); the
bus is active-high, matching the pull-up-and-short sense.

What this module deliberately does **not** encode is *which physical key* is at
each (row, col). That mapping is a property of the keyboard PCB, and on hardware
it will come from the USB-HID front end (M1) writing the `keys` bits. The RTL is
the matrix; whoever drives `keys` owns the layout. The layout the manual
documents — and that trs80gp implements — is the one the tests pin down.

## 3. The signal contract

| Signal | Meaning | Hardware origin |
|---|---|---|
| `a[7:0]` | row-select (drive) lines | A0–A7 |
| `kybd_n` | keyboard window selected | decoder (chapter 4) |
| `keys[63:0]` | pressed-key state, `keys[8*row+col]` | keyboard PCB / USB-HID (M1) |
| `dout[7:0]`, `dout_en` | sensed columns + Z3/Z4 enable | Z3/Z4 |

## 4. What the testbenches prove (and how to watch it)

**`sim/tb_m1_keyboard.sv`** checks the matrix exhaustively — small enough to be
total: every one of the 64 keys, when its row is selected, reads on exactly the
right data bit and on no bit when a different row (or no row) is driven; two
keys in two rows read together OR correctly (the ROM's fast scan); a fully
pressed row reads 0xFF while an empty one reads 0x00; `dout_en` tracks `KYBD*`.
It closes with a spot-check of the documented layout trs80gp uses — SPACE at row
6/D7, RIGHT at row 6/D6.

**`sim/tb_m1_cpu.sv`** proves it through the CPU against the golden model. The
test program polls keyboard row 6 for SPACE and samples row 0 for `'A'`, writing
the tag characters `'S'` and `'A'` to the screen. The simulation injects those
two keys via the bench's `keys` input; trs80gp presses the very same keys with
`-ik 6 80 -ik 0 02`. Row 1 of the screen ends up reading `>?630SA` — chapter 5's
checksum digits, chapter 6's port tags, and now the two keyboard tags — and
`make golden` stays **byte-exact, 1024/1024**. So the matrix's row-select *and*
column-sense are verified end-to-end against trs80gp, which independently agrees
that SPACE lives at row 6 bit 7 and `'A'` at row 0 bit 1.

`make` runs both benches; `make golden` prints the match; `make wave-kbd` shows
the combinational truth table stepping through all 64 keys.

## 5. Open items

- [ ] **The physical key map (all 53 keys).** Only the two probed keys are
      pinned to trs80gp here; the full row/column assignment (and the two shift
      keys on row 7) comes with the USB-HID front end (M1), where each HID
      keycode sets its `keys` bit. The matrix logic is layout-agnostic and done.
- [ ] **Ghosting / rollover.** A real passive matrix without per-key diodes
      shows phantom keys when three corners of a rectangle are pressed; the
      Model 1 keyboard's behavior here is a hardware detail to reproduce (or
      deliberately not) once the HID mapping exists. Not modeled yet.
- [ ] **Debounce.** A hardware/HID concern, not a matrix-logic one; noted for
      the input front end.
