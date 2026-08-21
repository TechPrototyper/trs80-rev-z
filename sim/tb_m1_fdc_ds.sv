// Testbench: double-sided disks via the DS drive-select convention.
//
// Boots the DS probe image (tools/build_fdc_ds_test.py) on m1_core with
// a double-sided disk in drive 0 (+dmk=build/fdc_ds_disk.hex from
// build_dmk.py --sides 2 — two track blocks per cylinder, distinct data
// per side). Latch bit 3 together with a drive bit selects head 1
// (0x09 = drive 0, side 1 — the NEWDOS/80 PDRIVE convention probed from
// the nd80206 boot sector). The probe reads t2/s3 on side 0, side 1,
// then side 0 again; the checksums must differ between sides and swing
// back — proving both the head switch and that the FDC track buffer is
// keyed by side. VRAM dumped for the golden compare (make
// golden-fdc-ds, the same DMK in trs80gp -d0).

`timescale 1ns / 1ps

module tb_m1_fdc_ds;

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
        .fdc_disk(4'b0001),   // a disk in drive 0, as trs80gp -d0
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
    initial $readmemh("build/fdcdstest.hex", image);

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

        expect_row(10'd0, "DS", "banner");
        expect_row(10'd4, "0000970000F997",
                   "row 0 (side 0 / side 1 / side 0 reads)");

        if (errors == 0)
            $display("  ok  both heads read distinct data, re-keyed buffer");

        fd = $fopen("build/vram_fdc_ds.bin", "wb");
        for (i = 0; i < 1024; i++)
            $fwrite(fd, "%c", vram_byte(10'(i)));
        $fclose(fd);
        $display("  ok  VRAM dumped: build/vram_fdc_ds.bin");

        if (errors == 0) $display("ALL CHECKS PASSED (double-sided reads)");
        else             $display("%0d CHECKS FAILED", errors);
        if (errors != 0) $fatal(1);
        $finish;
    end

    initial begin
        #6_000_000_000;
        $fatal(1, "watchdog: FDC DS test did not reach the marker");
    end

endmodule
