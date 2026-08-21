// Testbench: m1_sd_loader — SD card -> FAT32 -> ROM, end to end.
//
// Wires selftest loader + SD loader + core exactly as ulx3s_top does
// (self-test first, SD loader re-loads the ROM behind a second reset)
// against the SPI SD card model, and proves per +mode=:
//
//   pattern  MBR card, fragmented 12 KiB file: ROM equals the payload
//            byte-for-byte after `ok` (12288/12288), the core was held
//            in reset during the stream and released after.
//            (+sdsc reruns this on a byte-addressed SDSC card.)
//   boot     superfloppy card carrying the repository's own test image
//            as TRS80/LEVEL2.ROM: ROM = image + zero fill, and the
//            machine boots it from SD to the golden completion marker.
//   nocard   no card (MISO idle high): loader reports err, never touches
//            the ROM, and the self-test fallback still reaches its marker.
//   nofile   FAT32 card without the file: same fallback guarantees.
//
// Prerequisites: `make` in ../../sim (testimg.hex) and the fat images
// from tools/build_fat32.py (sim Makefile builds them).

`timescale 1ns / 1ps

module tb_sd_loader;

    logic clk, rst_n;
    initial begin clk = 0; rst_n = 0; end
    always #46.97 clk = ~clk;

    int errors = 0;

    string mode;
    bit    has_card;
    int    plen;
    initial begin
        if (!$value$plusargs("mode=%s", mode)) mode = "pattern";
        if (!$value$plusargs("plen=%d", plen)) plen = 12288;
        has_card = (mode != "nocard");
    end

    // golden keys down, as in tb_selftest (the image polls row 6)
    logic [63:0] kb_keys;
    initial begin
        kb_keys = '0;
        kb_keys[8*6 + 7] = 1'b1;   // SPACE
        kb_keys[8*0 + 1] = 1'b1;   // 'A'
    end

    // --- self-test loader (power-on fallback) ---
    wire        st_en, st_done;
    wire [13:0] st_addr;
    wire [7:0]  st_data;

    m1_selftest_loader #(.IMG_HEX("../../../sim/build/testimg.hex"))
    u_st (
        .clk(clk), .rst_n(rst_n),
        .ld_en(st_en), .ld_addr(st_addr), .ld_data(st_data),
        .done(st_done)
    );

    // --- SD loader + card model (fast SPI dividers for simulation) ---
    wire        sd_sck, sd_mosi, sd_cs_n;
    wire        card_miso;
    wire        sd_miso = has_card ? card_miso : 1'b1;

    wire        sd_en, sd_loading, sd_ok, sd_err;
    wire [13:0] sd_addr;
    wire [7:0]  sd_data;

    m1_sd_fs #(.HALF_INIT(8'd4), .HALF_FAST(8'd1),
               .RETRY_DLY(24'd2000)) u_sd (
        .clk(clk), .rst_n(rst_n),
        .sd_sck(sd_sck), .sd_mosi(sd_mosi),
        .sd_miso(sd_miso), .sd_cs_n(sd_cs_n),
        .ld_gate(st_done),
        .ld_en(sd_en), .ld_addr(sd_addr), .ld_data(sd_data),
        .loading(sd_loading), .ok(sd_ok), .err(sd_err),
        /* verilator lint_off PINCONNECTEMPTY */
        .sys_ready(), .init_err(),
        /* verilator lint_on PINCONNECTEMPTY */
        // mount/serve phases idle here — tb_sd_fs covers them
        .rq_req(1'b0), .rq_drv(3'b000), .rq_fsec(13'd0),
        .wq_req(1'b0), .wq_drv(3'b000), .wq_fsec(13'd0), .wq_dat(8'd0),
        /* verilator lint_off PINCONNECTEMPTY */
        .wq_fetch(), .wq_idx(), .wq_done(), .wq_err(),
        /* verilator lint_on PINCONNECTEMPTY */
        /* verilator lint_off PINCONNECTEMPTY */
        .drv_mounted(), .fs_ready(), .cas_len(),
        .rq_vld(), .rq_dat(), .rq_idx(), .rq_done(), .rq_err()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    sd_card_model u_card (
        .sck(sd_sck), .mosi(sd_mosi), .cs_n(sd_cs_n), .miso(card_miso)
    );

    // --- the ld_* seam, mux'd as in ulx3s_top ---
    wire        ld_en   = sd_loading ? sd_en   : st_en;
    wire [13:0] ld_addr = sd_loading ? sd_addr : st_addr;
    wire [7:0]  ld_data = sd_loading ? sd_data : st_data;
    wire        core_rst_n = rst_n & st_done & ~sd_loading;

    m1_core #(.FONT_HEX("../../../rtl/mcm6670_cg1.hex")) u_core (
        .clk(clk), .por_rst_n(core_rst_n), .dbg_rst_n(core_rst_n), .reset_btn_n(1'b1),
        .test_n(1'b1), .int_n(1'b1), .wait_n(1'b1),
        .ld_en(ld_en), .ld_addr(ld_addr), .ld_data(ld_data),
        .ei_ram_cfg(2'b00),   // no EI RAM: 16K system, goldens unchanged
        .fdc_disk(4'b0000),   // (tb_sd_fs exercises the mounted-media path)
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
        .pixel(), .col(), .line(), .row(), .snd()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    // --- references ---
    logic [7:0] payload [0:16383];
    initial begin
        string pf;
        if ($value$plusargs("payload=%s", pf))
            $readmemh(pf, payload);
    end

    logic [7:0] st_img [0:4095];
    initial $readmemh("../../../sim/build/testimg.hex", st_img);

    // --- monitors ---
    bit saw_loading, gate_violated;
    initial begin saw_loading = 0; gate_violated = 0; end
    always @(posedge clk) begin
        if (sd_loading) saw_loading <= 1;
        // the SD loader must never write before the self-test released
        if (sd_loading && !st_done) gate_violated <= 1;
    end

    // golden completion marker, armed by the stimulus when meaningful
    bit arm_marker, marker;
    initial begin arm_marker = 0; marker = 0; end
    always @(negedge clk)
        if (arm_marker && core_rst_n && !u_core.wr_n && !u_core.vid_n
            && u_core.addr[9:0] == 10'h3FF && u_core.bus == 8'hBF)
            marker <= 1;

    initial begin
        #400_000_000;
        $fatal(1, "watchdog: mode %s did not finish in 400 ms", mode);
    end

    // Optional state tracing: build with +define+SD_DEBUG (needs
    // -Wno-SYNCASYNCNET — observing the state registers trips that lint).
`ifdef SD_DEBUG
    always @(u_sd.state)
        $display("%t  loader state -> %0d", $time, u_sd.state);
    always @(u_sd.u_spi.state)
        $display("%t  spi    state -> %0d (r1=%02h)", $time,
                 u_sd.u_spi.state, u_sd.u_spi.r1);
