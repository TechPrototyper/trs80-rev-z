// TRS-80 Rev Z — DMK track fetcher: m1_fdc trk_* port -> m1_sd_fs sectors
//
// Own work (MIT). The board-side media provider behind the FDC's track
// fetch port: translates "give me track T of drive D" into 512-byte
// sector reads of that drive's mounted DMK file (m1_sd_fs rq_* port) and
// streams exactly the raw track bytes (128-byte IDAM table included)
// back with trk_vld/trk_idx.
//
// After the filesystem reports fs_ready, the fetcher reads file sector 0
// of every mounted drive once and snaps the DMK header: track count
// (byte 1), track length LE (bytes 2-3, table included), and the flags
// byte (4) whose bits 6/7 decide whether single-density bytes are stored
// doubled (see rtl/m1_fdc.v for the format notes). A header with an
// implausible track length (< 130 or > 8192, the FDC buffer size) marks
// the drive unusable; requests for it — or for a track beyond the track
// count, or from an unmounted drive — answer with a clean trk_err pulse.
//
// Track T of a single-sided DMK lives at file bytes 16 + T*tracklen;
// double-sided images (header bit 4 clear) store two blocks per
// cylinder, so the block index is T*2 + side (the DS drive-select
// convention, latch bit 3 — see rtl/m1_drives.v). Side 1 of a
// single-sided image answers trk_err, like a drive without a second
// head. The fetcher walks the covering 512-byte file sectors and
// forwards the bytes that fall inside the window.

