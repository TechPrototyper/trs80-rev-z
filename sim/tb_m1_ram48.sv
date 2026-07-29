// Testbench: the 48K machine, end to end (ADR-0005 stage 1).
//
// Boots the EI-RAM test image (tools/build_ram_test.py) on m1_core with
// both EI banks populated, runs it to the NMI completion marker and
// checks the five boundary tags read 'K' — then dumps the VRAM for the
// byte-exact golden compare against trs80gp -m1 -mem 48 (make golden-ram).
//
// A second run with +noei proves the test can fail: with no EI RAM the
// upper four cells float (reads return 0xFF) and the tags must read '-'.
// That run has no golden partner — it guards the bench against vacuity.
//
// Prerequisite: build/ramtest.hex (the sim Makefile builds it).

`timescale 1ns / 1ps

module tb_m1_ram48;

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
        .trk_req(), .trk_drv(), .trk_track(),
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
    initial $readmemh("build/ramtest.hex", image);

    // completion marker, as in the chapter-5 bench (checks_on instead of
    // rst_n in the clocked block — the tb_m1_cpu idiom, keeps lint clean)
    bit checks_on, done;
    initial begin checks_on = 0; done = 0; end
    always @(negedge clk)
        if (checks_on && !u_core.wr_n && !u_core.vid_n
            && u_core.addr[9:0] == 10'h3FF && u_core.bus == 8'hBF)
            done <= 1;

    // reconstruct a VRAM byte incl. the D6 = NOR(D5,D7) quirk (chapter 3)
    function automatic logic [7:0] vram_byte(input logic [9:0] i);
        vram_byte = {u_core.u_vr.ram[i][6],
                     ~(u_core.u_vr.ram[i][5] | u_core.u_vr.ram[i][6]),
                     u_core.u_vr.ram[i][5:0]};
    endfunction

    initial begin
        int i, fd;
        logic [7:0] want;

        // play the loader (the seam the chapter benches use)
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

        // the five boundary tags
        want = noei ? 8'h2D : 8'h4B;             // '-' or 'K'
        if (vram_byte(10'd0) !== 8'h4B) begin        // 0x7FFF: base RAM, always
            $display("FAIL  tag 0 (base RAM 0x7FFF) = %02h", vram_byte(10'd0));
            errors++;
        end
        for (i = 1; i < 5; i++)
            if (vram_byte(10'(i)) !== want) begin
                $display("FAIL  tag %0d = %02h, expected %02h",
                         i, vram_byte(10'(i)), want);
                errors++;
            end
        if (errors == 0)
            $display("  ok  boundary tags: %s", noei ? "K----" : "KKKKK");

        // dump for the golden compare (48K run only)
        if (!noei) begin
            fd = $fopen("build/vram_ram48.bin", "wb");
            for (i = 0; i < 1024; i++)
                $fwrite(fd, "%c", vram_byte(10'(i)));
            $fclose(fd);
            $display("  ok  VRAM dumped: build/vram_ram48.bin");
        end

        if (errors == 0) $display("ALL CHECKS PASSED (%s)",
                                  noei ? "16K negative" : "48K");
        else             $display("%0d CHECKS FAILED", errors);
        if (errors != 0) $fatal(1);
        $finish;
    end

    initial begin
        #100_000_000;
        $fatal(1, "watchdog: ram test did not reach the marker");
    end

endmodule
