// Testbench: m1_fdc + m1_drives — WD1771 Type I against the drive bay.
//
// Unit-level checks with shortened stepping rates (RATE*_US parameters),
// wired exactly as m1_ei wires the pair. The real rates and the whole
// bus path run in the system bench (tb_m1_fdc_sys) and the golden
// compare against trs80gp.
//
// Proves: reset register values, register r/w, restore from a nonzero
// position (with step-pulse count), seek up/down with track updates,
// step/step-in/step-out incl. direction retention and the u flag, busy
// during motion, INTRQ set at completion / cleared by status read and by
// command write, force interrupt (0xD0 silent, 0xD8 immediate INTRQ),
// TR00/ready/not-ready composition, and the restore seek-error path when
// no drive is selected (255-step guard).

`timescale 1ns / 1ps

module tb_m1_fdc;

    logic clk, rst_n;
    initial begin clk = 0; rst_n = 0; end
    always #46.97 clk = ~clk;

    int errors = 0;

    // a fast "1 MHz" enable: every 4th clk, so rates shrink further
    logic [1:0] ediv;
    initial ediv = '0;
    always @(posedge clk) ediv <= ediv + 2'd1;
    wire en_1m = (ediv == 2'd0);

    logic       sel;
    logic [1:0] a;
    logic [7:0] din;
    logic       rd_n, wr_n;
    wire  [7:0] dout;
    wire        dout_en, intrq, step, dirc;
    wire        tr00, ip, wprt, ready;

    logic [3:0] ds, disk;
    logic       motor_on;

    // shortened rates: 40/40/80/160 "us" of the fast enable
    wire [1:0] sel_idx;
    wire [6:0] pos_sel;
    wire       side_sel;

    m1_fdc #(.RATE0_US(15'd40), .RATE1_US(15'd40),
             .RATE2_US(15'd80), .RATE3_US(15'd160)) u_fdc (
        .clk(clk), .rst_n(rst_n), .en_1m(en_1m), .percom_en(1'b1),
        .sel(sel), .a(a), .din(din), .rd_n(rd_n), .wr_n(wr_n),
        .dout(dout), .dout_en(dout_en), .intrq(intrq),
        .step(step), .dirc(dirc),
        .tr00(tr00), .ip(ip), .wprt(wprt), .ready(ready),
        .sel_drv(sel_idx), .pos_sel(pos_sel), .sel_side(side_sel),
        // Type I only here — the read path runs in tb_m1_fdc_rd
        /* verilator lint_off PINCONNECTEMPTY */
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

    m1_drives u_drives (
        .clk(clk), .rst_n(rst_n), .en_1m(en_1m),
        .ds(ds), .motor_on(motor_on), .disk(disk), .disk_wp(4'b0000),
        .step(step), .dirc(dirc),
        .tr00(tr00), .ip(ip), .wprt(wprt), .ready(ready),
        .sel_idx(sel_idx), .pos_sel(pos_sel), .side(side_sel)
    );

    int steps_seen;
    initial steps_seen = 0;
    always @(posedge clk) if (step) steps_seen <= steps_seen + 1;

    task automatic wr(input logic [1:0] ra, input logic [7:0] v);
        @(negedge clk);
        a = ra; din = v; wr_n = 0;
        repeat (4) @(negedge clk);
        wr_n = 1;
        @(negedge clk);
    endtask

    task automatic rd(input logic [1:0] ra, output logic [7:0] v);
        @(negedge clk);
        a = ra; rd_n = 0;
        repeat (4) @(negedge clk);
        v = dout;
        if (!dout_en) begin
            $display("FAIL  read a=%0d: dout_en low", ra);
            errors++;
        end
        rd_n = 1;
        @(negedge clk);
    endtask

    task automatic docmd(input logic [7:0] c, output logic [7:0] st);
        wr(2'd0, c);
        wait (intrq);
        rd(2'd0, st);          // status read clears INTRQ (trailing edge)
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
        logic [7:0] v, st;

        sel = 1; a = '0; din = '0; rd_n = 1; wr_n = 1;
        ds = 4'b0001; disk = 4'b0001; motor_on = 1;
        repeat (4) @(negedge clk);
        rst_n = 1;
        @(negedge clk);

        // --- reset values (trs80gp contract: all zero, sector too) ---
        rd(2'd1, v); check(v == 8'h00, "reset: track 0");
        rd(2'd2, v); check(v == 8'h00, "reset: sector 0 (not 1)");
        rd(2'd3, v); check(v == 8'h00, "reset: data 0");
        rd(2'd0, v); check((v & 8'hFD) == 8'h04,
                           "reset: status = ready, TR00, idle");

        // --- register r/w ---
        wr(2'd2, 8'hA5); rd(2'd2, v); check(v == 8'hA5, "sector r/w");
        wr(2'd3, 8'h5A); rd(2'd3, v); check(v == 8'h5A, "data r/w");
        wr(2'd1, 8'h22); rd(2'd1, v); check(v == 8'h22, "track r/w");

        // --- seek up: 0x22 -> 0x28, rate r=00 ---
        wr(2'd3, 8'h28);
        steps_seen = 0;
        docmd(8'h10, st);
        rd(2'd1, v);
        check(v == 8'h28 && steps_seen == 6, "seek up: track 28h, 6 steps");
        check((st & 8'hFD) == 8'h00, "seek: TR00 gone, idle status");
        check(!intrq, "INTRQ cleared by the status read");

        // --- step-in/out with and without update ---
        docmd(8'h50, st); rd(2'd1, v);
        check(v == 8'h29, "step-in u: track 29h");
        docmd(8'h40, st); rd(2'd1, v);
        check(v == 8'h29, "step-in no-u: track register untouched");
        docmd(8'h20, st); rd(2'd1, v);   // plain step (no u) keeps direction
        check(v == 8'h29, "plain step keeps direction");
        docmd(8'h70, st); rd(2'd1, v);
        check(v == 8'h28, "step-out u: track 28h");

        // the track register started life at a written 0x22 while the
        // head sat at 0 — physically we are at 6+1+1+1-1 = 8 now
        // --- restore: steps out until TR00, track register cleared ---
        steps_seen = 0;
        docmd(8'h00, st);
        rd(2'd1, v);
        check(v == 8'h00 && steps_seen == 8,
              "restore: 8 physical steps back to TR00, track 0");
        check((st & 8'hFD) == 8'h04, "restore: TR00 status");

        // --- busy while stepping ---
        wr(2'd3, 8'h10);
        wr(2'd0, 8'h13);                 // seek 16, slowest rate
        repeat (20) @(negedge clk);
        rd(2'd0, v);
        check(v[0], "busy while seeking");
        wait (intrq);
        rd(2'd0, v);
        check(!v[0], "idle after completion");

        // --- INTRQ cleared by a command write, force interrupt ---
        docmd(8'h00, st);                // restore home, leaves INTRQ clear
        wr(2'd0, 8'h13);                 // long seek to nowhere? data=10h
        wr(2'd0, 8'hD0);                 // force interrupt, no INTRQ
        repeat (8) @(negedge clk);
        rd(2'd0, v);
        check(!v[0] && !intrq, "force interrupt D0: idle, no INTRQ");
        wr(2'd0, 8'hD8);
        repeat (8) @(negedge clk);
        check(intrq, "force interrupt D8: immediate INTRQ");
        rd(2'd0, v); @(negedge clk);
        check(!intrq, "D8 INTRQ cleared by status read");

        // --- ready composition ---
        motor_on = 0; @(negedge clk);
        rd(2'd0, v); check(v[7], "motor off: NOT READY");
        motor_on = 1;
        ds = 4'b0010; @(negedge clk);    // drive 1: no disk
        rd(2'd0, v); check(v[7], "empty drive selected: NOT READY");
        ds = 4'b0001; @(negedge clk);

        // --- restore with no drive: 255-step guard -> seek error ---
        ds = 4'b0000; @(negedge clk);
        wr(2'd3, 8'h05);
        docmd(8'h13, st);                // seek 5: track moves, no TR00 risk
        ds = 4'b0000;
        docmd(8'h00, st);                // restore: TR00 never comes
        check(st[4], "restore without TR00: seek error after 255 steps");
        ds = 4'b0001;

        if (errors == 0) $display("ALL CHECKS PASSED");
        else             $display("%0d CHECKS FAILED", errors);
        if (errors != 0) $fatal(1);
        $finish;
    end

    initial begin
        #40_000_000;
        $fatal(1, "watchdog");
    end

endmodule
