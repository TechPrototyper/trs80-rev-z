// Testbench: m1_scan_fb — the capture framebuffer against the golden frame.
//
// Runs the same machine + test image as sim/tb_m1_cpu (chapter 8), lets the
// final screen render into the capture framebuffer, then reads every one of
// the 384x192 cells back through the pixel-clock read port and compares it
// byte-for-byte against the reference frame the chapter-8 bench dumped
// (sim/build/frame_cpu.pgm — itself golden-verified against trs80gp).
//
// This pins the capture placement (col-2 lag, dot_in_cell, row*12+line) to
// the verified reference: if the DVI path shows anything, it shows exactly
// what the machine's authentic video chain produced.
//
// Prerequisite: run `make` in sim/ first (builds testimg.hex + frame_cpu.pgm).

`timescale 1ns / 1ps

module tb_scan_fb;

    logic clk;       // dot clock
    logic clk_pix;   // display pixel clock (40 MHz)
    logic rst_n;

    initial begin clk = 0; rst_n = 0; end
    always #46.97 clk = ~clk;
    initial clk_pix = 0;
    always #12.5 clk_pix = ~clk_pix;

    int errors = 0;

    // ------------------------------------------------------------------
    // The machine, exactly as in tb_m1_cpu (same keys, same image).
    // ------------------------------------------------------------------
    logic        ld_en;
    logic [13:0] ld_addr;
    logic [7:0]  ld_data;
    logic [63:0] kb_keys;
    logic [6:0]  col;
    logic [3:0]  line;
    logic [4:0]  row;
    logic        pixel;

    initial begin
        kb_keys = '0;
        kb_keys[8*6 + 7] = 1'b1;   // SPACE
        kb_keys[8*0 + 1] = 1'b1;   // 'A'
    end

    m1_core #(.FONT_HEX("../../../rtl/mcm6670_cg1.hex")) u_core (
        .clk(clk), .por_rst_n(rst_n), .dbg_rst_n(rst_n), .reset_btn_n(1'b1),
        .test_n(1'b1), .int_n(1'b1), .wait_n(1'b1),
        .ld_en(ld_en), .ld_addr(ld_addr), .ld_data(ld_data),
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
        /* verilator lint_on PINCONNECTEMPTY */
        .pixel(pixel), .col(col), .line(line), .row(row)
    );

    // ------------------------------------------------------------------
    // DUT: the capture framebuffer.
    // ------------------------------------------------------------------
    logic [16:0] rd_addr;
    logic        rd_bit;

    m1_scan_fb u_fb (
        .clk_dot(clk), .pixel(pixel), .col(col), .line(line), .row(row),
        .clk_pix(clk_pix), .rd_addr(rd_addr), .rd_bit(rd_bit)
    );

    // ------------------------------------------------------------------
    // Program completion: the NMI handler's marker write (as in tb_m1_cpu).
    // ------------------------------------------------------------------
    bit done;
    initial done = 0;
    always @(negedge clk)
        if (rst_n && !u_core.wr_n && !u_core.vid_n
            && u_core.addr[9:0] == 10'h3FF && u_core.bus == 8'hBF)
            done <= 1;

    // ------------------------------------------------------------------
    // ROM loader (test image, built by sim/tools/build_test_image.py).
    // ------------------------------------------------------------------
    logic [7:0] image [0:4095];
    task automatic load_rom;
        int i;
        $readmemh("../../../sim/build/testimg.hex", image);
        @(negedge clk);
        for (i = 0; i < 4096; i++) begin
            ld_en = 1; ld_addr = 14'(i); ld_data = image[i];
            @(negedge clk);
        end
        ld_en = 0;
        @(negedge clk);
    endtask

    // watchdog: the whole run needs ~75 ms of simulated time; a silent hang
    // (e.g. a missing test image) must fail loudly instead of spinning.
    initial begin
        #200_000_000;
        $fatal(1, "watchdog: bench did not finish within 200 ms simulated time");
    end

    // ------------------------------------------------------------------
    initial begin
        int fd, x, y, c, mism;
        logic expct;
        byte fbdump [0:191][0:383];

        ld_en = 0; ld_addr = '0; ld_data = '0;

        repeat (4) @(negedge clk);
        rst_n = 1;
        load_rom();
        rst_n = 0;
        repeat (8) @(negedge clk);
        rst_n = 1;

        wait (done);
        // let two full frames render the final (static) screen into the fb
        repeat (2 * 672 * 264) @(negedge clk);

        // ---- read the reference frame (header "P5\n384 192\n255\n") ----
        fd = $fopen("../../../sim/build/frame_cpu.pgm", "rb");
        if (fd == 0)
            $fatal(1, "reference ../../../sim/build/frame_cpu.pgm missing — run make in sim/ first");
        repeat (15) void'($fgetc(fd));

        // ---- read back through the pixel-clock port and compare ----
        mism = 0;
        for (y = 0; y < 192; y++) begin
            for (x = 0; x < 384; x++) begin
                rd_addr = 17'(y * 384 + x);
                @(posedge clk_pix);
                @(posedge clk_pix); #1;      // registered read settles
                c = $fgetc(fd);
                expct = (c != 0);
                fbdump[y][x] = rd_bit ? 8'hFF : 8'h00;
                if (rd_bit !== expct) begin
                    if (mism < 10)
                        $display("FAIL  (%0d,%0d): fb %b, reference %b", x, y, rd_bit, expct);
                    mism++;
                end
            end
        end
        $fclose(fd);

        // dump what the capture saw, for eyeballing
        fd = $fopen("build/frame_fb.pgm", "wb");
        $fwrite(fd, "P5\n384 192\n255\n");
        for (y = 0; y < 192; y++)
            for (x = 0; x < 384; x++) $fwrite(fd, "%c", fbdump[y][x]);
        $fclose(fd);

        if (mism != 0) begin
            $display("FAIL  %0d of 73728 cells differ from frame_cpu.pgm", mism);
            errors++;
        end else
            $display("  ok  capture == frame_cpu.pgm, 73728/73728 cells");

        if (errors == 0) $display("ALL CHECKS PASSED");
        else             $display("%0d CHECKS FAILED", errors);
        $finish;
    end

endmodule
