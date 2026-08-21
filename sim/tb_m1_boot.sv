// Testbench: the machine boots from disk through the REAL Level II ROM
// (EI stage 4 — the boot chain).
//
// Loads a user-supplied 12 KiB Level II ROM image (+rom=<hex>; the ROM
// policy keeps masks out of the repository — the Makefile hexes an
// external file into build/) over the ld_* seam, puts a DMK behind the
// media model (+dmk=), and lets the ROM do what it does on a disk
// machine: detect the controller, select drive 0, restore, read track 0
// sector 0 to 0x4200 and jump. With build/bootdisk (build_dmk.py --boot)
// the loaded sector is OUR banner code — the end state is a static
// screen, checked here (+banner) and byte-compared against trs80gp
// running the SAME ROM and disk by make golden-boot.
//
// With a real DOS disk instead (DISK=/path override, no +banner), the
// bench just runs and dumps — the golden compare against trs80gp is the
// entire check. That is the stage-4 acceptance run once a NEWDOS/80
// image is supplied.
//
// The dump happens at a fixed machine time (+ms=, default 2500) — both
// sides sit in a static end state long before, so no frame alignment
// between tv80 and trs80gp is needed (the tv80 cycle-accuracy caveat).

`timescale 1ns / 1ps

module tb_m1_boot;

    logic clk, rst_n;
    initial begin clk = 0; rst_n = 0; end
    always #46.97 clk = ~clk;

    int errors = 0;

    int  runms;
    bit  want_banner;
    initial begin
        if (!$value$plusargs("ms=%d", runms)) runms = 2500;
        want_banner = $test$plusargs("banner");
    end

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
        .ei_ram_cfg(2'b10),                  // the full 48K machine
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

    logic [7:0] rom_img [0:12287];
    initial begin
        string fn;
        if ($value$plusargs("rom=%s", fn))
            $readmemh(fn, rom_img);
        else
            $fatal(1, "+rom=<hex> is required (12 KiB Level II image)");
    end

    function automatic logic [7:0] vram_byte(input logic [9:0] i);
        vram_byte = {u_core.u_vr.ram[i][6],
                     ~(u_core.u_vr.ram[i][5] | u_core.u_vr.ram[i][6]),
                     u_core.u_vr.ram[i][5:0]};
    endfunction

    localparam string BANNER = "TRS-80 REV Z  DISK BOOT OK";

    initial begin
        int i, fd;

        ld_en = 0; ld_addr = 0; ld_data = 0;
        repeat (4) @(negedge clk);
        for (i = 0; i < 12288; i++) begin
            @(negedge clk);
            ld_en   = 1;
            ld_addr = 14'(i);
            ld_data = rom_img[i];
        end
        @(negedge clk);
        ld_en = 0;
        rst_n = 1;

        // fixed machine time; the end state is static long before
        repeat (runms) #1_000_000;

        if (want_banner) begin
            for (i = 0; i < BANNER.len(); i++)
                if (vram_byte(10'(i)) !== 8'(BANNER[i])) begin
                    $display("FAIL  banner cell %0d = %02h, expected '%s'",
                             i, vram_byte(10'(i)), BANNER.substr(i, i));
                    errors++;
                end
            if (errors == 0)
                $display("  ok  ROM booted our sector: \"%s\"", BANNER);
        end

        fd = $fopen("build/vram_boot.bin", "wb");
        for (i = 0; i < 1024; i++)
            $fwrite(fd, "%c", vram_byte(10'(i)));
        $fclose(fd);
        $display("  ok  VRAM dumped: build/vram_boot.bin");

        if (errors == 0) $display("ALL CHECKS PASSED (boot chain)");
        else             $display("%0d CHECKS FAILED", errors);
        if (errors != 0) $fatal(1);
        $finish;
    end

    initial begin
        #8_000_000_000;
        $fatal(1, "watchdog: boot bench overran");
    end

endmodule
