// Testbench: m1_io — port 0xFF (cassette latch + video mode select).
//
// Self-contained unit check of the port register the way the schematic
// specifies it (the schematic is authoritative here — there is exactly one
// port and its behavior is a handful of gates and a latch):
//   - FF* / INSIG* / OUTSIG* decode: only port 0xFF, IN* vs OUT* exclusive,
//     everything floats high off 0xFF;
//   - OUT 0xFF latches D0..D3 on the OUTSIG* rising edge -> cassette level,
//     motor, and MODESEL = ~D3 (write D3=1 => 32-char, D3=0 => 64-char);
//   - a write to any other port changes nothing;
//   - IN 0xFF returns {cassette_ff, MODESEL, 6'b111111} and drives the bus
//     only while INSIG* is low; IN elsewhere leaves the bus alone;
//   - the Z24 cassette flip-flop sets on a cassette-input edge and is reset
//     by OUTSIG* (which is what the ROM's bit-read loop relies on).

`timescale 1ns / 1ps

module tb_m1_io;

    logic       clk, rst_n;
    logic [7:0] a, din;
    logic       in_n, out_n, cass_in;
    logic [7:0] dout;
    logic       dout_en, modesel;
    logic [1:0] cass_out;
    logic       cass_motor, ff_n, insig_n, outsig_n;

    m1_io dut (
        .clk(clk), .rst_n(rst_n), .a(a),
        .in_n(in_n), .out_n(out_n), .din(din), .cass_in(cass_in),
        .dout(dout), .dout_en(dout_en),
        .modesel(modesel), .cass_out(cass_out), .cass_motor(cass_motor),
        .ff_n(ff_n), .insig_n(insig_n), .outsig_n(outsig_n)
    );

    initial begin clk = 0; rst_n = 0;
        a = '0; din = '0; in_n = 1; out_n = 1; cass_in = 0; end
    always #46.97 clk = ~clk;

    int errors = 0;

    task automatic chk(input bit cond, input string msg);
        if (!cond) begin $display("FAIL  %s", msg); errors++; end
    endtask

    // one OUT cycle to a given port with given data
    task automatic port_out(input [7:0] port, input [7:0] data);
        @(negedge clk); a = port; din = data;
        repeat (3) @(negedge clk); out_n = 0;
        repeat (5) @(negedge clk); out_n = 1;   // rising edge latches
        repeat (3) @(negedge clk);
    endtask

    // one IN cycle; returns the bus value seen mid-strobe and dout_en
    task automatic port_in(input [7:0] port, output [7:0] val, output bit en);
        @(negedge clk); a = port;
        repeat (3) @(negedge clk); in_n = 0;
        repeat (3) @(negedge clk);
        val = dout; en = dout_en;
        repeat (2) @(negedge clk); in_n = 1;
        repeat (3) @(negedge clk);
    endtask

    logic [7:0] rv; bit ren;

    initial begin
        $dumpfile("build/tb_m1_io.vcd");
        $dumpvars(0, tb_m1_io);

        repeat (4) @(negedge clk); rst_n = 1;
        repeat (4) @(negedge clk);

        // --- power-on defaults: 64-char, motor off, level 0 (bar the ~Q1 tap) ---
        chk(modesel === 1'b1,    "power-on MODESEL should be 64-char (high)");
        chk(cass_motor === 1'b0, "power-on motor should be off");

        // --- decode: OUTSIG*/INSIG* only for port 0xFF ---
        @(negedge clk); a = 8'hFE; out_n = 0; @(negedge clk);
        chk(ff_n === 1'b1 && outsig_n === 1'b1, "port 0xFE must not decode");
        out_n = 1; a = 8'hFF; @(negedge clk); out_n = 0; @(negedge clk);
        chk(ff_n === 1'b0 && outsig_n === 1'b0, "port 0xFF OUT must assert OUTSIG*");
        chk(insig_n === 1'b1, "INSIG* must stay high during an OUT");
        out_n = 1; @(negedge clk);

        // --- OUT 0xFF latches D0..D3; a non-FF write does not ---
        port_out(8'hFF, 8'h00);
        chk(modesel === 1'b1 && cass_motor === 1'b0, "OUT FF,00: 64-char, motor off");
        port_out(8'hFF, 8'h08);                       // D3=1 -> 32-char
        chk(modesel === 1'b0, "OUT FF,08: MODESEL -> 32-char (low)");
        port_out(8'hFF, 8'h04);                       // D2=1 -> motor on, D3=0
        chk(cass_motor === 1'b1, "OUT FF,04: motor on");
        chk(modesel === 1'b1, "OUT FF,04: back to 64-char");
        port_out(8'hFF, 8'h03);                       // D0=1,D1=1
        chk(cass_out === 2'b01, "OUT FF,03: cass_out {~Q1,Q0} = {0,1}");
        // a write to another port must not disturb the latch
        port_out(8'hAB, 8'hFF);
        chk(cass_out === 2'b01 && modesel === 1'b1 && cass_motor === 1'b0,
            "write to port 0xAB must not change the 0xFF latch");

        // --- IN 0xFF read: {cass_ff, MODESEL, 0x3F}; motor still off here ---
        port_out(8'hFF, 8'h00);                       // 64-char, reset state
        port_in(8'hFF, rv, ren);
        chk(ren === 1'b1, "IN FF must drive the bus");
        chk(rv === 8'h7F, "IN FF (64-char, no cassette) = 0x7F");
        port_out(8'hFF, 8'h08);                       // 32-char
        port_in(8'hFF, rv, ren);
        chk(rv === 8'h3F, "IN FF (32-char) = 0x3F");
        // IN on another port: bus not driven
        port_in(8'hA0, rv, ren);
        chk(ren === 1'b0, "IN on port 0xA0 must not drive the bus");

        // --- cassette flip-flop: set by an input edge, reset by OUTSIG* ---
        // keep motor-latch writes away so OUTSIG* isn't pulsing; use a
        // no-cassette baseline then a single edge.
        @(negedge clk); cass_in = 0; repeat (2) @(negedge clk);
        @(negedge clk); cass_in = 1; repeat (2) @(negedge clk);   // rising edge sets
        port_in(8'hFF, rv, ren);
        chk(rv[7] === 1'b1, "cassette FF should be set after an input edge");
        port_out(8'hFF, 8'h00);                       // OUTSIG* resets the FF
        port_in(8'hFF, rv, ren);
        chk(rv[7] === 1'b0, "cassette FF should be reset by OUTSIG*");
        cass_in = 0;

        if (errors == 0) $display("\nALL CHECKS PASSED");
        else             $display("\n%0d CHECKS FAILED", errors);
        if (errors != 0) $fatal(1);
        $finish;
    end

    initial begin #5_000_000; $display("FAIL  watchdog"); $fatal(1); end

endmodule
