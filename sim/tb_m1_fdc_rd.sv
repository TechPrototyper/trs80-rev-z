// Testbench: the 48K machine reads sectors off a DMK (EI stage 3).
//
// Boots the FDC read test image (tools/build_fdc_rd_test.py) on m1_core
// with the EI present, a disk in drive 0, and the DMK media model behind
// the track-fetch port (+dmk=build/fdc_disk.hex from build_dmk.py). The
// image reads t0/s0 and t17/s5 (byte counts + checksums), runs the
// record-not-found path (~1 s of index pulses) and Read Address, and
// tags everything quirk-invariantly; the bench checks the tags and dumps
// the VRAM for the byte-exact golden compare (make golden-fdc-rd,
// trs80gp without -dx, the same DMK in -d0).
//
// A +tferr run makes every track fetch fail: both reads and the read
// address must come back record-not-found (status 10) with zero bytes
// transferred — the media-refusal path, and proof the bench can fail.
//
// Expected checksums come from the generator (build_dmk.py prints them):
// t0/s0 = 0E, t17/s5 = 55.

`timescale 1ns / 1ps

module tb_m1_fdc_rd;

    logic clk, rst_n;
    initial begin clk = 0; rst_n = 0; end
    always #46.97 clk = ~clk;

    int errors = 0;

    bit tferr;
    initial tferr = $test$plusargs("tferr");

    logic        ld_en;
    logic [13:0] ld_addr;
    logic [7:0]  ld_data;

    wire        trk_req;
    wire [1:0]  trk_drv;
    wire [6:0]  trk_track;
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
        .fdc_disk(4'b0001),   // a disk in drive 0, as trs80gp -d0
        .trk_req(trk_req), .trk_drv(trk_drv), .trk_track(trk_track),
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
        .trk_vld(trk_vld), .trk_data(trk_data), .trk_idx(trk_idx),
        .trk_done(trk_done), .trk_err(trk_err),
        .trk_len(trk_len), .trk_dbl(trk_dbl), .trk_wp(trk_wp),
        .trk_wb_req(trk_wb_req), .trk_wb_fetch(trk_wb_fetch),
        .trk_wb_idx(trk_wb_idx), .trk_wb_data(trk_wb_data),
        .trk_wb_done(trk_wb_done), .trk_wb_err(trk_wb_err)
    );

    logic [7:0] image [0:4095];
    initial $readmemh("build/fdcrdtest.hex", image);

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

        expect_row(10'd0, "RD", "banner");
        if (tferr) begin
            // every fetch refused: both reads and the RA end RNF with
            // nothing transferred; RAM at 4200 stays zero, the sector
            // register keeps the 0x0B the RNF attempt wrote
            expect_row(10'd4,   "100000",         "row 0 (fetch refused)");
            expect_row(10'd68,  "0011100000",     "row 1 (fetch refused)");
            expect_row(10'd132, "10100000000B",   "row 2 (fetch refused)");
        end else begin
            expect_row(10'd4,   "00000E",         "row 0 (t0/s0)");
            expect_row(10'd68,  "0011000055",     "row 1 (seek+t17/s5)");
            expect_row(10'd132, "100011000111",   "row 2 (RNF+RA)");
        end

        if (errors == 0)
            $display("  ok  all read tags in place (%s)",
                     tferr ? "fetch-refusal" : "sector reads");

        if (!tferr) begin
            fd = $fopen("build/vram_fdc_rd.bin", "wb");
            for (i = 0; i < 1024; i++)
                $fwrite(fd, "%c", vram_byte(10'(i)));
            $fclose(fd);
            $display("  ok  VRAM dumped: build/vram_fdc_rd.bin");
        end

        if (errors == 0) $display("ALL CHECKS PASSED (%s)",
                                  tferr ? "tferr negative" : "DMK reads");
        else             $display("%0d CHECKS FAILED", errors);
        if (errors != 0) $fatal(1);
        $finish;
    end

    initial begin
        // the RNF paths wait out real index pulses (~1 s each)
        #6_000_000_000;
        $fatal(1, "watchdog: FDC read test did not reach the marker");
    end

endmodule
