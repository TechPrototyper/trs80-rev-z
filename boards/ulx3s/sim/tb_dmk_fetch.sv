// Testbench: m1_dmk_fetch — track requests against a DMK on the FAT card.
//
// Full board-side media chain: SPI card model -> m1_sd_fs (mount DRIVE1)
// -> m1_dmk_fetch, with the repository DMK generator's disk as the card
// payload (+img from build_fat32.py --drive 1:@...; +dmk = the same DMK
// as hex for reference). Proves: the header snapshot (trk_len 0x0CC0,
// trk_dbl 0), a full track streamed byte-exactly (track 2), a second
// fetch from a different track (track 17), and the refusal paths
// (unmounted drive, track beyond the header's track count).

`timescale 1ns / 1ps

// Waiver (testbench-only, per repo policy): int-typed task arguments
// keep the stimulus readable; their upper bits are deliberately unused.
/* verilator lint_off UNUSEDSIGNAL */

module tb_dmk_fetch;

    logic clk, rst_n;
    initial begin clk = 0; rst_n = 0; end
    always #46.97 clk = ~clk;

    int errors = 0;

    // --- card -> filesystem ---
    wire sd_sck, sd_mosi, sd_cs_n, card_miso;

    wire        fs_ready, rq_vld, rq_done, rq_err;
    wire [5:0]  drv_mounted;
    wire [7:0]  rq_dat;
    wire [8:0]  rq_idx;
    wire        rq_req;
    wire [2:0]  rq_drv;
    wire [1:0]  rq_drv2;
    wire [12:0] rq_fsec;

    m1_sd_fs #(.HALF_INIT(8'd4), .HALF_FAST(8'd1)) u_fs (
        .clk(clk), .rst_n(rst_n),
        .sd_sck(sd_sck), .sd_mosi(sd_mosi),
        .sd_miso(card_miso), .sd_cs_n(sd_cs_n),
        .ld_gate(1'b1),
        /* verilator lint_off PINCONNECTEMPTY */
        .ld_en(), .ld_addr(), .ld_data(),
        .loading(), .sys_ready(), .ok(), .err(), .init_err(),
        /* verilator lint_on PINCONNECTEMPTY */
        .drv_mounted(drv_mounted), .fs_ready(fs_ready),
        /* verilator lint_off PINCONNECTEMPTY */
        .cas_len(),
        /* verilator lint_on PINCONNECTEMPTY */
        .rq_req(rq_req), .rq_drv(rq_drv), .rq_fsec(rq_fsec),
        .rq_vld(rq_vld), .rq_dat(rq_dat), .rq_idx(rq_idx),
        .rq_done(rq_done), .rq_err(rq_err),
        .wq_req(wq_req), .wq_drv(wq_drv), .wq_fsec(wq_fsec),
        .wq_fetch(wq_fetch), .wq_idx(wq_idx), .wq_dat(wq_dat),
        .wq_done(wq_done), .wq_err(wq_err)
    );

    sd_card_model u_card (
        .sck(sd_sck), .mosi(sd_mosi), .cs_n(sd_cs_n), .miso(card_miso)
    );

    // --- fetcher under test ---
    logic        trk_req;
    logic [1:0]  trk_drv;
    logic [6:0]  trk_track;
    wire         trk_vld, trk_done, trk_err, trk_dbl;
    wire  [7:0]  trk_data;
    wire  [12:0] trk_idx, trk_len;

    logic        trk_wb_req;
    wire         trk_wb_fetch, trk_wb_done, trk_wb_err;
    wire  [12:0] trk_wb_idx;
    logic [7:0]  trk_wb_data;
    wire  [3:0]  drv_wp;
    wire         wq_req, wq_fetch, wq_done, wq_err;
    wire  [1:0]  wq_drv2;
    wire  [2:0]  wq_drv;
    wire  [12:0] wq_fsec;
    wire  [8:0]  wq_idx;
    wire  [7:0]  wq_dat;

    // FDC-buffer stand-in: modified track bytes = reference XOR 0x5A,
    // answered two clocks after each fetch (the FDC's registered read)
    logic [12:0] wbf_idx_d;
    logic [12:0] wb_base;
    always @(posedge clk) begin
        if (trk_wb_fetch) wbf_idx_d <= trk_wb_idx;
        trk_wb_data <= ref_dmk[int'(wb_base) + int'(wbf_idx_d)] ^ 8'h5A;
    end

    assign rq_drv = {1'b0, rq_drv2};
    assign wq_drv = {1'b0, wq_drv2};

    m1_dmk_fetch u_fetch (
        .clk(clk), .rst_n(rst_n),
        .fs_ready(fs_ready), .drv_mounted(drv_mounted[3:0]),
        .rq_req(rq_req), .rq_drv(rq_drv2), .rq_fsec(rq_fsec),
        .rq_vld(rq_vld), .rq_dat(rq_dat), .rq_idx(rq_idx),
        .rq_done(rq_done), .rq_err(rq_err),
        .wq_req(wq_req), .wq_drv(wq_drv2), .wq_fsec(wq_fsec),
        .wq_fetch(wq_fetch), .wq_idx(wq_idx), .wq_dat(wq_dat),
        .wq_done(wq_done), .wq_err(wq_err),
        .trk_req(trk_req), .trk_drv(trk_drv), .trk_track(trk_track),
        .trk_side(1'b0),
        .trk_vld(trk_vld), .trk_data(trk_data), .trk_idx(trk_idx),
        .trk_done(trk_done), .trk_err(trk_err),
        .trk_len(trk_len), .trk_dbl(trk_dbl), .drv_wp(drv_wp),
        .trk_wb_req(trk_wb_req), .trk_wb_fetch(trk_wb_fetch),
        .trk_wb_idx(trk_wb_idx), .trk_wb_data(trk_wb_data),
        .trk_wb_done(trk_wb_done), .trk_wb_err(trk_wb_err)
    );

    // --- reference DMK ---
    logic [7:0] ref_dmk [0:262143];
    initial begin
        string fn;
        if ($value$plusargs("dmk=%s", fn)) $readmemh(fn, ref_dmk);
    end

    // --- captured track ---
    logic [7:0] cap [0:8191];
    int         ncap;
    initial ncap = 0;
    always @(posedge clk) begin
        if (trk_vld) begin
            cap[trk_idx] <= trk_data;
            ncap <= ncap + 1;
        end
    end

    bit got_done, got_err;
    always @(posedge clk) begin
        if (trk_done || trk_wb_done) got_done <= 1;
        if (trk_err  || trk_wb_err)  got_err  <= 1;
    end

    task automatic writeback(input int track, output bit okr);
        wb_base = 13'(16 + track * 3264);
        got_done = 0; got_err = 0;
        @(negedge clk);
        trk_wb_req = 1;
        trk_drv    = 2'd1;
        trk_track  = 7'(track);
        @(negedge clk);
        trk_wb_req = 0;
        wait (got_done || got_err);
        okr = got_done;
        repeat (2) @(negedge clk);
    endtask

    task automatic fetch(input int drv, input int track, output bit okr);
        got_done = 0; got_err = 0; ncap = 0;
        @(negedge clk);
        trk_req   = 1;
        trk_drv   = 2'(drv);
        trk_track = 7'(track);
        @(negedge clk);
        trk_req = 0;
        wait (got_done || got_err);
        okr = got_done;
        repeat (2) @(negedge clk);
    endtask

    task automatic check_track(input int track);
        bit okr;
        int base, mism;
        fetch(1, track, okr);
        if (!okr) begin
            $display("FAIL  fetch track %0d refused", track);
            errors++;
            return;
        end
        if (trk_len !== 13'd3264 || trk_dbl !== 1'b0) begin
            $display("FAIL  header: len=%0d dbl=%b", trk_len, trk_dbl);
            errors++;
        end
        if (ncap != 3264) begin
            $display("FAIL  track %0d: %0d/3264 bytes streamed",
                     track, ncap);
            errors++;
        end
        base = 16 + track * 3264;
        mism = 0;
        for (int i = 0; i < 3264; i++)
            if (cap[i] !== ref_dmk[base + i]) begin
                if (mism < 3)
                    $display("FAIL  track %0d byte %0d = %02h != %02h",
                             track, i, cap[i], ref_dmk[base + i]);
                mism++;
            end
        if (mism != 0) begin
            $display("FAIL  track %0d: %0d bytes differ", track, mism);
            errors++;
        end else
            $display("  ok  track %0d streamed byte-exactly (3264 bytes)",
                     track);
    endtask

    initial begin
        bit okr;

        trk_req = 0; trk_drv = 0; trk_track = 0;
        trk_wb_req = 0; wb_base = 0;
        repeat (4) @(negedge clk);
        rst_n = 1;

        wait (fs_ready);
        // give the header snapshot pass time to finish
        repeat (400_000) @(negedge clk);

        if (drv_mounted[3:0] !== 4'b0010) begin
            $display("FAIL  mounts %b, expected 0010", drv_mounted[3:0]);
            errors++;
        end else
            $display("  ok  DRIVE1 mounted");

        check_track(2);
        check_track(17);

        fetch(0, 0, okr);
        if (okr) begin
            $display("FAIL  unmounted drive 0 served a track");
            errors++;
        end else
            $display("  ok  trk_err for the unmounted drive");

        fetch(1, 40, okr);
        if (okr) begin
            $display("FAIL  track 40 of a 35-track image served");
            errors++;
        end else
            $display("  ok  trk_err beyond the track count");

        // ---- write-back: modified track 2 through read-merge-write ----
        if (drv_wp !== 4'b0000) begin
            $display("FAIL  wp mask %b for a writable image", drv_wp);
            errors++;
        end
        writeback(2, okr);
        if (!okr) begin
            $display("FAIL  write-back of track 2 refused");
            errors++;
        end else begin
            // the card must now hold ref^5A for track 2 ...
            got_done = 0; got_err = 0; ncap = 0;
            @(negedge clk);
            trk_req = 1; trk_drv = 2'd1; trk_track = 7'd2;
            @(negedge clk);
            trk_req = 0;
            wait (got_done || got_err);
            repeat (2) @(negedge clk);
            begin
                int base, mism;
                base = 16 + 2 * 3264;
                mism = 0;
                for (int i = 0; i < 3264; i++)
                    if (cap[i] !== (ref_dmk[base + i] ^ 8'h5A)) mism++;
                if (mism != 0) begin
                    $display("FAIL  track 2 after WB: %0d differ", mism);
                    errors++;
                end else
                    $display("  ok  track 2 written back byte-exact (3264)");
            end
            // ... while the unaligned EDGES of tracks 1 and 3 survived
            check_track(1);
            check_track(3);
            $display("  ok  neighbour tracks 1/3 intact (merge edges)");
        end

        if (errors == 0) $display("ALL CHECKS PASSED");
        else             $display("%0d CHECKS FAILED", errors);
        if (errors != 0) $fatal(1, "tb_dmk_fetch failed");
        $finish;
    end

    initial begin
        #600_000_000;
        $fatal(1, "watchdog: dmk fetch bench did not finish");
    end

endmodule
