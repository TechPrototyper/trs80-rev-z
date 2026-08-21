// Testbench: m1_cass_sd — the SD cassette deck end to end (M2).
//
// Full board-side chain: SPI card model -> m1_sd_fs (slots 4/5) ->
// m1_sd_arb (client 0 idle) -> m1_cass_sd. The card carries
// TRS80/CASSETTE/TAPE.CAS (+cas = its bytes as hex) and a zero-filled
// TRS80/CASSOUT.CAS. Proves:
//
//   1. mounts: slots 4 and 5 come up, cas_len matches the tape
//   2. play: the full tape decodes byte-exact from the cass_in pulse
//      train (500-baud rule: clock pulse per 2 ms cell, data pulse
//      1 ms in = '1' — the timing pinned by sim/make golden-cass)
//   3. rewind: a motor stop at end-of-tape rewinds; the first byte
//      plays again
//   4. pause: the tape freezes with the motor (no pulses, nothing
//      lost — a real deck pauses mid-pulse and resumes in place)
//   5. record: pulses banged onto the output ladder come back as
//      decoded bytes inside CASSOUT.CAS on the card (backdoor read),
//      zero-padded to the sector edge

`timescale 1ns / 1ps

// Waiver (testbench-only, per repo policy): int-typed task arguments
// keep the stimulus readable; their upper bits are deliberately unused.
/* verilator lint_off UNUSEDSIGNAL */

module tb_cass_sd;

    logic clk, rst_n;
    initial begin clk = 0; rst_n = 0; end
    always #46.97 clk = ~clk;

    int errors = 0;

    // --- card -> filesystem ---
    wire sd_sck, sd_mosi, sd_cs_n, card_miso;

    wire        fs_ready, rq_vld, rq_done, rq_err;
    wire [5:0]  drv_mounted;
    wire [31:0] cas_len;
    wire [7:0]  rq_dat;
    wire [8:0]  rq_idx;
    wire        rq_req;
    wire [2:0]  rq_drv;
    wire [12:0] rq_fsec;
    wire        wq_req, wq_fetch, wq_done, wq_err;
    wire [2:0]  wq_drv;
    wire [12:0] wq_fsec;
    wire [8:0]  wq_idx;
    wire [7:0]  wq_dat;

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
        .cas_len(cas_len),
        .rq_req(rq_req), .rq_drv(rq_drv), .rq_fsec(rq_fsec),
        .rq_vld(rq_vld), .rq_dat(rq_dat), .rq_idx(rq_idx),
        .rq_done(rq_done), .rq_err(rq_err),
        .wq_req(wq_req), .wq_drv(wq_drv), .wq_fsec(wq_fsec),
        .wq_fetch(wq_fetch), .wq_idx(wq_idx), .wq_dat(wq_dat),
        .wq_done(wq_done), .wq_err(wq_err)
    );

    sd_card_model u_card (
        .sck(sd_sck), .mosi(sd_mosi), .miso(card_miso), .cs_n(sd_cs_n)
    );

    // --- arbiter with an idle client 0 ---
    wire        c1_rq_req, c1_rq_vld, c1_rq_done, c1_rq_err;
    wire [12:0] c1_rq_fsec;
    wire [7:0]  c1_rq_dat;
    wire [8:0]  c1_rq_idx;
    wire        c1_wq_req, c1_wq_fetch, c1_wq_done, c1_wq_err;
    wire [12:0] c1_wq_fsec;
    wire [8:0]  c1_wq_idx;
    wire [7:0]  c1_wq_dat;

    m1_sd_arb u_arb (
        .clk(clk), .rst_n(rst_n),
        .rq_req(rq_req), .rq_drv(rq_drv), .rq_fsec(rq_fsec),
        .rq_vld(rq_vld), .rq_dat(rq_dat), .rq_idx(rq_idx),
        .rq_done(rq_done), .rq_err(rq_err),
        .wq_req(wq_req), .wq_drv(wq_drv), .wq_fsec(wq_fsec),
        .wq_fetch(wq_fetch), .wq_idx(wq_idx), .wq_dat(wq_dat),
        .wq_done(wq_done), .wq_err(wq_err),
        .c0_rq_req(1'b0), .c0_rq_drv(2'd0), .c0_rq_fsec(13'd0),
        /* verilator lint_off PINCONNECTEMPTY */
        .c0_rq_vld(), .c0_rq_dat(), .c0_rq_idx(),
        .c0_rq_done(), .c0_rq_err(),
        .c0_wq_fetch(), .c0_wq_idx(), .c0_wq_done(), .c0_wq_err(),
        /* verilator lint_on PINCONNECTEMPTY */
        .c0_wq_req(1'b0), .c0_wq_drv(2'd0), .c0_wq_fsec(13'd0),
        .c0_wq_dat(8'd0),
        .c1_rq_req(c1_rq_req), .c1_rq_fsec(c1_rq_fsec),
        .c1_rq_vld(c1_rq_vld), .c1_rq_dat(c1_rq_dat),
        .c1_rq_idx(c1_rq_idx),
        .c1_rq_done(c1_rq_done), .c1_rq_err(c1_rq_err),
        .c1_wq_req(c1_wq_req), .c1_wq_fsec(c1_wq_fsec),
        .c1_wq_fetch(c1_wq_fetch), .c1_wq_idx(c1_wq_idx),
        .c1_wq_dat(c1_wq_dat),
        .c1_wq_done(c1_wq_done), .c1_wq_err(c1_wq_err)
    );

    // --- the deck ---
    logic       motor;
    logic [1:0] ladder;
    wire        cass_in;

    m1_cass_sd u_cass (
        .clk(clk), .rst_n(rst_n),
        .fs_ready(fs_ready),
        .cas_in_ok(drv_mounted[4]), .cas_out_ok(drv_mounted[5]),
        .cas_len(cas_len),
        .rq_req(c1_rq_req), .rq_fsec(c1_rq_fsec),
        .rq_vld(c1_rq_vld), .rq_dat(c1_rq_dat), .rq_idx(c1_rq_idx),
        .rq_done(c1_rq_done), .rq_err(c1_rq_err),
        .wq_req(c1_wq_req), .wq_fsec(c1_wq_fsec),
        .wq_fetch(c1_wq_fetch), .wq_idx(c1_wq_idx),
        .wq_dat(c1_wq_dat),
        .wq_done(c1_wq_done), .wq_err(c1_wq_err),
        .motor(motor), .cass_out(ladder), .cass_in(cass_in)
    );

    // --- expected tape bytes (+cas=<hex>, +clen=<n>) ---
    logic [7:0] tape [0:255];
    int         clen;
    initial begin
        string fn;
        clen = 0;
        if ($value$plusargs("cas=%s", fn))
            $readmemh(fn, tape);
        void'($value$plusargs("clen=%d", clen));
    end

    // --- pulse capture on cass_in ---
    realtime  ptimes [$];
    always @(posedge cass_in)
        ptimes.push_back($realtime);

    // decode the captured train with the golden-pinned rule
    function automatic void decode(output logic [7:0] bytes_out [$]);
        int  i;
        int  bits [$];
        logic [7:0] b;
        i = 0;
        while (i < ptimes.size() - 1) begin
            if (ptimes[i + 1] - ptimes[i] < 1_500_000.0) begin
                bits.push_back(1);
                i += 2;
            end else begin
                bits.push_back(0);
                i += 1;
            end
        end
        repeat (16) bits.push_back(0);       // final byte pad
        while (bits.size() >= 8) begin
            b = 8'd0;
            for (int j = 0; j < 8; j++) begin
                b = {b[6:0], bits[0][0]};
                bits.pop_front();
            end
            bytes_out.push_back(b);
        end
    endfunction

    // --- record stimulus: one ladder pulse (11 -> 00 -> 10) ---
    task automatic wpulse();
        ladder = 2'b11; #100_000;            // ~100 us positive
        ladder = 2'b00; #100_000;            // ~100 us negative
        ladder = 2'b10;                      // back to center
    endtask

    task automatic wbyte(input logic [7:0] b);
        for (int i = 7; i >= 0; i--) begin
            wpulse();                        // clock pulse
            #800_000;                        // -> ~1 ms
            if (b[i]) begin
                wpulse();
                #800_000;
            end else
                #1_000_000;
            #200_000;                        // -> ~2 ms cell
        end
    endtask

    logic [7:0] rec_pat [0:3];
    initial begin
        rec_pat[0] = 8'hC3; rec_pat[1] = 8'h3C;
        rec_pat[2] = 8'hA5; rec_pat[3] = 8'h5A;
    end

    initial begin
        logic [7:0] got [$];
        int  np, i, hit;

        motor  = 0;
        ladder = 2'b10;
        repeat (20) @(negedge clk);
        rst_n = 1;

        // ---- 1: mounts ----
        wait (fs_ready);
        repeat (10) @(negedge clk);
        if (drv_mounted[5:4] !== 2'b11) begin
            $display("FAIL  cassette slots %b, expected 11",
                     drv_mounted[5:4]);
            errors++;
        end else
            $display("  ok  slots 4+5 mounted");
        if (cas_len !== 32'(clen)) begin
            $display("FAIL  cas_len %0d, expected %0d", cas_len, clen);
            errors++;
        end else
            $display("  ok  cas_len = %0d", clen);

        // ---- 2: play the whole tape ----
        motor = 1;
        # (clen * 16_000_000 + 40_000_000);  // tape + slack
        if (!u_cass.at_eof) begin
            $display("FAIL  not at end-of-tape after full play");
            errors++;
        end
        decode(got);
        if (got.size() < clen) begin
            $display("FAIL  decoded %0d bytes, expected %0d",
                     got.size(), clen);
            errors++;
        end else begin
            for (i = 0; i < clen; i++)
                if (got[i] !== tape[i]) begin
                    $display("FAIL  tape byte %0d: %02h, expected %02h",
                             i, got[i], tape[i]);
                    errors++;
                end
            if (errors == 0)
                $display("  ok  %0d tape bytes decoded byte-exact", clen);
        end

        // ---- 3+4: rewind at EOF, then pause mid-play ----
        motor = 0;
        #3_000_000;
        ptimes.delete();
        motor = 1;
        #20_000_000;                         // ~1.25 byte times
        motor = 0;                           // pause mid-tape
        np = ptimes.size();
        #5_000_000;
        if (ptimes.size() != np) begin
            $display("FAIL  pulses while the motor was off");
            errors++;
        end else
            $display("  ok  tape frozen while the motor is off");
        motor = 1;
        #20_000_000;
        motor = 0;
        decode(got);
        if (got.size() < 1 || got[0] !== tape[0]) begin
            $display("FAIL  rewind: first byte %02h, expected %02h",
                     (got.size() != 0) ? got[0] : 8'hXX, tape[0]);
            errors++;
        end else
            $display("  ok  end-of-tape rewind: byte 0 plays again");

        // ---- 5: record four bytes, flush on motor stop ----
        #3_000_000;
        motor = 1;
        #2_000_000;
        for (i = 0; i < 4; i++)
            wbyte(rec_pat[i]);
        #3_000_000;
        motor = 0;                           // pad + flush the sector
        wait (u_cass.wsec == 13'd1);         // one CASSOUT sector written
        repeat (400) @(negedge clk);

        // backdoor: find the pattern inside the card image
        hit = -1;
        for (i = 0; i < $size(u_card.mem) - 8 && hit < 0; i++)
            if (u_card.mem[i] === rec_pat[0]
                && u_card.mem[i+1] === rec_pat[1]
                && u_card.mem[i+2] === rec_pat[2]
                && u_card.mem[i+3] === rec_pat[3])
                hit = i;
        if (hit < 0) begin
            $display("FAIL  recorded bytes not found on the card");
            errors++;
        end else if (u_card.mem[hit+4] !== 8'h00
                     || u_card.mem[hit+5] !== 8'h00) begin
            $display("FAIL  recording not zero-padded after the data");
            errors++;
        end else
            $display("  ok  CASSOUT.CAS holds %02h %02h %02h %02h + pad",
                     rec_pat[0], rec_pat[1], rec_pat[2], rec_pat[3]);

        if (errors == 0) $display("ALL CHECKS PASSED (SD cassette deck)");
        else             $display("%0d CHECKS FAILED", errors);
        if (errors != 0) $fatal(1);
        $finish;
    end

    initial begin
        #900_000_000;
        $fatal(1, "watchdog: SD cassette bench did not finish");
    end

endmodule
