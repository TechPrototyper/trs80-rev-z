// TRS-80 Rev Z — SD cassette deck: .cas files behind the port-0xFF pins
//
// Own work (MIT). The board-side tape deck (M2): plays TRS80/CASSETTE/
// *.CAS (fs slot 4) into cass_in and records what the machine writes
// into the pre-allocated TRS80/CASSOUT.CAS (slot 5) — both through the
// m1_sd_arb client-1 port (level requests held until done/err).
//
// Play side: the 500-baud Level II encoding pinned by the sim goldens
// (make golden-cass) — 2 ms bit cells MSB first, a clock pulse at the
// cell start, a '1' adds a data pulse 1 ms in; each pulse drives
// cass_in high for PULSE_US, the shape the Z4 front end would deliver.
// The tape rolls only while the motor relay is closed and pauses in
// place when it opens; a motor stop at end-of-tape rewinds, so the
// next CLOAD finds the leader again. Bytes stream through a two-sector
// ping-pong buffer: while one half plays (a sector lasts ~8 s at 62
// bytes/s), the other prefetches — the FDC always wins the arbiter,
// and this deck never notices.
//
// Record side: every positive swing of the output ladder (cass_out ==
// 2'b11) is a pulse; the streaming decoder mirrors the golden-pinned
// rule (a pulse < 1.5 ms after the cell's clock is a data '1') and
// packs bits MSB first into bytes. Full 512-byte halves are written
// in place to CASSOUT.CAS as they fill; a motor stop flushes the
// partial rest zero-padded (trailing zeros read as leader bytes —
// harmless noise by the .cas convention). The write cursor only ever
// advances: successive saves append like a real tape until power-off
// (or the file is full, which simply stops the recorder).

