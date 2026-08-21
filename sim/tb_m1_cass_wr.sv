// Testbench: cassette WRITE path through port 0xFF (M2 stage 2).
//
// Boots the write probe (tools/build_cass_wr_test.py): it bit-bangs an
// 8-byte leader, the 0xA5 sync and the 16-byte payload at 500 baud
// through the output ladder (OUT 01/02/00 pulse swings, motor held).
// The deck model records every positive spike; +caswr dumps the
// timestamps and tools/check_cass_write.py decodes them back to bytes
// — the round-trip proof that what the RTL puts on tape is the stream
// the probe meant to write. VRAM golden vs trs80gp: make
// golden-cass-wr additionally diffs trs80gp''s auto-saved .cas against
// our decode from the A5 sync on.

`timescale 1ns / 1ps

module tb_m1_cass_wr;

    logic clk, rst_n;
    initial begin clk = 0; rst_n = 0; end
    always #46.97 clk = ~clk;

    int errors = 0;

    logic        ld_en;
    logic [13:0] ld_addr;
    logic [7:0]  ld_data;

    wire cass_in, cass_motor;
    wire [1:0] cass_out;

    m1_core u_core (
        .clk(clk), .por_rst_n(rst_n), .dbg_rst_n(rst_n), .reset_btn_n(1'b1),
        .test_n(1'b1), .int_n(1'b1), .wait_n(1'b1),
        .ld_en(ld_en), .ld_addr(ld_addr), .ld_data(ld_data),
        .ei_ram_cfg(2'b10),
        .fdc_disk(4'b0000),
        /* verilator lint_off PINCONNECTEMPTY */
        .trk_req(), .trk_drv(), .trk_track(), .trk_side(), .trk_wb_req(),
        .trk_wb_data(),
        /* verilator lint_on PINCONNECTEMPTY */
        .trk_vld(1'b0), .trk_data(8'h00), .trk_idx(13'd0),
        .trk_done(1'b0), .trk_err(1'b1), .trk_len(13'd0), .trk_dbl(1'b0),
        .trk_wb_fetch(1'b0), .trk_wb_idx(13'd0),
        .trk_wb_done(1'b0), .trk_wb_err(1'b1),
        .fdc_wp(4'b0000),
        .percom_en(1'b0),
        .dbg_in_valid(1'b0), .dbg_in_data(8'h00), .dbg_out_ready(1'b1),
        /* verilator lint_off PINCONNECTEMPTY */
        .dbg_in_ready(), .dbg_out_valid(), .dbg_out_data(),
        /* verilator lint_on PINCONNECTEMPTY */
        .keys('0),
        .cass_in(cass_in),
        .cass_out(cass_out), .cass_motor(cass_motor),
        /* verilator lint_off PINCONNECTEMPTY */
        .hdrv(), .vdrv(), .dot_en(),
        .cpu_cen(), .modesel(), .addr(), .m1_n(), .halt_n(),
        .pixel(), .col(), .line(), .row(), .snd()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    cass_media_model u_tape (
        .clk(clk), .motor(cass_motor), .cass_out(cass_out),
        .cass_in(cass_in)
    );

    logic [7:0] image [0:4095];
    initial $readmemh("build/casswtest.hex", image);

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

        expect_row(10'd0, "CW", "banner");
        expect_row(10'd4, "88", "row 0 (payload checksum)");

        if (errors == 0)
            $display("  ok  probe wrote the full stream (checksum 88)");

        fd = $fopen("build/vram_cass_wr.bin", "wb");
        for (i = 0; i < 1024; i++)
            $fwrite(fd, "%c", vram_byte(10'(i)));
        $fclose(fd);
        $display("  ok  VRAM dumped: build/vram_cass_wr.bin");

        if (errors == 0) $display("ALL CHECKS PASSED (cassette write)");
        else             $display("%0d CHECKS FAILED", errors);
        if (errors != 0) $fatal(1);
        $finish;
    end

    initial begin
        #8_000_000_000;
        $fatal(1, "watchdog: cassette write test did not reach the marker");
    end

endmodule
