// TRS-80 Rev Z — keyboard matrix (memory-mapped read at 0x3800-0x3BFF)
//
// Hardware modeled (RetroStack "Keyboard.kicad_sch" is just the 20-pin
// connector; the matrix itself is on the keyboard PCB — TRS-80 Technical
// Manual 1978, "Keyboard"/"Keyboard Decoding", pp. 244-246, 507-511):
//   The keyboard is not a scanned ASCII device — it is a passive switch
//   matrix the CPU reads as if it were memory. KYBD* (from the address
//   decoder, chapter 4) enables the tri-state sense buffers Z3/Z4 onto the
//   data bus. The eight low address lines A0..A7 are the matrix's "horizontal"
//   drive lines (one per row); the eight data lines D0..D7 are the "vertical"
//   sense lines (one per column), held high by pull-ups R1..R8 and pulled to
//   the driven row by a closed key. So a read of 0x3800 + (1<<r) returns, on
//   the data bus, the eight keys of row r (bit c high = key r,c pressed);
//   reading several rows at once (several address bits set) ORs them, which
//   is exactly how the ROM's "any key?" fast scan of 0x3801..0x38FF works.
//
// Deliberate deviations:
//   - The physical key-to-(row,col) assignment lives on the keyboard PCB and,
//     on hardware, will come from the USB-HID front end (M1). This module is
//     the matrix itself: it takes a 64-bit pressed-key state and does the
//     row-select / column-sense combinational logic. Which bit is which key is
//     a property of whoever drives `keys`, verified against trs80gp's matrix
//     in the testbench.
//   - Z3/Z4 tri-states -> dout + dout_en (chapters 3/5/6 idiom). The real
//     buffers are non-inverting and the bus is active-high (a pressed key
//     reads as 1), matching the pull-up/short sense above.
//   - Pure combinational: no clock. The matrix has no state of its own.

module m1_keyboard (
    input  wire [7:0]  a,       // A0..A7: the row-select (drive) lines
    input  wire        kybd_n,  // KYBD* from the decoder (active low)
    input  wire [63:0] keys,    // pressed-key state; keys[8*row + col]

    output wire [7:0]  dout,    // sensed columns (valid while dout_en)
    output wire        dout_en  // Z3/Z4 drive the bus (KYBD* low)
);

    // For each column c, OR the key at (row r, col c) across every driven row.
    // dout[c] = | over r of ( a[r] & keys[8*r + c] )
    genvar c, r;
    wire [7:0] col_bits;
    generate
        for (c = 0; c < 8; c = c + 1) begin : g_col
            wire [7:0] contrib;
            for (r = 0; r < 8; r = r + 1) begin : g_row
                assign contrib[r] = a[r] & keys[8*r + c];
            end
            assign col_bits[c] = |contrib;
        end
    endgenerate

    assign dout    = col_bits;
    assign dout_en = ~kybd_n;

endmodule