module m1_cass_sd #(
    parameter [24:0] ACC_K    = 25'd1576139,   // 1 MHz off the dot clock
    parameter [7:0]  PULSE_US = 8'd50
) (
    input  wire        clk,          // dot clock
    input  wire        rst_n,

    // filesystem status (m1_sd_fs)
    input  wire        fs_ready,
    input  wire        cas_in_ok,    // slot 4 mounted (drv_mounted[4])
    input  wire        cas_out_ok,   // slot 5 mounted (drv_mounted[5])
    input  wire [31:0] cas_len,      // slot 4 file size in bytes

    // arbiter client-1 port (requests are LEVELS, held until done/err)
    output reg         rq_req,
    output reg  [12:0] rq_fsec,
    input  wire        rq_vld,
    input  wire [7:0]  rq_dat,
    input  wire [8:0]  rq_idx,
    input  wire        rq_done,
    input  wire        rq_err,
    output reg         wq_req,
    output reg  [12:0] wq_fsec,
    input  wire        wq_fetch,
    input  wire [8:0]  wq_idx,
    output wire [7:0]  wq_dat,
    input  wire        wq_done,
    input  wire        wq_err,

    // machine side (m1_core port-0xFF pins)
    input  wire        motor,        // cassette relay (D2)
    input  wire [1:0]  cass_out,     // output ladder {~Q1, Q0}
    output reg         cass_in
);

    // ------------------------------------------------------------------
    // State declarations (BRAM blocks follow, then the one FSM)
    // ------------------------------------------------------------------
    reg  [23:0] acc;
    wire [24:0] acc_n = {1'b0, acc} + ACC_K;
    wire        en_1m = acc_n[24];

    // play side
    reg  [20:0] byte_pos;            // absolute file byte being played
    wire [11:0] play_sec = byte_pos[20:9];
    reg  [12:0] half_sec [0:1];      // file sector each half holds
    reg  [1:0]  half_ok;
    reg         f_half;              // half being fetched
    reg         f_busy;
    reg  [12:0] f_sec;
    reg  [7:0]  cur_byte;
    reg  [2:0]  bit_i;
    reg  [11:0] cell_us;             // position inside the 2 ms bit cell
    reg  [1:0]  pstate;
    reg  [7:0]  high_us;             // remaining cass_in pulse width
    reg         motor_d;
    reg  [9:0]  pb_raddr;
    reg  [7:0]  pbuf_q;

    wire [12:0] file_secs = {1'b0, cas_len[20:9]} + {12'd0, |cas_len[8:0]};
    wire        at_eof    = ({11'd0, byte_pos} >= cas_len);
    wire [7:0]  play_bit_src = cur_byte;

    localparam [1:0] P_LOAD = 2'd0, P_SETTLE = 2'd1, P_RUN = 2'd2;

    // record side
    reg  [7:0]  wbuf_q;
    reg  [9:0]  wb_raddr;
    reg         wb_we;
    reg  [9:0]  wb_waddr;
    reg  [7:0]  wb_wdat;
    reg  [1:0]  out_d;
    reg  [11:0] wcell_us;            // time since the cell's clock pulse
    reg         in_cell;
    reg         wbit;
    reg  [6:0]  wshift;
    reg  [2:0]  wnbits;
    reg  [9:0]  wpos;                // {half, offset} write cursor
    reg  [12:0] wsec;                // next CASSOUT file sector
    reg         w_flush_half;
    reg         w_flush_busy;
    reg         w_full;              // CASSOUT exhausted: recorder off
    reg  [9:0]  w_pad;
    reg         w_padding;

    // ------------------------------------------------------------------
    // Buffers (two 512-byte halves each; registered reads for EBR)
    // ------------------------------------------------------------------
    reg [7:0] pbuf [0:1023];
    always @(posedge clk) begin
        if (rq_vld)
            pbuf[{f_half, rq_idx}] <= rq_dat;
        pbuf_q <= pbuf[pb_raddr];
    end

    reg [7:0] wbuf [0:1023];
    always @(posedge clk) begin
        if (wb_we)
            wbuf[wb_waddr] <= wb_wdat;
        wbuf_q <= wbuf[wb_raddr];
    end
    assign wq_dat = wbuf_q;
    // wq_fetch contract: address on the fetch edge, data two clocks later
    always @(posedge clk)
        if (wq_fetch) wb_raddr <= {w_flush_half, wq_idx};

    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc      <= 24'd0;
            cass_in  <= 1'b0;
            rq_req   <= 1'b0;
            rq_fsec  <= 13'd0;
            wq_req   <= 1'b0;
            wq_fsec  <= 13'd0;
            byte_pos <= 21'd0;
            half_sec[0] <= 13'h1FFF;
            half_sec[1] <= 13'h1FFF;
            half_ok  <= 2'b00;
            f_half   <= 1'b0;
            f_busy   <= 1'b0;
            f_sec    <= 13'd0;
            cur_byte <= 8'd0;
            bit_i    <= 3'd0;
            cell_us  <= 12'd0;
            pstate   <= P_LOAD;
            high_us  <= 8'd0;
            motor_d  <= 1'b0;
            pb_raddr <= 10'd0;
            out_d    <= 2'b10;
            wcell_us <= 12'd0;
            in_cell  <= 1'b0;
            wbit     <= 1'b0;
            wshift   <= 7'd0;
            wnbits   <= 3'd0;
            wpos     <= 10'd0;
            wsec     <= 13'd0;
            w_flush_half <= 1'b0;
            w_flush_busy <= 1'b0;
            w_full   <= 1'b0;
            w_pad    <= 10'd0;
            w_padding <= 1'b0;
            wb_we    <= 1'b0;
            wb_waddr <= 10'd0;
            wb_wdat  <= 8'd0;
        end else begin
            acc     <= acc_n[23:0];
            wb_we   <= 1'b0;
            motor_d <= motor;

            // ---------- play-side prefetch ----------
            if (fs_ready && cas_in_ok && !f_busy && !at_eof) begin
                // the half for the CURRENT sector first, then read-ahead
                if (!half_ok[play_sec[0]]
                    || half_sec[play_sec[0]] != {1'b0, play_sec}) begin
                    f_sec  <= {1'b0, play_sec};
                    f_half <= play_sec[0];
                    half_ok[play_sec[0]] <= 1'b0;
                    f_busy <= 1'b1;
                end else if ((half_sec[~play_sec[0]]
                              != {1'b0, play_sec} + 13'd1)
                             && ({1'b0, play_sec} + 13'd1 < file_secs)) begin
                    f_sec  <= {1'b0, play_sec} + 13'd1;
                    f_half <= ~play_sec[0];
                    half_ok[~play_sec[0]] <= 1'b0;
                    f_busy <= 1'b1;
                end
            end
            if (f_busy) begin
                rq_req  <= 1'b1;
                rq_fsec <= f_sec;
                if (rq_done) begin
                    half_sec[f_half] <= f_sec;
                    half_ok[f_half]  <= 1'b1;
                    rq_req <= 1'b0;
                    f_busy <= 1'b0;
                end else if (rq_err) begin
                    rq_req <= 1'b0;
                    f_busy <= 1'b0;   // retried on the next pass
                end
            end

            // ---------- play-side bit engine ----------
            if (en_1m) begin
                if (high_us != 8'd0)
                    high_us <= high_us - 8'd1;
                cass_in <= (high_us != 8'd0);

                if (motor && cas_in_ok && !at_eof) begin
                    case (pstate)
                        P_LOAD: begin
                            pb_raddr <= {play_sec[0], byte_pos[8:0]};
                            if (half_ok[play_sec[0]]
                                && half_sec[play_sec[0]]
                                   == {1'b0, play_sec})
                                pstate <= P_SETTLE;
                        end
                        P_SETTLE: begin
                            cur_byte <= pbuf_q;   // q valid next tick
                            pstate   <= P_RUN;
                        end
                        P_RUN: begin
                            if (cell_us == 12'd0) begin
                                high_us <= PULSE_US;          // clock pulse
                                cell_us <= 12'd1;
                            end else if (cell_us == 12'd1000) begin
                                if (play_bit_src[3'd7 - bit_i])
                                    high_us <= PULSE_US;      // data pulse
                                cell_us <= cell_us + 12'd1;
                            end else if (cell_us == 12'd1999) begin
                                cell_us <= 12'd0;
                                if (bit_i == 3'd7) begin
                                    bit_i    <= 3'd0;
                                    byte_pos <= byte_pos + 21'd1;
                                    pstate   <= P_LOAD;
                                end else
                                    bit_i <= bit_i + 3'd1;
                            end else
                                cell_us <= cell_us + 12'd1;
                        end
                        default: pstate <= P_LOAD;
                    endcase
                end
            end
            // Motor stop: the tape simply freezes — cell position,
            // bit index and byte all stay put, exactly like a real
            // deck pausing mid-pulse. Only a stop at end-of-tape
            // rewinds, so the next CLOAD starts at the leader.
            if (!motor && motor_d && at_eof) begin
                byte_pos <= 21'd0;
                bit_i    <= 3'd0;
                cell_us  <= 12'd0;
                pstate   <= P_LOAD;
            end

            // ---------- record side ----------
            if (en_1m && cas_out_ok && !w_full && !w_padding) begin
                out_d <= cass_out;

                if (in_cell && wcell_us != 12'd1500)
                    wcell_us <= wcell_us + 12'd1;

                if (motor && cass_out == 2'b11 && out_d != 2'b11) begin
                    if (!in_cell) begin
                        in_cell  <= 1'b1;    // the cell's clock pulse
                        wcell_us <= 12'd0;
                        wbit     <= 1'b0;
                    end else if (wcell_us < 12'd1500)
                        wbit <= 1'b1;        // data pulse -> '1'
                end

                if (in_cell && wcell_us == 12'd1500) begin
                    // window closed: commit the bit
                    in_cell <= 1'b0;
                    wshift  <= {wshift[5:0], wbit};
                    if (wnbits == 3'd7) begin
                        wnbits   <= 3'd0;
                        wb_we    <= 1'b1;
                        wb_waddr <= wpos;
                        wb_wdat  <= {wshift, wbit};
                        wpos     <= wpos + 10'd1;
                        if (wpos[8:0] == 9'd511)
                            w_flush_busy <= 1'b1;   // half full: write it
                    end else
                        wnbits <= wnbits + 3'd1;
                end
            end
            // motor stopped with a partial byte/sector: pad + flush
            if (!motor && motor_d && cas_out_ok && !w_full
                && (wnbits != 3'd0 || wpos[8:0] != 9'd0)) begin
                wnbits    <= 3'd0;
                in_cell   <= 1'b0;
                w_padding <= 1'b1;
                w_pad     <= wpos;
            end

            // zero-pad the open half up to its sector edge, then flush
            if (w_padding && !wb_we) begin
                if (w_pad[8:0] == 9'd0 && w_pad != wpos) begin
                    w_padding    <= 1'b0;
                    w_flush_busy <= 1'b1;
                    wpos         <= w_pad;
                end else begin
                    wb_we    <= 1'b1;
                    wb_waddr <= w_pad;
                    wb_wdat  <= 8'h00;
                    w_pad    <= w_pad + 10'd1;
                end
            end

            // write the filled half in place
            if (w_flush_busy) begin
                w_flush_half <= ~wpos[9];   // the half just completed
                wq_req  <= 1'b1;
                wq_fsec <= wsec;
                if (wq_done) begin
                    wq_req       <= 1'b0;
                    w_flush_busy <= 1'b0;
                    wsec         <= wsec + 13'd1;
                end else if (wq_err) begin
                    wq_req       <= 1'b0;
                    w_flush_busy <= 1'b0;
                    w_full       <= 1'b1;   // CASSOUT exhausted
                end
            end
        end
    end

    wire _unused_ok = &{1'b0, rq_idx, cas_len[31:21]};

endmodule
