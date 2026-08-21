// Testbench: the 48K machine WRITES a sector and it survives the full
// media round trip (EI stage 5b).
//
// Runs the write test image (tools/build_fdc_wr_test.py): write t2/s3
// with a known pattern through the DRQ pull, read it back from the
// (dirty) track buffer, then force an eviction (t5 read) so the
// write-back travels through the media model, return and read t2/s3
// again from the re-fetched track. Tags checked here and dumped for the
// byte-exact golden compare (make golden-fdc-wr, trs80gp with a THROWAWAY
// COPY of the same DMK in -d0 — trs80gp mutates its disk too).
//
// The bench also dumps the media model's post-run image
// (build/written_dmk.hex); tools/check_dmk_write.py then verifies the
// written artifact mathematically: pattern data in place AND a correct
// CCITT CRC over DAM+data — the proof that stage-6 trs80gp (or a real
// 1771) reading our written track would see a clean sector.
//
// +wp (with the write-protected +dmk image): the write must refuse with
// status 0x40 and both readbacks must show the ORIGINAL generator
// pattern (t2/s3 checksum 97).

`timescale 1ns / 1ps

module tb_m1_fdc_wr;

    logic clk, rst_n;
    initial begin clk = 0; rst_n = 0; end
    always #46.97 clk = ~clk;

    int errors = 0;

    bit wp;
    initial wp = $test$plusargs("wp");

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
        .pixel(), .col(), .line(), .row(), .snd()
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
    initial $readmemh("build/fdcwrtest.hex", image);

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

        expect_row(10'd0, "WS", "banner");
        if (wp) begin
            expect_row(10'd4,   "4000",   "row 0 (write refused)");
            expect_row(10'd68,  "000097", "row 1 (original pattern)");
            expect_row(10'd132, "000097", "row 2 (original pattern)");
        end else begin
            expect_row(10'd4,   "0000",   "row 0 (write ok, 256 fed)");
            expect_row(10'd68,  "000080", "row 1 (buffer readback)");
            expect_row(10'd132, "000080", "row 2 (after flush+refetch)");
        end

        if (errors == 0)
            $display("  ok  all write tags in place (%s)",
                     wp ? "write-protect" : "write+flush");

        fd = $fopen(wp ? "build/vram_fdc_wp.bin" : "build/vram_fdc_wr.bin",
                    "wb");
        for (i = 0; i < 1024; i++)
            $fwrite(fd, "%c", vram_byte(10'(i)));
        $fclose(fd);

        if (!wp) begin
            // post-run media for the artifact CRC check
            $writememh("build/written_dmk.hex", u_media.mem);
            $display("  ok  written media dumped: build/written_dmk.hex");
        end

        if (errors == 0) $display("ALL CHECKS PASSED (%s)",
                                  wp ? "wp refusal" : "write round trip");
        else             $display("%0d CHECKS FAILED", errors);
        if (errors != 0) $fatal(1);
        $finish;
    end

    initial begin
        #4_000_000_000;
        $fatal(1, "watchdog: FDC write test did not reach the marker");
    end

endmodule