module m1_dmk_fetch (
    input  wire        clk,          // dot clock
    input  wire        rst_n,

    // filesystem side (m1_sd_fs)
    input  wire        fs_ready,
    input  wire [3:0]  drv_mounted,
    output reg         rq_req,
    output reg  [1:0]  rq_drv,
    output reg  [12:0] rq_fsec,
    input  wire        rq_vld,
    input  wire [7:0]  rq_dat,
    input  wire [8:0]  rq_idx,
    input  wire        rq_done,
    input  wire        rq_err,

    output reg         wq_req,
    output reg  [1:0]  wq_drv,
    output reg  [12:0] wq_fsec,
    input  wire        wq_fetch,
    input  wire [8:0]  wq_idx,
    output wire [7:0]  wq_dat,
    input  wire        wq_done,
    input  wire        wq_err,

    // FDC side (m1_core trk_* port)
    input  wire        trk_req,
    input  wire [1:0]  trk_drv,
    input  wire [6:0]  trk_track,
    input  wire        trk_side,
    output reg         trk_vld,
    output reg  [7:0]  trk_data,
    output reg  [12:0] trk_idx,
    output reg         trk_done,
    output reg         trk_err,
    output reg  [12:0] trk_len,
    output reg         trk_dbl,
    output wire [3:0]  drv_wp,      // DMK header WP bytes -> the drive bay

    // dirty-track write-back (pull): read-merge-write, because track
    // edges are not 512-aligned — the covering file sectors also hold
    // neighbour-track (or header) bytes that must survive
    input  wire        trk_wb_req,
    output reg         trk_wb_fetch,
    output reg  [12:0] trk_wb_idx,
    input  wire [7:0]  trk_wb_data,
    output reg         trk_wb_done,
    output reg         trk_wb_err
);

    // per-drive DMK header snapshot
    reg [3:0]  hok;
    reg [7:0]  h_ntrk [0:3];
    reg [12:0] h_tlen [0:3];
    reg [3:0]  h_dbl;
    reg [3:0]  h_ss;                 // header bit 4: single-sided
    reg [3:0]  h_wp;
    assign drv_wp = h_wp;

    // one file sector, staged for the read-merge-write
    reg [7:0]  sbuf [0:511];
    reg [7:0]  sb_q;
    reg [8:0]  sb_raddr;
    always @(posedge clk)
        sb_q <= sbuf[sb_raddr];
    assign wq_dat = sb_q;
    // wq_fetch contract: address on the fetch edge, data two clocks later
    always @(posedge clk)
        if (wq_fetch) sb_raddr <= wq_idx;

    // header parse scratch
    reg [1:0]  hd;
    reg [7:0]  s_ntrk;
    reg [15:0] s_tlen;
    reg [1:0]  s_flags;              // header bits 7:6
    reg        s_ss;                 // header bit 4 (single-sided)
    reg        s_wp;

    // write-back scratch
    reg [9:0]  mb;                   // merge byte cursor 0..511
    reg [1:0]  mset;                 // fetch-settle counter
    wire [20:0] g_mb = {rq_fsec[11:0], 9'd0} + {11'd0, mb};
    // byte range of the requested track (combinational, both serve
    // paths). DS images: two blocks per cylinder, block = T*2 + side.
    wire [8:0]  req_blk   = h_ss[trk_drv]
                            ? {2'd0, trk_track}
                            : ({1'd0, trk_track, 1'b0} + {8'd0, trk_side});
    wire        req_noside = trk_side && h_ss[trk_drv];
    wire [20:0] req_start = 21'd16
                            + {12'd0, req_blk} * {8'd0, h_tlen[trk_drv]};

    // serve scratch
    reg [20:0] t_start, t_end;       // byte range of the track in the file
    wire [20:0] g_off = {rq_fsec[11:0], 9'd0} + {12'd0, rq_idx};

    localparam [3:0]
        H_WAIT = 4'd0,
        H_REQ  = 4'd1,
        H_RD   = 4'd2,
        H_NEXT = 4'd3,
        S_IDLE = 4'd4,
        S_REQ  = 4'd5,
        S_RD   = 4'd6,
        W_RREQ = 4'd7,               // WB: read the covering file sector
        W_RD   = 4'd8,
        W_MRG  = 4'd9,               // WB: overlay the track window bytes
        W_MRG2 = 4'd10,
        W_WR   = 4'd11;              // WB: write the merged sector back

    reg [3:0] state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= H_WAIT;
            hok      <= 4'b0000;
            h_dbl    <= 4'b0000;
            h_ss     <= 4'b1111;
            hd       <= 2'd0;
            s_ntrk   <= 8'd0;
            s_tlen   <= 16'd0;
            s_flags  <= 2'd0;
            s_ss     <= 1'b1;
            s_wp     <= 1'b0;
            h_wp     <= 4'b0000;
            mb       <= 10'd0;
            mset     <= 2'd0;
            wq_req   <= 1'b0;
            wq_drv   <= 2'd0;
            wq_fsec  <= 13'd0;
            trk_wb_fetch <= 1'b0;
            trk_wb_idx   <= 13'd0;
            trk_wb_done  <= 1'b0;
            trk_wb_err   <= 1'b0;
            rq_req   <= 1'b0;
            rq_drv   <= 2'd0;
            rq_fsec  <= 13'd0;
            t_start  <= 21'd0;
            t_end    <= 21'd0;
            trk_vld  <= 1'b0;
            trk_data <= 8'd0;
            trk_idx  <= 13'd0;
            trk_done <= 1'b0;
            trk_err  <= 1'b0;
            trk_len  <= 13'd0;
            trk_dbl  <= 1'b0;
        end else begin
            rq_req   <= 1'b0;
            wq_req   <= 1'b0;
            trk_vld  <= 1'b0;
            trk_done <= 1'b0;
            trk_err  <= 1'b0;
            trk_wb_fetch <= 1'b0;
            trk_wb_done  <= 1'b0;
            trk_wb_err   <= 1'b0;

            case (state)
                // ---- snap the DMK headers once the mounts are up ----
                H_WAIT: if (fs_ready) begin
                    hd    <= 2'd0;
                    state <= H_REQ;
                end
                H_REQ: begin
                    if (drv_mounted[hd]) begin
                        rq_drv  <= hd;
                        rq_fsec <= 13'd0;
                        rq_req  <= 1'b1;
                        state   <= H_RD;
                    end else
                        state <= H_NEXT;
                end
                H_RD: begin
                    if (rq_vld) begin
                        case (rq_idx)
                            9'd0: s_wp          <= (rq_dat == 8'hFF);
                            9'd1: s_ntrk        <= rq_dat;
                            9'd2: s_tlen[7:0]   <= rq_dat;
                            9'd3: s_tlen[15:8]  <= rq_dat;
                            9'd4: begin
                                      s_flags <= rq_dat[7:6];
                                      s_ss    <= rq_dat[4];
                                  end
                            default: ;
                        endcase
                    end
                    if (rq_done) begin
                        if (s_tlen >= 16'd130 && s_tlen <= 16'd8192) begin
                            hok[hd]    <= 1'b1;
                            h_ntrk[hd] <= s_ntrk;
                            h_tlen[hd] <= s_tlen[12:0];
                            h_dbl[hd]  <= (s_flags == 2'b00);
                            h_ss[hd]   <= s_ss;
                            h_wp[hd]   <= s_wp;
                        end
                        state <= H_NEXT;
                    end
                    if (rq_err)
                        state <= H_NEXT;     // drive stays unusable
                end
                H_NEXT: begin
                    if (hd == 2'd3)
                        state <= S_IDLE;
                    else begin
                        hd    <= hd + 2'd1;
                        state <= H_REQ;
                    end
                end

                // ---- serve track requests ----
                S_IDLE: if (trk_wb_req) begin
                    if (!hok[trk_drv] || req_noside
                        || {1'b0, trk_track} >= h_ntrk[trk_drv][7:0])
                        trk_wb_err <= 1'b1;
                    else begin
                        t_start <= req_start;
                        t_end   <= req_start + {8'd0, h_tlen[trk_drv]};
                        rq_drv  <= trk_drv;
                        wq_drv  <= trk_drv;
                        rq_fsec <= {1'd0, req_start[20:9]};
                        state   <= W_RREQ;
                    end
                end else if (trk_req) begin
                    if (!hok[trk_drv] || req_noside
                        || {1'b0, trk_track} >= h_ntrk[trk_drv][7:0])
                        trk_err <= 1'b1;
                    else begin
                        trk_len <= h_tlen[trk_drv];
                        trk_dbl <= h_dbl[trk_drv];
                        t_start <= req_start;
                        t_end   <= req_start + {8'd0, h_tlen[trk_drv]};
                        rq_drv  <= trk_drv;
                        state   <= S_REQ;
                    end
                end
                S_REQ: begin
                    rq_fsec <= {1'd0, t_start[20:9]};    // first covering
                    rq_req  <= 1'b1;                     // file sector
                    state   <= S_RD;
                end
                S_RD: begin
                    if (rq_vld && g_off >= t_start && g_off < t_end) begin
                        trk_vld  <= 1'b1;
                        trk_data <= rq_dat;
                        trk_idx  <= g_off[12:0] - t_start[12:0];
                    end
                    if (rq_done) begin
                        // done when the NEXT file sector starts at or
                        // past the end of the track window
                        if ({{rq_fsec[11:0] + 12'd1}, 9'd0} >= t_end) begin
                            trk_done <= 1'b1;
                            state    <= S_IDLE;
                        end else begin
                            rq_fsec <= rq_fsec + 13'd1;
                            rq_req  <= 1'b1;
                        end
                    end
                    if (rq_err) begin
                        trk_err <= 1'b1;
                        state   <= S_IDLE;
                    end
                end

                // ---- dirty-track write-back: read, merge, write ------
                W_RREQ: begin
                    // first pass targets the first covering file sector;
                    // later passes arrive here with rq_fsec advanced
                    rq_req <= 1'b1;
                    state  <= W_RD;
                end
                W_RD: begin
                    if (rq_vld)
                        sbuf[rq_idx] <= rq_dat;
                    if (rq_done) begin
                        mb    <= 10'd0;
                        state <= W_MRG;
                    end
                    if (rq_err) begin
                        trk_wb_err <= 1'b1;
                        state      <= S_IDLE;
                    end
                end
                W_MRG: begin
                    if (mb == 10'd512) begin
                        wq_fsec <= rq_fsec;
                        wq_req  <= 1'b1;
                        state   <= W_WR;
                    end else if (g_mb >= t_start && g_mb < t_end) begin
                        trk_wb_fetch <= 1'b1;
                        trk_wb_idx   <= g_mb[12:0] - t_start[12:0];
                        mset         <= 2'd0;
                        state        <= W_MRG2;
                    end else
                        mb <= mb + 10'd1;    // neighbour byte: keep it
                end
                W_MRG2: begin
                    // the FDC's registered buffer answers two clocks
                    // after the fetch edge
                    mset <= mset + 2'd1;
                    if (mset == 2'd2) begin
                        sbuf[mb[8:0]] <= trk_wb_data;
                        mb    <= mb + 10'd1;
                        state <= W_MRG;
                    end
                end
                W_WR: begin
                    // wq_fetch/wq_dat run through the staged sector above
                    if (wq_done) begin
                        if ({{rq_fsec[11:0] + 12'd1}, 9'd0} >= t_end) begin
                            trk_wb_done <= 1'b1;
                            state       <= S_IDLE;
                        end else begin
                            rq_fsec <= rq_fsec + 13'd1;
                            state   <= W_RREQ;
                        end
                    end
                    if (wq_err) begin
                        trk_wb_err <= 1'b1;
                        state      <= S_IDLE;
                    end
                end

                default: state <= H_WAIT;
            endcase
        end
    end

endmodule
