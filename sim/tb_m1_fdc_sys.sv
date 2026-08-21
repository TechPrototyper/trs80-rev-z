// Testbench: the 48K machine drives the WD1771 Type I end to end (EI stage 2).
//
// Boots the FDC test image (tools/build_fdc_test.py) on m1_core with the
// EI present and a disk in drive 0 (fdc_disk mirrors trs80gp's "-d dmk"),
// runs Restore / Seek 17 / 3x Step-In / Step-Out / Seek 0 with INTRQ
// polled through 0x37E0 bit 6, and checks the VRAM tags (status bytes
// with the rotation-dependent INDEX bit masked, track-register values,
// register r/w). Then the VRAM is dumped for the byte-exact golden
// compare (make golden-fdc, trs80gp without -dx, with -d dmk).
//
// A second run with +noei proves the bench can fail: no EI means every
// FDC address floats 0xFF and the INTRQ poll trips immediately on the
// floating 0x40 bit — the deterministic float pattern is checked.
//
// Prerequisite: build/fdctest.hex (the sim Makefile builds it).

`timescale 1ns / 1ps

module tb_m1_fdc_sys;

    logic clk, rst_n;
    initial begin clk = 0; rst_n = 0; end
    always #46.97 clk = ~clk;

    int errors = 0;

    bit noei;
    initial noei = $test$plusargs("noei");

    logic        ld_en;
    logic [13:0] ld_addr;
    logic [7:0]  ld_data;

    m1_core u_core (
        .clk(clk), .por_rst_n(rst_n), .dbg_rst_n(rst_n), .reset_btn_n(1'b1),
        .test_n(1'b1), .int_n(1'b1), .wait_n(1'b1),
        .ld_en(ld_en), .ld_addr(ld_addr), .ld_data(ld_data),
        .ei_ram_cfg(noei ? 2'b00 : 2'b10),
        .fdc_disk(4'b0001),   // mirror the golden setup (-d dmk: drive 0)
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
        .keys('0),
        .cass_in(1'b0),
        /* verilator lint_off PINCONNECTEMPTY */
        .cass_out(), .cass_motor(), .hdrv(), .vdrv(), .dot_en(),
        .cpu_cen(), .modesel(), .addr(), .m1_n(), .halt_n(),
        .pixel(), .col(), .line(), .row()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    logic [7:0] image [0:4095];
    initial $readmemh("build/fdctest.hex", image);

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

        expect_row(10'd0, "FD", "banner");
        if (noei) begin
            // every FDC/EI address floats 0xFF; statuses masked to FD,
            // the ready poll burns its full 65536-round budget first
            expect_row(10'd4,   "FDFFFFFF",           "row 0 (float)");
            expect_row(10'd68,  "FDFF40FDFFFDFFFDFF", "row 1 (float)");
            expect_row(10'd132, "FDFFFFFF",           "row 2 (float)");
        end else begin
            expect_row(10'd4,   "04000000",           "row 0 (ready+regs)");
            expect_row(10'd68,  "040000001100140013", "row 1 (seek/steps)");
            expect_row(10'd132, "040055AA",           "row 2 (seek0+regs)");
        end

        if (errors == 0)
            $display("  ok  all FDC tags in place (%s)",
                     noei ? "float pattern" : "Type I sequence");

        if (!noei) begin
            fd = $fopen("build/vram_fdc.bin", "wb");
            for (i = 0; i < 1024; i++)
                $fwrite(fd, "%c", vram_byte(10'(i)));
            $fclose(fd);
            $display("  ok  VRAM dumped: build/vram_fdc.bin");
        end

        if (errors == 0) $display("ALL CHECKS PASSED (%s)",
                                  noei ? "no-EI negative" : "Type I");
        else             $display("%0d CHECKS FAILED", errors);
        if (errors != 0) $fatal(1);
        $finish;
    end

    initial begin
        // ~0.42 s of stepping when the EI is there; the +noei run burns
        // its bounded spin-up budget (~2 s of machine time)
        #3_000_000_000;
        $fatal(1, "watchdog: FDC test did not reach the marker");
    end

endmodule
