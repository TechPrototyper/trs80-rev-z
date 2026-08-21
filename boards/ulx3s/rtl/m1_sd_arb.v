// TRS-80 Rev Z — SD sector-server arbiter: two clients, one m1_sd_fs
//
// Own work (MIT). Client 0 is the DMK track fetcher (slots 0-3, 2-bit
// drive), client 1 the cassette deck (fixed slots: reads from 4,
// writes to 5). Requests are single pulses answered by done/err, so
// ownership is simply "first pulse wins, held until the reply"; the
// FDC path has priority when both arrive on the same clock. The
// cassette needs a sector only every few seconds (500 baud = 62
// bytes/s), so waiting behind a track fetch is invisible to it.
//
// Contract difference: client 0 pulses (m1_dmk_fetch idiom); client 1
// HOLDS its request high until it sees done/err — that way a c1
// request that loses the same-clock race is simply granted next time
// around instead of being lost. The rearm flags stop a held line from
// re-triggering while the client reacts to its completion strobe.

module m1_sd_arb (
    input  wire        clk,
    input  wire        rst_n,

    // ---- filesystem side (m1_sd_fs) ----
    output reg         rq_req,
    output reg  [2:0]  rq_drv,
    output reg  [12:0] rq_fsec,
    input  wire        rq_vld,
    input  wire [7:0]  rq_dat,
    input  wire [8:0]  rq_idx,
    input  wire        rq_done,
    input  wire        rq_err,
    output reg         wq_req,
    output reg  [2:0]  wq_drv,
    output reg  [12:0] wq_fsec,
    input  wire        wq_fetch,
    input  wire [8:0]  wq_idx,
    output wire [7:0]  wq_dat,
    input  wire        wq_done,
    input  wire        wq_err,

    // ---- client 0: DMK fetcher (slots 0-3) ----
    input  wire        c0_rq_req,
    input  wire [1:0]  c0_rq_drv,
    input  wire [12:0] c0_rq_fsec,
    output wire        c0_rq_vld,
    output wire [7:0]  c0_rq_dat,
    output wire [8:0]  c0_rq_idx,
    output wire        c0_rq_done,
    output wire        c0_rq_err,
    input  wire        c0_wq_req,
    input  wire [1:0]  c0_wq_drv,
    input  wire [12:0] c0_wq_fsec,
    output wire        c0_wq_fetch,
    output wire [8:0]  c0_wq_idx,
    input  wire [7:0]  c0_wq_dat,
    output wire        c0_wq_done,
    output wire        c0_wq_err,

    // ---- client 1: cassette deck (read slot 4, write slot 5) ----
    input  wire        c1_rq_req,
    input  wire [12:0] c1_rq_fsec,
    output wire        c1_rq_vld,
    output wire [7:0]  c1_rq_dat,
    output wire [8:0]  c1_rq_idx,
    output wire        c1_rq_done,
    output wire        c1_rq_err,
    input  wire        c1_wq_req,
    input  wire [12:0] c1_wq_fsec,
    output wire        c1_wq_fetch,
    output wire [8:0]  c1_wq_idx,
    input  wire [7:0]  c1_wq_dat,
    output wire        c1_wq_done,
    output wire        c1_wq_err
);

    // one owner per direction (read and write never overlap inside
    // m1_sd_fs — it serves one request at a time — but tracking them
    // separately keeps the routing trivially correct)
    reg r_busy, r_own;               // read in flight, owner (0/1)
    reg w_busy, w_own;
    reg r_rearm1, w_rearm1;          // c1 must release before re-granting

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_busy <= 1'b0; r_own <= 1'b0;
            w_busy <= 1'b0; w_own <= 1'b0;
            r_rearm1 <= 1'b0; w_rearm1 <= 1'b0;
            rq_req <= 1'b0; rq_drv <= 3'd0; rq_fsec <= 13'd0;
            wq_req <= 1'b0; wq_drv <= 3'd0; wq_fsec <= 13'd0;
        end else begin
            rq_req <= 1'b0;
            wq_req <= 1'b0;

            if (r_rearm1 && !c1_rq_req)
                r_rearm1 <= 1'b0;
            if (w_rearm1 && !c1_wq_req)
                w_rearm1 <= 1'b0;

            if (!r_busy) begin
                if (c0_rq_req) begin
                    rq_drv  <= {1'b0, c0_rq_drv};
                    rq_fsec <= c0_rq_fsec;
                    rq_req  <= 1'b1;
                    r_own   <= 1'b0;
                    r_busy  <= 1'b1;
                end else if (c1_rq_req && !r_rearm1) begin
                    rq_drv  <= 3'd4;
                    rq_fsec <= c1_rq_fsec;
                    rq_req  <= 1'b1;
                    r_own   <= 1'b1;
                    r_busy  <= 1'b1;
                end
            end else if (rq_done || rq_err) begin
                r_busy <= 1'b0;
                if (r_own) r_rearm1 <= 1'b1;
            end

            if (!w_busy) begin
                if (c0_wq_req) begin
                    wq_drv  <= {1'b0, c0_wq_drv};
                    wq_fsec <= c0_wq_fsec;
                    wq_req  <= 1'b1;
                    w_own   <= 1'b0;
                    w_busy  <= 1'b1;
                end else if (c1_wq_req && !w_rearm1) begin
                    wq_drv  <= 3'd5;
                    wq_fsec <= c1_wq_fsec;
                    wq_req  <= 1'b1;
                    w_own   <= 1'b1;
                    w_busy  <= 1'b1;
                end
            end else if (wq_done || wq_err) begin
                w_busy <= 1'b0;
                if (w_own) w_rearm1 <= 1'b1;
            end
        end
    end

    // response routing (data fans out; strobes gate by owner)
    assign c0_rq_vld  = rq_vld  && r_busy && !r_own;
    assign c1_rq_vld  = rq_vld  && r_busy &&  r_own;
    assign c0_rq_dat  = rq_dat;
    assign c1_rq_dat  = rq_dat;
    assign c0_rq_idx  = rq_idx;
    assign c1_rq_idx  = rq_idx;
    assign c0_rq_done = rq_done && r_busy && !r_own;
    assign c1_rq_done = rq_done && r_busy &&  r_own;
    assign c0_rq_err  = rq_err  && r_busy && !r_own;
    assign c1_rq_err  = rq_err  && r_busy &&  r_own;

    assign c0_wq_fetch = wq_fetch && w_busy && !w_own;
    assign c1_wq_fetch = wq_fetch && w_busy &&  w_own;
    assign c0_wq_idx   = wq_idx;
    assign c1_wq_idx   = wq_idx;
    assign wq_dat      = w_own ? c1_wq_dat : c0_wq_dat;
    assign c0_wq_done  = wq_done && w_busy && !w_own;
    assign c1_wq_done  = wq_done && w_busy &&  w_own;
    assign c0_wq_err   = wq_err  && w_busy && !w_own;
    assign c1_wq_err   = wq_err  && w_busy &&  w_own;

endmodule
