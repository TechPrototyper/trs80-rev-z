// Testbench: m1_sd_fs — drive mounts + sector server (EI stage-0 layer).
//
// Runs the full filesystem brain against the SPI card model and proves,
// per +mode=:
//
//   drives   card with TRS80/LEVEL2.ROM plus DRIVE0..3/: DRIVE0 holds a
//            FRAGMENTED image, DRIVE1 an image whose size is not a
//            multiple of 512 (partial last sector), DRIVE2 only the
//            NOTES.TXT decoy (must stay unmounted), DRIVE3 a plain
//            image. Checks: mount mask, the ROM still arrives byte-exact
//            over the ld_* seam, a full sequential read of the
//            fragmented image, spot reads (first/middle/last sector,
//            drives interleaved to prove random access), and rq_err on
//            an unmounted drive / an out-of-range sector.
//            (+sdsc reruns everything on a byte-addressed SDSC card.)
//   none     card whose TRS80/ has neither ROM nor drive directories:
//            err (ROM fallback), all drives unmounted, requests answered
//            with rq_err — and fs_ready still comes up.
//
// Payload references come from tools/build_fat32.py (+d0/+d1/+d3 hex
// files, +sz0/+sz1/+sz3 byte sizes, +mounts expected mask).

`timescale 1ns / 1ps

// Waiver (testbench-only, per repo policy): plusarg holders and int-typed
// task/function arguments keep the stimulus readable — their sliced-off
// upper bits (and the unused loading flag) are deliberate, not oversights.
/* verilator lint_off UNUSEDSIGNAL */

module tb_sd_fs;

    logic clk, rst_n;
    initial begin clk = 0; rst_n = 0; end
    always #46.97 clk = ~clk;

    int errors = 0;

    string mode;
    int    sz [0:3];
    int    mounts_exp;
    initial begin
        if (!$value$plusargs("mode=%s", mode)) mode = "drives";
        if (!$value$plusargs("sz0=%d", sz[0])) sz[0] = 0;
        if (!$value$plusargs("sz1=%d", sz[1])) sz[1] = 0;
        sz[2] = 0;
        if (!$value$plusargs("sz3=%d", sz[3])) sz[3] = 0;
        if (!$value$plusargs("mounts=%d", mounts_exp)) mounts_exp = 0;
    end

    // --- device under test + card model (fast SPI for simulation) ---
    wire        sd_sck, sd_mosi, sd_cs_n, card_miso;

    logic       rq_req;
    logic [2:0] rq_drv;
    logic [12:0] rq_fsec;
    wire        rq_vld, rq_done, rq_err;
    wire [7:0]  rq_dat;
    wire [8:0]  rq_idx;

    logic        wq_req;
    logic [2:0]  wq_drv;
    logic [12:0] wq_fsec;
    wire         wq_fetch, wq_done, wq_err;
    wire  [8:0]  wq_idx;
    logic [7:0]  wq_dat;
    logic [7:0]  wseed;

    // pull-style supply: pattern byte two clocks after wq_fetch
    logic [8:0] wq_idx_d;
    always @(posedge clk) begin
        if (wq_fetch) wq_idx_d <= wq_idx;
        wq_dat <= wq_idx_d[7:0] ^ wseed;
    end

    wire        ld_en, sd_loading, sd_ok, sd_err, fs_ready;
    wire [13:0] ld_addr;
    wire [7:0]  ld_data;
    wire [5:0]  drv_mounted;

    m1_sd_fs #(.HALF_INIT(8'd4), .HALF_FAST(8'd1)) u_fs (
        .clk(clk), .rst_n(rst_n),
        .sd_sck(sd_sck), .sd_mosi(sd_mosi),
        .sd_miso(card_miso), .sd_cs_n(sd_cs_n),
        .ld_gate(1'b1),                  // no self-test stage in this bench
        .ld_en(ld_en), .ld_addr(ld_addr), .ld_data(ld_data),
        .loading(sd_loading), .ok(sd_ok), .err(sd_err),
        /* verilator lint_off PINCONNECTEMPTY */
        .sys_ready(), .init_err(),
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

    // --- references ---
    logic [7:0] rom_ref [0:16383];
    logic [7:0] p0 [0:65535];
    logic [7:0] p1 [0:65535];
    logic [7:0] p3 [0:65535];
    initial begin
        string fn;
        if ($value$plusargs("payload=%s", fn)) $readmemh(fn, rom_ref);
        if ($value$plusargs("d0=%s", fn))      $readmemh(fn, p0);
        if ($value$plusargs("d1=%s", fn))      $readmemh(fn, p1);
        if ($value$plusargs("d3=%s", fn))      $readmemh(fn, p3);
    end

    function automatic logic [7:0] ref_byte(input int drv, input int off);
        case (drv)
            0: ref_byte = p0[off];
            1: ref_byte = p1[off];
            3: ref_byte = p3[off];
            default: ref_byte = 8'hxx;
        endcase
    endfunction

    // --- capture the ld_* seam (no core here: the seam is the contract) ---
    logic [7:0] romw [0:16383];
    always @(posedge clk) if (ld_en) romw[ld_addr] <= ld_data;

    // --- capture one served sector ---
    logic [7:0] sbuf [0:511];
    always @(posedge clk) if (rq_vld) sbuf[rq_idx] <= rq_dat;

    bit got_done, got_err;
    always @(posedge clk) begin
        if (rq_done || wq_done) got_done <= 1;
        if (rq_err  || wq_err)  got_err  <= 1;
    end

    task automatic write_sector(input int drv, input int fsec,
                                input logic [7:0] seed, output bit okr);
        wseed = seed;
        got_done = 0; got_err = 0;
        @(negedge clk);
        wq_req  = 1;
        wq_drv  = 3'(drv);
        wq_fsec = 13'(fsec);
        @(negedge clk);
        wq_req  = 0;
        wait (got_done || got_err);
        okr = got_done;
        repeat (2) @(negedge clk);
    endtask

    task automatic read_sector(input int drv, input int fsec,
                               output bit okr);
        got_done = 0; got_err = 0;
        @(negedge clk);
        rq_req  = 1;
        rq_drv  = 3'(drv);
        rq_fsec = 13'(fsec);
        @(negedge clk);
        rq_req  = 0;
        wait (got_done || got_err);
        okr = got_done;
    endtask

    // compare one sector against the reference (partial last sector:
    // only the bytes inside the file are meaningful)
    task automatic check_sector(input int drv, input int fsec,
                                input string what);
        bit okr;
        int i, lim, mism;
        read_sector(drv, fsec, okr);
        if (!okr) begin
            $display("FAIL  rq_err on %s (drv %0d sector %0d)",
                     what, drv, fsec);
            errors++;
            return;
        end
        lim = sz[drv] - fsec * 512;
        if (lim > 512) lim = 512;
        mism = 0;
        for (i = 0; i < lim; i++)
            if (sbuf[i] !== ref_byte(drv, fsec * 512 + i)) begin
                if (mism < 3)
                    $display("FAIL  drv %0d sec %0d byte %0d = %02h != %02h (%s)",
                             drv, fsec, i, sbuf[i],
                             ref_byte(drv, fsec * 512 + i), what);
                mism++;
            end
        if (mism != 0) begin
            $display("FAIL  %0d bytes differ (%s)", mism, what);
            errors++;
        end
    endtask

    task automatic expect_err(input int drv, input int fsec,
                              input string what);
        bit okr;
        read_sector(drv, fsec, okr);
        if (okr) begin
            $display("FAIL  expected rq_err: %s", what);
            errors++;
        end else
            $display("  ok  rq_err as expected: %s", what);
    endtask

    function automatic int nsec(input int bytes);
        nsec = (bytes + 511) / 512;
    endfunction

    initial begin
        #600_000_000;
        $fatal(1, "watchdog: mode %s did not finish in 600 ms", mode);
    end

    initial begin
        int s, mism;

        rq_req = 0; rq_drv = 0; rq_fsec = 0;
        wq_req = 0; wq_drv = 0; wq_fsec = 0; wseed = 0;
        repeat (4) @(negedge clk);
        rst_n = 1;

        wait (fs_ready);
        repeat (4) @(negedge clk);

        case (mode)
            "drives": begin
                if (!sd_ok || sd_err) begin
                    $display("FAIL  ROM flags: ok=%b err=%b", sd_ok, sd_err);
                    errors++;
                end
                if (drv_mounted[3:0] !== 4'(mounts_exp)) begin
                    $display("FAIL  mounts %b, expected %b",
                             drv_mounted[3:0], 4'(mounts_exp));
                    errors++;
                end else
                    $display("  ok  mount mask %b", drv_mounted[3:0]);

                // the ROM still arrived byte-exact over the ld_* seam
                mism = 0;
                for (s = 0; s < 12288; s++)
                    if (romw[s] !== rom_ref[s]) mism++;
                if (mism != 0) begin
                    $display("FAIL  ROM seam: %0d bytes differ", mism);
                    errors++;
                end else
                    $display("  ok  ROM over ld_* seam, 12288/12288 bytes");

                // full sequential read of the fragmented image
                for (s = 0; s < nsec(sz[0]); s++)
                    check_sector(0, s, "drive 0 full read");
                $display("  ok  drive 0 read in full, %0d sectors (%s)",
                         nsec(sz[0]), errors == 0 ? "clean" : "with FAILs");

                // random access: first/middle/last, drives interleaved
                check_sector(1, 0,               "drive 1 first sector");
                check_sector(3, nsec(sz[3]) / 2, "drive 3 middle sector");
                check_sector(1, nsec(sz[1]) - 1, "drive 1 last (partial)");
                check_sector(0, nsec(sz[0]) - 1, "drive 0 revisited");
                check_sector(3, 0,               "drive 3 first sector");
                $display("  ok  spot reads done (drv 1/3 interleaved)");

                // ---- write path: overwrite a sector, read it back ----
                begin
                    bit okw;
                    write_sector(3, 5, 8'hA7, okw);
                    if (!okw) begin
                        $display("FAIL  write to drive 3 refused");
                        errors++;
                    end
                    read_sector(3, 5, okw);
                    if (!okw) begin
                        $display("FAIL  readback after write refused");
                        errors++;
                    end else begin
                        mism = 0;
                        for (s = 0; s < 512; s++)
                            if (sbuf[s] !== (8'(s) ^ 8'hA7)) mism++;
                        if (mism != 0) begin
                            $display("FAIL  write/readback: %0d differ", mism);
                            errors++;
                        end else
                            $display("  ok  sector written via CMD24, read back byte-exact");
                    end
                    // neighbours untouched
                    check_sector(3, 4, "drive 3 sector before the write");
                    check_sector(3, 6, "drive 3 sector after the write");
                    write_sector(2, 0, 8'h00, okw);
                    if (okw) begin
                        $display("FAIL  write to unmounted drive accepted");
                        errors++;
                    end else
                        $display("  ok  wq_err for the unmounted drive");
                end

                // refusal paths
                expect_err(2, 0, "unmounted drive 2");
                expect_err(1, nsec(sz[1]), "sector just past drive 1 EOF");
                expect_err(1, 8191, "sector far out of range");
            end

            "none": begin
                if (drv_mounted[3:0] !== 4'b0000) begin
                    $display("FAIL  mounts %b on an empty card", drv_mounted[3:0]);
                    errors++;
                end
                if (!sd_err || sd_ok) begin
                    $display("FAIL  ROM flags: ok=%b err=%b", sd_ok, sd_err);
                    errors++;
                end
                $display("  ok  no images: all unmounted, err flagged");
                expect_err(0, 0, "request on an unmounted system");
            end

            default: $fatal(1, "unknown +mode=%s", mode);
        endcase

        if (errors == 0) $display("ALL CHECKS PASSED (%s)", mode);
        else             $display("%0d CHECKS FAILED (%s)", errors, mode);
        if (errors != 0) $fatal(1, "tb_sd_fs failed");
        $finish;
    end

endmodule
