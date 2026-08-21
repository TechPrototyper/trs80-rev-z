// Testbench: double density through the Percom Doubler (EI stage 6).
//
// Runs the DD test image (tools/build_fdc_dd_test.py) on the
// mixed-density disk (build_dmk.py --dd): the Percom latch (0xFE/0xFF)
// switches between the SD boot track and the MFM tracks; DD transfers
// run the doubler-era unrolled driver loops (32 us/byte); a DD write
// overwrites s7 with 0x5A fill; and the density filter proves an
// all-MFM track is invisible to the SD personality (RNF). Golden:
// make golden-fdc-dd against trs80gp -ddp on a throwaway disk copy.

`timescale 1ns / 1ps

module tb_m1_fdc_dd;

    logic clk, rst_n;
    initial begin clk = 0; rst_n = 0; end
    always #46.97 clk = ~clk;

    int errors = 0;


    logic        ld_en;
    logic [13:0] ld_addr;
    logic [7:0]  ld_data;

    wire        trk_req;
    wire [1:0]  trk_drv;
    wire [6:0]  trk_track;
    wire        trk_side;
    wire        trk_vld, trk_done, trk_err, trk_dbl, trk_wp;
    wire [7:0]  trk_data;
    wire [12:0] trk_idx, trk_len;
    wire        trk_wb_req, trk_wb_fetch, trk_wb_done, trk_wb_err;
    wire [12:0] trk_wb_idx;
    wire [7:0]  trk_wb_data;

    m1_core u_core (
        .clk(clk), .por_rst_n(rst_n), .dbg_rst_n(rst_n), .reset_btn_n(1'b1),
        .test_n(1'b1), .int_n(1'b1), .wait_n(1'b1),
        .ld_en(ld_en), .ld_addr(ld_addr), .ld_data(ld_data),
        .ei_ram_cfg(2'b10),
        .fdc_disk(4'b0001),
        .trk_req(trk_req), .trk_drv(trk_drv), .trk_track(trk_track),
        .trk_side(trk_side),
        .trk_vld(trk_vld), .trk_data(trk_data), .trk_idx(trk_idx),
        .trk_done(trk_done), .trk_err(trk_err),
        .trk_len(trk_len), .trk_dbl(trk_dbl),
        .fdc_wp({3'b000, trk_wp}),
        .percom_en(1'b1),
        .trk_wb_req(trk_wb_req), .trk_wb_fetch(trk_wb_fetch),
        .trk_wb_idx(trk_wb_idx), .trk_wb_data(trk_wb_data),
        .trk_wb_done(trk_wb_done), .trk_wb_err(trk_wb_err),
        .dbg_in_valid(1'b0), .dbg_in_data(8'h00), .dbg_out_ready(1'b1),
        /* verilator lint_off PINCONNECTEMPTY */
        .dbg_in_ready(), .dbg_out_valid(), .dbg_out_data(),
        /* verilator lint_on PINCONNECTEMPTY */
        .keys('0),
        .cass_in(1'b0),
        /* verilator lint_off PINCONNECTEMPTY */
        .cass_out(), .cass_motor(), .hdrv(), .vdrv(), .dot_en(),
        .cpu_cen(), .modesel(), .addr(), .m1_n(), .halt_n(),
        .pixel(), .col(), .line(), .row()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    dmk_media_model u_media (
        .clk(clk),
        .trk_req(trk_req), .trk_drv(trk_drv), .trk_track(trk_track),
        .trk_side(trk_side),
        .trk_vld(trk_vld), .trk_data(trk_data), .trk_idx(trk_idx),
        .trk_done(trk_done), .trk_err(trk_err),
        .trk_len(trk_len), .trk_dbl(trk_dbl), .trk_wp(trk_wp),
        .trk_wb_req(trk_wb_req), .trk_wb_fetch(trk_wb_fetch),
        .trk_wb_idx(trk_wb_idx), .trk_wb_data(trk_wb_data),
        .trk_wb_done(trk_wb_done), .trk_wb_err(trk_wb_err)
    );

    logic [7:0] image [0:4095];
    initial $readmemh("build/fdcddtest.hex", image);

    bit checks_on, done;
    initial begin checks_on = 0; done = 0; end
    always @(negedge clk)
        if (checks_on && !u_core.wr_n && !u_core.vid_n
            && u_core.addr[9:0] == 10'h3FF && u_core.bus == 8'hBF)
            done <= 1;

    function automatic logic [7:0] vram_byte(input logic [9:0] i);
        vram_byte = {u_core.u_vr.ram[i][6],
                     ~(u_core.u_vr.ram[i][5] | u_core.u_vr.ram[i][6]),
                     u_core.u_vr.ram[i][5:0]};
    endfunction

    task automatic expect_row(input logic [9:0] base, input string tags,
                              input string what);
        for (int i = 0; i < tags.len(); i++)
            if (vram_byte(base + 10'(i)) !== 8'(tags[i])) begin
                $display("FAIL  %s: cell %0d = %02h, expected '%s'",
                         what, base + 10'(i), vram_byte(base + 10'(i)),
                         tags.substr(i, i));
                errors++;
            end
    endtask

    initial begin
        int i, fd;

        ld_en = 0; ld_addr = 0; ld_data = 0;
        repeat (4) @(negedge clk);
        for (i = 0; i < 4096; i++) begin
            @(negedge clk);
            ld_en   = 1;
            ld_addr = 14'(i);
            ld_data = image[i];
        end
        @(negedge clk);
        ld_en = 0;
        rst_n = 1;
        checks_on = 1;

        wait (done);
        repeat (8) @(negedge clk);

        expect_row(10'd0,   "DD",       "banner");
        expect_row(10'd4,   "00000E",   "row 0 (SD side of the disk)");
        expect_row(10'd68,  "0097",     "row 1 (MFM read, fast loop)");
        expect_row(10'd132, "00000010", "row 2 (DD write/readback + RNF)");

        if (errors == 0)
            $display("  ok  all DD tags in place (mixed-density disk)");

        fd = $fopen("build/vram_fdc_dd.bin", "wb");
        for (i = 0; i < 1024; i++)
            $fwrite(fd, "%c", vram_byte(10'(i)));
        $fclose(fd);

        if (errors == 0) $display("ALL CHECKS PASSED (double density)");
        else             $display("%0d CHECKS FAILED", errors);
        if (errors != 0) $fatal(1);
        $finish;
    end

`ifdef DDDBG5
    always @(posedge clk) begin
        if (u_core.u_ei.u_fdc.wr_d && !u_core.u_ei.u_fdc.wr_here
            && u_core.u_ei.u_fdc.wa_d == 2'd0)
            $display("%t CMD %02h (rstate=%0d busy=%b)", $time,
                     u_core.u_ei.u_fdc.wd_d, u_core.u_ei.u_fdc.rstate,
                     u_core.u_ei.u_fdc.busy);
    end
    always @(u_core.u_ei.u_fdc.t2ctx)
        $display("%t t2ctx -> %b", $time, u_core.u_ei.u_fdc.t2ctx);
    int nsr = 0;
    reg rs_d = 0;
    always @(posedge clk) begin
        rs_d <= u_core.u_ei.u_fdc.rd_stat;
        if (!rs_d && u_core.u_ei.u_fdc.rd_stat && $realtime > 76400000.0
            && (u_core.u_ei.u_fdc.rstate == 5'd7
                || u_core.u_ei.u_fdc.rstate == 5'd8)
            && nsr < 10) begin
            nsr <= nsr + 1;
            $display("%t STAT=%02h drq=%b t2=%b rst8=%0d", $realtime,
                     u_core.u_ei.u_fdc.dout, u_core.u_ei.u_fdc.drq,
                     u_core.u_ei.u_fdc.t2ctx, u_core.u_ei.u_fdc.rstate);
        end
    end
`endif

`ifdef DDDBG6
    int nrd = 0;
    reg rdn_d6 = 1;
    always @(posedge clk) if (u_core.cpu_cen) begin
        rdn_d6 <= u_core.rd_n;
        if (rdn_d6 && !u_core.rd_n && u_core.m1_n
            && $realtime > 76450000.0 && nrd < 10) begin
            nrd <= nrd + 1;
            $display("RD @%04h -> %02h", u_core.addr, u_core.bus);
        end
    end
    int n_prod = 0, n_cons = 0;
    reg rdd_d6 = 0;
    always @(posedge clk) begin
        if (u_core.u_ei.u_fdc.rstate == 5'd8
            && !u_core.u_ei.u_fdc.rd_pend) ;
        rdd_d6 <= u_core.u_ei.u_fdc.rd_data;
        if (rdd_d6 && !u_core.u_ei.u_fdc.rd_data
            && $realtime > 76000000.0)
            n_cons <= n_cons + 1;
    end
    reg drq_d6 = 0;
    always @(posedge clk) begin
        drq_d6 <= u_core.u_ei.u_fdc.drq;
        if (!drq_d6 && u_core.u_ei.u_fdc.drq
            && $realtime > 76000000.0)
            n_prod <= n_prod + 1;
    end
    initial begin
        #200_000_000;
        $display("CNT@200ms produced=%0d consumed=%0d lost=%b rstate=%0d",
                 n_prod, n_cons, u_core.u_ei.u_fdc.lost,
                 u_core.u_ei.u_fdc.rstate);
    end
    // log every overlap (byte lost) instant
    always @(posedge clk)
        if (u_core.u_ei.u_fdc.rstate == 5'd8
            && !u_core.u_ei.u_fdc.rd_pend
            && u_core.u_ei.u_fdc.drq)
            $display("%t LOSTBYTE (cpu addr=%04h m1=%b)", $realtime,
                     u_core.addr, u_core.m1_n);
`endif

`ifdef DDDBG4
    bit m14_d; int t4, n4;
    initial begin m14_d = 1; t4 = 0; n4 = 0; end
    always @(posedge clk) if (u_core.cpu_cen) begin
        t4 <= t4 + 1;
        m14_d <= u_core.m1_n;
        if (m14_d && !u_core.m1_n
            && u_core.addr >= 16'h02C0 && u_core.addr < 16'h02E0
            && n4 < 40) begin
            n4 <= n4 + 1;
            $display("M1 @%04h  dT=%0d", u_core.addr, t4);
            t4 <= 1;
        end
    end
`endif

`ifdef DDDBG3
    reg drq_q;
    int nev = 0;
    always @(posedge clk) begin
        drq_q <= u_core.u_ei.u_fdc.drq;
        if (!drq_q && u_core.u_ei.u_fdc.drq && nev < 40) begin
            nev <= nev + 1;
            $display("%t DRQ set", $time);
        end
        if (drq_q && !u_core.u_ei.u_fdc.drq && nev < 40)
            $display("%t DRQ clr", $time);
    end
`endif

`ifdef DDDBG2
    reg drq_d;
    int ndc = 0;
    always @(posedge clk) begin
        drq_d <= u_core.u_ei.u_fdc.drq;
        if (drq_d && !u_core.u_ei.u_fdc.drq && ndc < 10) begin
            ndc <= ndc + 1;
            $display("%t drq cleared (#%0d)", $time, ndc);
        end
    end
`endif

`ifdef DDDBG7
    // write-path forensics: on every lost-data strike, show where the
    // byte died relative to the CPU's last data-register write strobe
    // and the FDC's last DRQ raise
    realtime t_drq_set, t_wstrb_beg, t_wstrb_end;
    reg wda_d7, drq_d7, lost_d7;
    initial begin
        t_drq_set = 0; t_wstrb_beg = 0; t_wstrb_end = 0;
        wda_d7 = 0; drq_d7 = 0; lost_d7 = 0;
    end
    always @(posedge clk) begin
        wda_d7  <= u_core.u_ei.u_fdc.wr_data_act;
        drq_d7  <= u_core.u_ei.u_fdc.drq;
        lost_d7 <= u_core.u_ei.u_fdc.lost;
        if (!wda_d7 && u_core.u_ei.u_fdc.wr_data_act)
            t_wstrb_beg <= $realtime;
        if (wda_d7 && !u_core.u_ei.u_fdc.wr_data_act)
            t_wstrb_end <= $realtime;
        if (!drq_d7 && u_core.u_ei.u_fdc.drq)
            t_drq_set <= $realtime;
        if (!lost_d7 && u_core.u_ei.u_fdc.lost)
            $display("%t LOST rstate=%0d wphase=%0d n_left=%0d us=%0d drq=%b | DRQset %t  wstrb %t..%t  (dT set->now %0.1f us, strb_end->now %0.1f us)",
                     $realtime, u_core.u_ei.u_fdc.rstate,
                     u_core.u_ei.u_fdc.wphase,
                     u_core.u_ei.u_fdc.rd_n_left,
                     u_core.u_ei.u_fdc.us_byte, u_core.u_ei.u_fdc.drq,
                     t_drq_set, t_wstrb_beg, t_wstrb_end,
                     ($realtime - t_drq_set) / 1000.0,
                     ($realtime - t_wstrb_end) / 1000.0);
    end
    // event trace around the strike: status reads (with the value the
    // CPU saw), data-register writes, DRQ edges — during write states
    reg rst7_d;
    initial rst7_d = 0;
    wire in_wr7 = (u_core.u_ei.u_fdc.rstate >= 5'd12
                   && u_core.u_ei.u_fdc.rstate <= 5'd14);
    always @(posedge clk) if (in_wr7 && !u_core.u_ei.u_fdc.lost) begin
        rst7_d <= u_core.u_ei.u_fdc.rd_stat;
        if (rst7_d && !u_core.u_ei.u_fdc.rd_stat)
            $display("%t   STAT read -> %02h (drq=%b)", $realtime,
                     u_core.u_ei.u_fdc.dout, u_core.u_ei.u_fdc.drq);
        if (wda_d7 && !u_core.u_ei.u_fdc.wr_data_act)
            $display("%t   DATA write %02h", $realtime,
                     u_core.u_ei.u_fdc.din);
        if (!drq_d7 && u_core.u_ei.u_fdc.drq)
            $display("%t   DRQ set (n_left=%0d)", $realtime,
                     u_core.u_ei.u_fdc.rd_n_left);
        if (drq_d7 && !u_core.u_ei.u_fdc.drq)
            $display("%t   DRQ clr", $realtime);
    end
`endif

`ifdef DDDBG
    always @(u_core.u_ei.u_fdc.rstate)
        $display("%t rstate -> %0d (dden=%b e_dd=%b)", $time,
                 u_core.u_ei.u_fdc.rstate, u_core.u_ei.u_fdc.dden,
                 u_core.u_ei.u_fdc.e_dd);
`endif

    initial begin
        // the density-filter RNF waits out ~1 s of index pulses
        #4_000_000_000;
        $display("WDG fdc: lost=%b drq=%b intrq=%b  cpu addr=%04h",
                 u_core.u_ei.u_fdc.lost, u_core.u_ei.u_fdc.drq,
                 u_core.u_ei.u_fdc.intrq, u_core.addr);
        for (int r = 0; r < 3; r++)
            $display("WDG row%0d: %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h %02h",
                     r, vram_byte(10'(r*64+0)), vram_byte(10'(r*64+1)),
                     vram_byte(10'(r*64+4)), vram_byte(10'(r*64+5)),
                     vram_byte(10'(r*64+6)), vram_byte(10'(r*64+7)),
                     vram_byte(10'(r*64+8)), vram_byte(10'(r*64+9)),
                     vram_byte(10'(r*64+10)), vram_byte(10'(r*64+11)),
                     vram_byte(10'(r*64+12)), vram_byte(10'(r*64+13)));
        $fatal(1, "watchdog: DD test did not reach the marker");
    end

endmodule
