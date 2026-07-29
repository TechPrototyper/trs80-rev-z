// Testbench: m1_hid_keys — HID reports to TRS-80 matrix chords.
//
// Feeds boot-protocol keyboard reports and checks the matrix bits that
// come out of the dot-domain side, including the glyph-faithful shift
// translations (@, *, :, ", +) and the control mappings (Esc -> BREAK,
// Backspace -> LEFT, Home -> CLEAR), plus rollover, release, and the
// no-device clear.

`timescale 1ns / 1ps

module tb_hid_keys;

    logic        usbclk, clk_dot, usbrst_n;
    logic [1:0]  typ;
    logic        report;
    logic [7:0]  mods, k1, k2, k3, k4;
    wire  [63:0] keys;

    initial begin usbclk = 0; clk_dot = 0; usbrst_n = 0; end
    always #41.67 usbclk  = ~usbclk;   // 12 MHz
    always #46.97 clk_dot = ~clk_dot;  // 10.64 MHz

    m1_hid_keys dut (
        .usbclk(usbclk), .usbrst_n(usbrst_n),
        .typ(typ), .report(report), .key_modifiers(mods),
        .key1(k1), .key2(k2), .key3(k3), .key4(k4),
        .clk_dot(clk_dot), .keys(keys)
    );

    int errors = 0;

    task automatic send(input [7:0] m, input [7:0] a, input [7:0] b = 8'h00,
                        input [7:0] c = 8'h00, input [7:0] d = 8'h00);
        @(negedge usbclk);
        mods = m; k1 = a; k2 = b; k3 = c; k4 = d;
        report = 1;
        @(negedge usbclk);
        report = 0;
        repeat (6) @(negedge clk_dot);   // CDC settle
    endtask

    function automatic bit pressed(input [2:0] row, input [2:0] col);
        pressed = keys[{row, col}];
    endfunction

    task automatic expect_only(input [63:0] want, input string what);
        if (keys !== want) begin
            $display("FAIL  %s: keys=%h want=%h", what, keys, want);
            errors++;
        end
    endtask

    function automatic [63:0] bit_at(input [2:0] row, input [2:0] col);
        bit_at = 64'd1 << {row, col};
    endfunction

    localparam [63:0] SHIFT_L = 64'd1 << (8*7 + 0);
    localparam [63:0] SHIFT_R = 64'd1 << (8*7 + 1);

    initial begin
        typ = 2'd1; report = 0; mods = '0;
        k1 = '0; k2 = '0; k3 = '0; k4 = '0;
        repeat (4) @(negedge usbclk);
        usbrst_n = 1;

        // --- plain letter: A -> row0 col1 ---
        send(8'h00, 8'h04);
        expect_only(bit_at(0,1), "A");

        // --- golden pair from chapter 7: SPACE row6 col7 ---
        send(8'h00, 8'h2C);
        expect_only(bit_at(6,7), "SPACE");

        // --- physical shift passthrough: LShift+A ---
        send(8'h02, 8'h04);
        expect_only(bit_at(0,1) | SHIFT_L, "LShift+A");

        // --- RShift lands on row7 col1 ---
        send(8'h20, 8'h04);
        expect_only(bit_at(0,1) | SHIFT_R, "RShift+A");

        // --- @ : modern shift+2 -> M1 @ key UNSHIFTED ---
        send(8'h02, 8'h1F);
        expect_only(bit_at(0,0), "@ drops shift");

        // --- * : modern shift+8 -> M1 shift+':' ---
        send(8'h02, 8'h25);
        expect_only(bit_at(5,2) | SHIFT_L, "* becomes shift+colon");

        // --- : modern shift+; -> M1 ':' UNSHIFTED ---
        send(8'h02, 8'h33);
        expect_only(bit_at(5,2), "colon drops shift");

        // --- " : modern shift+' -> M1 shift+2 ---
        send(8'h02, 8'h34);
        expect_only(bit_at(4,2) | SHIFT_L, "quote becomes shift+2");

        // --- = : modern plain '=' -> M1 shift+'-' (forced shift) ---
        send(8'h00, 8'h2E);
        expect_only(bit_at(5,5) | SHIFT_L, "= forces shift+minus");

        // --- controls: Esc->BREAK, Backspace->LEFT, Home->CLEAR, Enter ---
        send(8'h00, 8'h29);
        expect_only(bit_at(6,2), "Esc -> BREAK");
        send(8'h00, 8'h2A);
        expect_only(bit_at(6,5), "Backspace -> LEFT");
        send(8'h00, 8'h4A);
        expect_only(bit_at(6,1), "Home -> CLEAR");
        send(8'h00, 8'h28);
        expect_only(bit_at(6,0), "Enter");

        // --- unmappable glyph drops out: shift+6 (^) ---
        send(8'h02, 8'h23);
        expect_only(SHIFT_L, "^ has no key (shift alone remains)");

        // --- rollover: A + B + Enter + Space together ---
        send(8'h00, 8'h04, 8'h05, 8'h28, 8'h2C);
        expect_only(bit_at(0,1) | bit_at(0,2) | bit_at(6,0) | bit_at(6,7),
                    "4-key rollover");

        // --- release: empty report clears everything ---
        send(8'h00, 8'h00);
        expect_only(64'd0, "all released");

        // --- device unplugged: matrix clears even without a report ---
        send(8'h00, 8'h04);
        typ = 2'd0;
        repeat (4) @(negedge usbclk);
        repeat (6) @(negedge clk_dot);
        expect_only(64'd0, "device gone -> released");
        typ = 2'd1;

        if (errors == 0) $display("ALL CHECKS PASSED");
        else             $display("%0d CHECKS FAILED", errors);
        $finish;
    end

endmodule
