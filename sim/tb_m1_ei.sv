// Testbench: m1_ei — the Expansion Interface container (EI stage 1).
//
// Unit-level checks with shortened timing parameters (HB_DIV, MOTOR_US);
// the real 40 Hz / 3 s values are exercised by the system bench
// (tb_m1_ei_hb) and the golden compare against trs80gp.
//
// Proves: the 1 MHz enable rate, the power-on-pending latch, the exact
// 0x37E0 read decode with pre-clear value + clear-on-read, the heartbeat
// setting the latch again, INT* level behavior, the 37E0-37E3 write
// window into the drive-select latch, the motor one-shot with retrigger,
// and that en=0 (bare keyboard unit) disables everything.

`timescale 1ns / 1ps

module tb_m1_ei;

    logic clk, rst_n;
    initial begin clk = 0; rst_n = 0; end
    always #46.97 clk = ~clk;

    int errors = 0;

    logic        en;
    logic [15:0] a;
    logic [7:0]  din;
    logic        rd_n, wr_n;
    wire  [7:0]  dout;
    wire         dout_en, int_n, motor_on, en_1m;
    wire  [3:0]  drive_sel;

    // shortened: tick every 50 us, motor one-shot 200 us
    m1_ei #(.HB_DIV(15'd50), .MOTOR_US(22'd200)) u_ei (
        .clk(clk), .rst_n(rst_n), .en(en),
        .a(a), .din(din), .rd_n(rd_n), .wr_n(wr_n),
        .dout(dout), .dout_en(dout_en),
        .int_n(int_n), .disk(4'b0000), .disk_wp(4'b0000),
        .percom_en(1'b1),
        .drive_sel(drive_sel), .motor_on(motor_on), .en_1m(en_1m),
        /* verilator lint_off PINCONNECTEMPTY */
        .fdc_step(), .fdc_dirc(),
        .trk_req(), .trk_drv(), .trk_track(), .trk_side(),
        /* verilator lint_on PINCONNECTEMPTY */
        .trk_vld(1'b0), .trk_data(8'd0), .trk_idx(13'd0),
        .trk_done(1'b0), .trk_err(1'b1), .trk_len(13'd0), .trk_dbl(1'b0),
        /* verilator lint_off PINCONNECTEMPTY */
        .trk_wb_req(), .trk_wb_data(),
        /* verilator lint_on PINCONNECTEMPTY */
        .trk_wb_fetch(1'b0), .trk_wb_idx(13'd0),
        .trk_wb_done(1'b0), .trk_wb_err(1'b1)
    );

    task automatic bus_read(input logic [15:0] addr,
                            output logic [7:0] val, output logic drove);
        @(negedge clk);
        a = addr; rd_n = 0;
        repeat (4) @(negedge clk);
        val   = dout;
        drove = dout_en;
        rd_n = 1;
        @(negedge clk);
    endtask

    task automatic bus_write(input logic [15:0] addr, input logic [7:0] val);
        @(negedge clk);
        a = addr; din = val; wr_n = 0;
        repeat (4) @(negedge clk);
        wr_n = 1;
        @(negedge clk);
    endtask

    task automatic check(input bit cond, input string what);
        if (!cond) begin
            $display("FAIL  %s", what);
            errors++;
        end else
            $display("  ok  %s", what);
    endtask

    initial begin
        logic [7:0] v;
        logic       d;
        int i, pulses;

        en = 1; a = '0; din = '0; rd_n = 1; wr_n = 1;
        repeat (4) @(negedge clk);
        rst_n = 1;
        @(negedge clk);

        // --- power-on: RTC latch set, INT* asserted ---
        check(!int_n, "power-on: RTC pending, INT* low");
        bus_read(16'h37E0, v, d);
        check(d && v == 8'hBF, "37E0 read: pre-clear value BF");
        @(negedge clk);
        check(int_n, "read cleared the latch: INT* high");
        bus_read(16'h37E0, v, d);
        check(d && v == 8'h3F, "second read: idle value 3F");

        // --- decode edges: only 37E0 answers reads ---
        bus_read(16'h37E1, v, d);
        check(!d, "37E1 read: not decoded");
        bus_read(16'h37DF, v, d);
        check(!d, "37DF read: not decoded");
        bus_read(16'h37EC, v, d);
        check(d && v == 8'h80,
              "37EC read: FDC status (not ready, nothing selected)");

        // --- heartbeat: the shortened tick re-arms the latch ---
        wait (!int_n);
        bus_read(16'h37E0, v, d);
        check(v == 8'hBF, "tick: pending again, read shows BF");
        @(negedge clk);
        check(int_n, "tick cleared by read");

        // --- 1 MHz enable rate: ~200 pulses in 200 us ---
        pulses = 0;
        for (i = 0; i < 2129; i++) begin   // 2129 dot clocks ~= 200.0 us
            @(negedge clk);
            if (en_1m) pulses++;
        end
        check(pulses >= 199 && pulses <= 201,
              $sformatf("1 MHz enable: %0d pulses in 200 us", pulses));

        // --- drive select + motor one-shot ---
        check(!motor_on, "motor off before any select");
        bus_write(16'h37E0, 8'h01);
        check(drive_sel == 4'b0001 && motor_on,
              "write 37E0: DS0 latched, motor on");
        bus_write(16'h37E3, 8'h04);
        check(drive_sel == 4'b0100, "write 37E3 (window mirror): DS2");
        bus_write(16'h37E4, 8'h0F);
        check(drive_sel == 4'b0100, "write 37E4: outside the window");

        // one-shot: 200 us nominal; retrigger at 100 us stretches it
        #100_000 check(motor_on, "motor still on at 100 us");
        bus_write(16'h37E0, 8'h01);        // retrigger
        #150_000 check(motor_on, "retriggered: on at 100+150 us");
        #100_000 check(!motor_on, "one-shot expired after the retrigger");

        // --- bare keyboard unit: en = 0 kills everything ---
        en = 0;
        @(negedge clk);
        check(int_n, "en=0: INT* never asserts");
        bus_read(16'h37E0, v, d);
        check(!d, "en=0: 37E0 not decoded");
        bus_write(16'h37E0, 8'h02);
        check(drive_sel == 4'b0001, "en=0: drive latch untouched");

        if (errors == 0) $display("ALL CHECKS PASSED");
        else             $display("%0d CHECKS FAILED", errors);
        if (errors != 0) $fatal(1);
        $finish;
    end

    initial begin
        #5_000_000;
        $fatal(1, "watchdog");
    end

endmodule