`endif

    task automatic check_rom(input int lo, input int hi,
                             input bit against_payload,
                             input bit against_zero,
                             input string what);
        int i, mism;
        logic [7:0] expect_b;
        mism = 0;
        for (i = lo; i < hi; i++) begin
            if (against_payload)   expect_b = payload[i];
            else if (against_zero) expect_b = 8'h00;
            else                   expect_b = st_img[i];
            if (u_core.u_rom.mem[i] !== expect_b) begin
                if (mism < 5)
                    $display("FAIL  rom[%0d] = %02h, expected %02h (%s)",
                             i, u_core.u_rom.mem[i], expect_b, what);
                mism++;
            end
        end
        if (mism != 0) begin
            $display("FAIL  %0d bytes differ (%s)", mism, what);
            errors++;
        end else
            $display("  ok  %s, %0d/%0d bytes", what, hi - lo, hi - lo);
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1;

        case (mode)
            "pattern": begin
                wait (sd_ok || sd_err);
                if (sd_err) $fatal(1, "loader flagged err on a good card");
                repeat (4) @(negedge clk);
                if (!saw_loading) begin
                    $display("FAIL  ok without a loading phase");
                    errors++;
                end
                if (!core_rst_n) begin
                    $display("FAIL  core still in reset after ok");
                    errors++;
                end
                check_rom(0, plen, 1, 0, "ROM == card payload");
                if (plen < 12288)
                    check_rom(plen, 12288, 0, 1, "ROM zero fill");
            end

            "boot": begin
                wait (sd_ok || sd_err);
                if (sd_err) $fatal(1, "loader flagged err on a good card");
                repeat (4) @(negedge clk);
                check_rom(0, plen, 1, 0, "ROM == card payload (test image)");
                check_rom(plen, 12288, 0, 1, "ROM zero fill");
                arm_marker = 1;
                wait (marker);
                $display("  ok  machine booted the SD-loaded image to the marker");
            end

            "nocard": begin
                arm_marker = 1;
                wait (sd_err);
                if (saw_loading || sd_ok) begin
                    $display("FAIL  loader touched the ROM with no card");
                    errors++;
                end
                wait (marker);
                $display("  ok  no card: err flagged, self-test fallback ran");
                check_rom(0, 4096, 0, 0, "ROM still the self-test image");
            end

            "nofile": begin
                arm_marker = 1;
                wait (sd_err);
                if (saw_loading || sd_ok) begin
                    $display("FAIL  loader touched the ROM without the file");
                    errors++;
                end
                wait (marker);
                $display("  ok  no file: err flagged, self-test fallback ran");
                check_rom(0, 4096, 0, 0, "ROM still the self-test image");
            end

            default: $fatal(1, "unknown +mode=%s", mode);
        endcase

        if (gate_violated) begin
            $display("FAIL  SD loader wrote before the self-test finished");
            errors++;
        end

        if (errors == 0) $display("ALL CHECKS PASSED (%s)", mode);
        else             $display("%0d CHECKS FAILED (%s)", errors, mode);
        if (errors != 0) $fatal(1, "tb_sd_loader failed");
        $finish;
    end

endmodule
