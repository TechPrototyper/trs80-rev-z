// Testbench: m1_keyboard — the passive switch matrix read as memory.
//
// The matrix logic is small enough to check exhaustively:
//   - every single key (row r, col c) is sensed on exactly the right data bit
//     when its row is selected, and on no data bit when a different row is;
//   - the row-select is the address bit: reading 0x38xx with A[r]=1 returns
//     row r; multiple address bits OR the rows (the ROM's fast "any key" scan);
//   - dout_en follows KYBD* and nothing drives the bus with KYBD* high;
//   - a fully-pressed row and an all-keys-down board behave (all-ones sense).
// Then a spot-check against the documented TRS-80 layout used by trs80gp so the
// system-level golden test (tb_m1_cpu + `-ik`) has a known mapping to lean on.

`timescale 1ns / 1ps

module tb_m1_keyboard;

    logic [7:0]  a;
    logic        kybd_n;
    logic [63:0] keys;
    logic [7:0]  dout;
    logic        dout_en;

    m1_keyboard dut (.a(a), .kybd_n(kybd_n), .keys(keys),
                     .dout(dout), .dout_en(dout_en));

    int errors = 0;
    task automatic chk(input bit c, input string m);
        if (!c) begin $display("FAIL  %s", m); errors++; end
    endtask

    // helper: set exactly one key
    function automatic [63:0] one_key(input int r, input int c);
        one_key = 64'd0; one_key[8*r + c] = 1'b1;
    endfunction

    int r, c;

    initial begin
        $dumpfile("build/tb_m1_keyboard.vcd");
        $dumpvars(0, tb_m1_keyboard);
        kybd_n = 1; a = '0; keys = '0;
        #1;

        // --- KYBD* gates the bus ---
        keys = '1; a = 8'hFF; kybd_n = 1; #1;
        chk(dout_en === 1'b0, "dout_en must be low while KYBD* is high");
        kybd_n = 0; #1;
        chk(dout_en === 1'b1, "dout_en must be high while KYBD* is low");
        chk(dout === 8'hFF, "all keys down, all rows selected -> 0xFF");

        // --- every single key: sensed on the right bit for its row only ---
        kybd_n = 0;
        for (r = 0; r < 8; r++) begin
            for (c = 0; c < 8; c++) begin
                keys = one_key(r, c);
                // select the key's own row: only bit c set
                a = 8'(1 << r); #1;
                chk(dout === 8'(1 << c),
                    $sformatf("key(%0d,%0d) on row %0d should read bit %0d", r, c, r, c));
                // select a different row: nothing
                a = 8'(1 << ((r + 1) % 8)); #1;
                chk(dout === 8'h00,
                    $sformatf("key(%0d,%0d) must not show on row %0d", r, c, (r+1)%8));
                // select no row: nothing
                a = 8'h00; #1;
                chk(dout === 8'h00,
                    $sformatf("key(%0d,%0d) must not show with no row selected", r, c));
            end
        end

        // --- multi-row OR: two keys in different rows, both rows selected ---
        keys = one_key(1, 2) | one_key(4, 5);
        a = 8'(1 << 1) | 8'(1 << 4); #1;
        chk(dout === (8'(1 << 2) | 8'(1 << 5)),
            "reading rows 1+4 together ORs their pressed keys");
        a = 8'(1 << 1); #1;
        chk(dout === 8'(1 << 2), "row 1 alone shows only its key");

        // --- a fully pressed row reads all ones on that row only ---
        keys = 64'd0;
        for (c = 0; c < 8; c++) keys[8*3 + c] = 1'b1;   // row 3 all down
        a = 8'(1 << 3); #1; chk(dout === 8'hFF, "row 3 fully pressed -> 0xFF");
        a = 8'(1 << 2); #1; chk(dout === 8'h00, "row 2 empty even so -> 0x00");

        // --- spot-check the documented layout trs80gp's -ik uses:
        //     row 6 (addr 0x3840) bit 7 = SPACE, bit 6 = RIGHT, bit 5 = LEFT ---
        keys = 64'd0;
        keys[8*6 + 7] = 1'b1;                 // SPACE
        a = 8'h40; #1;                        // A6 -> row 6
        chk(dout === 8'h80, "layout: SPACE = row 6, D7 (0x80)");
        keys = 64'd0; keys[8*6 + 6] = 1'b1;   // RIGHT
        a = 8'h40; #1;
        chk(dout === 8'h40, "layout: RIGHT = row 6, D6 (0x40)");

        if (errors == 0) $display("\nALL CHECKS PASSED (%0d keys, all rows)", 64);
        else             $display("\n%0d CHECKS FAILED", errors);
        if (errors != 0) $fatal(1);
        $finish;
    end

endmodule
