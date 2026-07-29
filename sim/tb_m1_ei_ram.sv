// Testbench: m1_ei_ram — the Expansion Interface RAM banks (ADR-0005).
//
// Drives bus-shaped cycles (RAS*/RD*/WR* strobes spanning several dot
// clocks, like the real machine) against every population option and
// proves:
//   1. cfg=1x (48K system): both banks store and return data at all four
//      boundary cells, values stay distinct (no aliasing between banks),
//   2. cfg=01 (32K system): bank 1 works, bank 2 floats the bus on reads
//      and swallows writes (the earlier contents survive untouched),
//   3. cfg=00 (16K system): no cell answers at all,
//   4. region discipline: A15=0 memory cycles and I/O-style cycles
//      (RAS* high) never select the EI RAM — a lower-32K write to the
//      same A14..A0 pattern must not corrupt the EI cell it aliases.

`timescale 1ns / 1ps

module tb_m1_ei_ram;

    logic clk;
    initial clk = 0;
    always #46.97 clk = ~clk;

    int errors = 0;

    logic [14:0] a;
    logic        a15, ras_n, rd_n, wr_n;
    logic [1:0]  cfg;
    logic [7:0]  din;
    wire  [7:0]  dout;
    wire         dout_en;

    m1_ei_ram dut (
        .clk(clk), .a(a), .a15(a15),
        .ras_n(ras_n), .rd_n(rd_n), .wr_n(wr_n),
        .cfg(cfg), .din(din), .dout(dout), .dout_en(dout_en)
    );

    task automatic idle_bus();
        ras_n = 1; rd_n = 1; wr_n = 1; a = '0; a15 = 0; din = 8'hFF;
    endtask

    // a write cycle: address settles, RAS* falls, WR* strobes low for a
    // few dot clocks (the real strobes span several), everything releases
    task automatic bus_write(input logic [15:0] addr, input logic [7:0] d);
        @(negedge clk);
        a = addr[14:0]; a15 = addr[15]; din = d;
        ras_n = 0;
        @(negedge clk);
        wr_n = 0;
        repeat (3) @(negedge clk);
        wr_n = 1;
        @(negedge clk);
        idle_bus();
    endtask

    // a read cycle: returns data and the buffer-enable state
    task automatic bus_read(input logic [15:0] addr,
                            output logic [7:0] d, output logic en);
        @(negedge clk);
        a = addr[14:0]; a15 = addr[15];
        ras_n = 0; rd_n = 0;
        repeat (3) @(negedge clk);   // registered read: settle
        d  = dout;
        en = dout_en;
        rd_n = 1;
        @(negedge clk);
        idle_bus();
    endtask

    task automatic expect_read(input logic [15:0] addr,
                               input logic [7:0] want, input string what);
        logic [7:0] d;
        logic       en;
        bus_read(addr, d, en);
        if (!en || d !== want) begin
            $display("FAIL  %s: [%04h] = %02h (en=%0d), expected %02h",
                     what, addr, d, en, want);
            errors++;
        end
    endtask

    task automatic expect_float(input logic [15:0] addr, input string what);
        logic [7:0] d;
        logic       en;
        bus_read(addr, d, en);
        if (en) begin
            $display("FAIL  %s: [%04h] drove the bus (%02h), expected float",
                     what, addr, d);
            errors++;
        end
    endtask

    initial begin
        idle_bus();
        cfg = 2'b10;                       // 48K system
        repeat (4) @(negedge clk);

        // --- 1. both banks, boundary cells, distinct values -----------
        bus_write(16'h8000, 8'h11);
        bus_write(16'hBFFF, 8'h22);
        bus_write(16'hC000, 8'h33);
        bus_write(16'hFFFF, 8'h44);
        expect_read(16'h8000, 8'h11, "48K bank1 first");
        expect_read(16'hBFFF, 8'h22, "48K bank1 last");
        expect_read(16'hC000, 8'h33, "48K bank2 first");
        expect_read(16'hFFFF, 8'h44, "48K bank2 last");
        $display("  ok  48K: both banks store, boundaries distinct");

        // --- 4a. lower-32K cycles must not alias into the EI ----------
        bus_write(16'h4000, 8'hEE);        // aliases A14..A0 of 0xC000
        bus_write(16'h0000, 8'hEE);        // aliases A14..A0 of 0x8000
        expect_float(16'h4000, "A15=0 read");
        expect_read(16'hC000, 8'h33, "bank2 after A15=0 alias write");
        expect_read(16'h8000, 8'h11, "bank1 after A15=0 alias write");
        $display("  ok  A15=0 cycles never touch the EI RAM");

        // --- 4b. non-memory cycles (RAS* high) select nothing ---------
        @(negedge clk);
        a = 15'h0000; a15 = 1; rd_n = 0; ras_n = 1;
        repeat (3) @(negedge clk);
        if (dout_en) begin
            $display("FAIL  dout_en with RAS* high"); errors++;
        end
        rd_n = 1; idle_bus();
        $display("  ok  RAS* high: EI RAM stays off the bus");

        // --- 2. 32K system: bank 2 unpopulated -------------------------
        cfg = 2'b01;
        repeat (2) @(negedge clk);
        expect_read(16'h8000, 8'h11, "32K bank1 still there");
        expect_float(16'hC000, "32K bank2 read");
        bus_write(16'hC000, 8'hAB);        // must vanish
        cfg = 2'b10;
        repeat (2) @(negedge clk);
        expect_read(16'hC000, 8'h33, "bank2 after unpopulated write");
        $display("  ok  32K: bank 2 floats reads, swallows writes");

        // --- 3. 16K system: nothing answers ----------------------------
        cfg = 2'b00;
        repeat (2) @(negedge clk);
        expect_float(16'h8000, "16K bank1 read");
        expect_float(16'hFFFF, "16K bank2 read");
        bus_write(16'h8000, 8'hCD);
        cfg = 2'b10;
        repeat (2) @(negedge clk);
        expect_read(16'h8000, 8'h11, "bank1 after 16K-config write");
        $display("  ok  16K: EI RAM fully absent");

        if (errors == 0) $display("ALL CHECKS PASSED");
        else             $display("%0d CHECKS FAILED", errors);
        if (errors != 0) $fatal(1);
        $finish;
    end

    initial begin
        #10_000_000;
        $fatal(1, "watchdog");
    end

endmodule
