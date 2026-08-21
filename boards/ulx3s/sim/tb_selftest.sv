// Testbench: m1_selftest_loader — the power-on self-test, end to end.
//
// Instantiates loader + machine exactly as ulx3s_top wires them (loader
// holds the core in reset, streams the image, releases) and proves:
//   1. after `done`, the ROM array equals the image byte-for-byte
//      (catches any off-by-one between ld_addr and ld_data),
//   2. the machine then runs the image to its final marker write —
//      the same completion the golden test uses — i.e. the first flash
//      will really draw the banner, not just load bytes.
//
// Prerequisite: `make` in sim/ (builds testimg.hex).

`timescale 1ns / 1ps

module tb_selftest;

    logic clk, rst_n;
    initial begin clk = 0; rst_n = 0; end
    always #46.97 clk = ~clk;

    int errors = 0;

    logic [63:0] kb_keys;
    initial begin
        kb_keys = '0;
        kb_keys[8*6 + 7] = 1'b1;   // SPACE
        kb_keys[8*0 + 1] = 1'b1;   // 'A'
    end

    // --- loader + core, wired as in ulx3s_top ---
    wire        ld_en, ld_done;
    wire [13:0] ld_addr;
    wire [7:0]  ld_data;

    m1_selftest_loader #(.IMG_HEX("../../../sim/build/testimg.hex"))
    u_loader (
        .clk(clk), .rst_n(rst_n),
        .ld_en(ld_en), .ld_addr(ld_addr), .ld_data(ld_data),
        .done(ld_done)
    );

    wire core_rst_n = rst_n & ld_done;

    m1_core #(.FONT_HEX("../../../rtl/mcm6670_cg1.hex")) u_core (
        .clk(clk), .por_rst_n(core_rst_n), .dbg_rst_n(core_rst_n), .reset_btn_n(1'b1),
        .test_n(1'b1), .int_n(1'b1), .wait_n(1'b1),
        .ld_en(ld_en), .ld_addr(ld_addr), .ld_data(ld_data),
        // press the golden keys (SPACE row6/D7, 'A' row0/D1): the image polls
        // row 6 with a 65536-count timeout (~1.5 s) — with the keys down it
        // exits immediately, same stimulus as the golden run
        .ei_ram_cfg(2'b00),   // no EI RAM: 16K system, goldens unchanged
        .fdc_disk(4'b0000),
        /* verilator lint_off PINCONNECTEMPTY */
        .trk_req(), .trk_drv(), .trk_track(), .trk_side(),
        /* verilator lint_on PINCONNECTEMPTY */
        .trk_vld(1'b0), .trk_data(8'd0), .trk_idx(13'd0),
        .trk_done(1'b0), .trk_err(1'b1), .trk_len(13'd0), .trk_dbl(1'b0),
        .fdc_wp(4'b0000),
        .percom_en(1'b1),
        /* verilator lint_off PINCONNECTEMPTY */
        .trk_wb_req(), .trk_wb_data(),
        /* verilator lint_on PINCONNECTEMPTY */
        .trk_wb_fetch(1'b0), .trk_wb_idx(13'd0),
        .trk_wb_done(1'b0), .trk_wb_err(1'b1),
        .dbg_in_valid(1'b0), .dbg_in_data(8'h00), .dbg_out_ready(1'b1),
        /* verilator lint_off PINCONNECTEMPTY */
        .dbg_in_ready(), .dbg_out_valid(), .dbg_out_data(),
        /* verilator lint_on PINCONNECTEMPTY */
        .keys(kb_keys),
        .cass_in(1'b0),
        /* verilator lint_off PINCONNECTEMPTY */
        .cass_out(), .cass_motor(), .hdrv(), .vdrv(), .dot_en(),
        .cpu_cen(), .modesel(), .addr(), .m1_n(), .halt_n(),
        .pixel(), .col(), .line(), .row()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    // reference copy of the image
    logic [7:0] image [0:4095];
    initial $readmemh("../../../sim/build/testimg.hex", image);

    // completion marker, as in the golden bench
    bit done;
    initial done = 0;
    always @(negedge clk)
        if (core_rst_n && !u_core.wr_n && !u_core.vid_n
            && u_core.addr[9:0] == 10'h3FF && u_core.bus == 8'hBF)
            done <= 1;

    initial begin
        #100_000_000;
        $fatal(1, "watchdog: self-test did not reach the marker in 100 ms");
    end

    initial begin
        int i, mism;

        repeat (4) @(negedge clk);
        rst_n = 1;

        wait (ld_done);
        repeat (2) @(negedge clk);

        // --- 1. ROM content == image ---
        mism = 0;
        for (i = 0; i < 4096; i++)
            if (u_core.u_rom.mem[i] !== image[i]) begin
                if (mism < 5)
                    $display("FAIL  rom[%0d] = %02h, image %02h",
                             i, u_core.u_rom.mem[i], image[i]);
                mism++;
            end
        if (mism != 0) begin
            $display("FAIL  %0d ROM bytes differ from the image", mism);
            errors++;
        end else
            $display("  ok  ROM == image, 4096/4096 bytes");

        // --- 2. the machine runs it to the marker ---
        wait (done);
        $display("  ok  self-test ran to the completion marker");

        if (errors == 0) $display("ALL CHECKS PASSED");
        else             $display("%0d CHECKS FAILED", errors);
        $finish;
    end

endmodule
