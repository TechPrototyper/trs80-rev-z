// TRS-80 Rev Z — WD FD1771B-01 floppy disk controller (EI stages 2+3)
//
// The FDC chip itself, as it sits on the Expansion Interface (registers
// 37EC-37EF behind the Z33/Z37/Z38 buffers; the address sub-decode is the
// container's job). Implemented: the Type I command set (Restore, Seek,
// Step variants) with real stepping rates from the 1 MHz enable, Force
// Interrupt, and — stage 3 — Type II Read Sector and Type III Read
// Address served from an in-FPGA track buffer; stage 5 adds Type II
// Write Sector — in place over the existing DAM/data/CRC of the
// formatted track, with a fresh CCITT CRC — plus the dirty-buffer
// write-back through the trk_wb_* pull port (flushed before a different
// track is fetched, and when the drive drops ready while idle). Type
// III Write Track (format) is the remaining gap and completes with
// INTRQ so nothing hangs on it.
//
// Track buffer: one raw DMK track (128-byte IDAM pointer table + track
// bytes) in an 8 KiB BRAM — double-density sized from day one (ADR-0005:
// the Percom stage only adds a personality, not a rebuild). The buffer
// is (re)filled through the trk_* fetch port whenever the (drive, head
// position) it holds is not the one a command needs; the media provider
// behind that port is the board's DMK fetcher (SD card) or a bench model.
//
// DMK parsing facts (probed against trs80gp 2.5.5, 2026-07-24 — see
// sim/tools/build_dmk.py for the full format notes):
//   - IDAM pointers: 64 x 16-bit LE at track offsets 0..127; the value
//     (bits 13:0) is the offset of the 0xFE ID mark from the START of
//     the track, table included; 0 ends the list; bit 15 = IDAM is
//     double density
//   - trk_dbl = the image stores single-density bytes DOUBLED (wild
//     0x1900-track images); our generated 0x0CC0 images store them once
//   - ID field: FE track side sector length crc crc; the DAM (F8..FB)
//     follows within ~30 gap bytes; data length = 128 << length[1:0]
//
// Contract pinned against trs80gp 2.5.5 (probes, 2026-07-24):
//   - reset: command/track/sector/data all 0x00 (sector is NOT 1)
//   - Type I status: {~ready, wprt, hld(0), seek_err, crc(0), tr00,
//     index, busy}; Type II/III status: {~ready, wprt|rt1, rt0, rnf,
//     crc(0), lost, drq, busy} — the mux follows the last command class;
//     a forced interrupt (0xDx) issued while idle reverts it to Type I
//     (NEWDOS/80's driver D0s after each read, then polls S1 for index
//     pulses as a drive-alive check — z88a lookup divergence, 2026-08-21).
//     rt1:rt0 is the read record type: 1771/FM = ~DAM[1:0] (FB=00 FA=01
//     F9=10 F8=11 — TRS-80 DOS directories use FA/F8 and check this),
//     1791/MFM = deleted flag in rt0 only (fdcdamtest probe, 2026-08-20)
//   - INTRQ raises at command completion, cleared by reading the status
//     register or writing a new command (37E0 clears only the RTC half)
//   - DRQ paces one byte per 64 us (FM, 125 kbit/s); an unserviced DRQ
//     sets lost data, the transfer continues (spec behaviour)
//   - record-not-found raises after five index pulses without a match
//
// Register writes latch on the trailing edge of the write strobe (the
// data bus is stable across the whole cycle); status/data reads act on
// their trailing edges the same way.

module m1_fdc #(
    parameter [14:0] RATE0_US = 15'd6000,
    parameter [14:0] RATE1_US = 15'd6000,
    parameter [14:0] RATE2_US = 15'd10000,
    parameter [14:0] RATE3_US = 15'd20000,
    parameter [6:0]  BYTE_US  = 7'd64,       // FM data rate: 1 byte/64 us
    // Gap II rotates under the head between the ID field and the DAM
    // (FM: ~17 bytes of FF/00 = ~1.1 ms). The IDAM scan above is
    // instantaneous, so without this floor the first data byte would
    // arrive ~64 us after the command — real drivers (NEWDOS/80) have an
    // interruptible setup window wider than that between issuing the
    // read and their DI, and a long 40 Hz ISR landing in it would eat
    // DRQs that a real 177x could never have raised yet (aj6 boot,
    // 2026-08-21).
    parameter [14:0] GAP2_US  = 15'd1100,
    // MFM: true 32 us/byte. tv80 is datasheet-exact in T-states
    // (tb_z80_tstates), so 56.7 T per MFM byte is servicable exactly as
    // on real hardware: it takes the doubler-era unrolled driver loops,
    // and the byte tick defers while a data-register strobe is in
    // flight (dreg_busy, <1 us) so a tick can never land INSIDE the
    // CPU's access. A 30%-slower-tv80 measurement that once argued for
    // 52 us here was wrong and is withdrawn (2026-07-25).
    parameter [6:0]  BYTE_US_DD = 7'd32
) (
    input  wire        clk,          // dot clock
    input  wire        rst_n,
    input  wire        en_1m,        // 1 MHz enable (the EI's clock chain)
    input  wire        percom_en,    // Percom Doubler fitted (stage 6)

    // bus (sub-decoded window 37EC-37EF)
    input  wire        sel,          // address is inside the window
    input  wire [1:0]  a,            // 0 cmd/status, 1 track, 2 sector, 3 data
    input  wire [7:0]  din,
    input  wire        rd_n,
    input  wire        wr_n,
    output wire [7:0]  dout,
    output wire        dout_en,

    output reg         intrq,

    // drive interface (Shugart side, J5)
    output reg         step,         // one-clk pulse
    output reg         dirc,         // 1 = step in (toward higher tracks)
    input  wire        tr00,         // selected drive at track 0
    input  wire        ip,           // index pulse
    input  wire        wprt,         // write protected
    input  wire        ready,
    input  wire [1:0]  sel_drv,      // selected drive index (drive bay)
    input  wire [6:0]  pos_sel,      // its head position

    // track fetch port (media provider: DMK fetcher / bench model)
    output reg         trk_req,      // pulse: fetch (trk_drv, trk_track)
    output reg  [1:0]  trk_drv,
    output reg  [6:0]  trk_track,
    input  wire        trk_vld,      // one byte of the raw track
    input  wire [7:0]  trk_data,
    input  wire [12:0] trk_idx,
    input  wire        trk_done,
    input  wire        trk_err,
    input  wire [12:0] trk_len,      // track length incl. the 128-byte table
    input  wire        trk_dbl,      // SD bytes stored doubled

    // dirty-track write-back (stage 5): the media provider PULLS the
    // buffer with trk_wb_fetch/trk_wb_idx; trk_wb_data answers two
    // clocks later. Raised for (trk_drv, trk_track) like a fetch.
    output reg         trk_wb_req,
    input  wire        trk_wb_fetch,
    input  wire [12:0] trk_wb_idx,
    output wire [7:0]  trk_wb_data,
    input  wire        trk_wb_done,
    input  wire        trk_wb_err
);

    // ------------------------------------------------------------------
    // Registers
    // ------------------------------------------------------------------
    reg [7:0] track, sector, data;
    reg       busy, seek_err;
    reg       drq, lost, rnf;
    reg [1:0] rec_type;              // Type II read: S6:S5 record type —
                                     // 1771: ~DAM[1:0] (FB=00 FA=01 F9=10
                                     // F8=11), 1791: S5 only (deleted DAM);
                                     // probed against trs80gp (fdcdamtest)
    reg       t2ctx;                 // status mux: last command Type II/III

    wire [7:0] status_t1 = {~ready, wprt, 1'b0, seek_err, 1'b0, tr00, ip, busy};
    wire [7:0] status_t2 = {~ready, s_wprt | rec_type[1], rec_type[0], rnf,
                            1'b0, lost, drq, busy};
    wire [7:0] status    = t2ctx ? status_t2 : status_t1;

    wire rd_stat = sel && (a == 2'd0) && !rd_n;
    wire rd_data = sel && (a == 2'd3) && !rd_n;
    wire wr_data_act = sel && (a == 2'd3) && !wr_n;
    // a data-register access IN FLIGHT counts as service: the byte tick
    // defers until the strobe ends (<1 us elasticity), otherwise a tick
    // landing inside the CPU's read/write strobe falsely sees DRQ still
    // set and flags lost data — found as a deterministic 13-byte beat
    // at the true 32 us MFM cadence (2026-07-25)
    wire dreg_busy = rd_data || wr_data_act;
    wire wr_here = sel && !wr_n;
    reg        wr_d;
    reg  [1:0] wa_d;
    reg  [7:0] wd_d;
    reg        rd_stat_d, rd_data_d;

    // ------------------------------------------------------------------
    // Track buffer (8 KiB BRAM) + registered read port
    // ------------------------------------------------------------------
    reg [7:0]  tbuf [0:8191];
    reg [7:0]  tb_q;
    reg [12:0] tb_addr;
    reg        tbw_en;
    reg [12:0] tbw_addr;
    reg [7:0]  tbw_data;
    always @(posedge clk) begin
        if (trk_vld)
            tbuf[trk_idx] <= trk_data;
        else if (tbw_en)
            tbuf[tbw_addr] <= tbw_data;
        tb_q <= tbuf[tb_addr];
    end
    assign trk_wb_data = tb_q;      // write-back pull: addr set on fetch,
                                    // valid two clocks later (registered)

    reg        tbv;                  // buffer holds (tb_drv, tb_trk)
    reg [1:0]  tb_drv;
    reg [6:0]  tb_trk;
    reg [12:0] tb_len;
    reg        tb_dbl;

    // ------------------------------------------------------------------
    // Type I engine
    // ------------------------------------------------------------------
    localparam [2:0] F_IDLE = 3'd0, F_START = 3'd1, F_STEP = 3'd2,
                     F_WAIT = 3'd3, F_DONE = 3'd4;
    localparam [2:0] OP_RESTORE = 3'd0, OP_SEEK = 3'd1, OP_STEP = 3'd2;

    reg [2:0]  fstate;
    reg [2:0]  op;
    reg        upd;                 // step commands: update the track reg
    reg [14:0] rate_us, us_cnt;
    reg [8:0]  guard;               // restore: at most 255 steps to TR00

    // ------------------------------------------------------------------
    // Type II/III engine (read sector / read address)
    // ------------------------------------------------------------------
    localparam [4:0]
        R_IDLE   = 5'd0,
        R_SETUP  = 5'd1,            // buffer check -> flush/fetch/scan
        R_FETCH  = 5'd2,            // stream into the track buffer
        R_PTR_L  = 5'd3,            // pointer table entry, low byte
        R_PTR_H  = 5'd4,
        R_ID     = 5'd5,            // walk the ID field
        R_DAM    = 5'd6,            // hunt the data address mark
        R_TICK   = 5'd7,            // wait for the next byte time
        R_BYTE   = 5'd8,            // present one byte via DRQ
        R_NFWAIT = 5'd9,            // count index pulses toward RNF
        R_LAST   = 5'd10,           // CRC passes under the head: the CPU
                                    // gets two byte times for the final byte
        R_DONE   = 5'd11,
        W_TICK   = 5'd12,           // write path: wait the byte time
        W_BYTE   = 5'd13,           // write one byte (DAM/data/CRC)
        W_BYTE2  = 5'd14,           // second copy (doubled-SD images)
        R_FLUSH  = 5'd15,           // media provider pulls the dirty buffer
        T_WTWAIT = 5'd16,           // write track: wait the index edge
        T_WTTICK = 5'd17,           // write track: byte cadence
        T_WTBYTE = 5'd18,           // write track: classify + store
        T_WTB2   = 5'd19,           // second copy / second CRC byte
        T_WTFIN  = 5'd20,           // rebuild the IDAM pointer table
        R_GAP    = 5'd21;           // gap II passes the head before the data

    reg [4:0]  rstate;
    reg        is_ra;               // Read Address (else Read Sector)
    reg        is_wr;               // Write Sector
    reg        is_rt;               // Read Track (raw)
    reg        is_wt;               // Write Track (format)
    reg        dden;                // Percom latch: 1 = 1791/MFM/DD
    reg        s_wprt;              // write refused: status bit 6
    reg [12:0] idam_list [0:63];    // write track: recorded FE positions
    reg [5:0]  wt_n;                // ... and how many
    reg [6:0]  fin_i;               // table-rebuild cursor (2 phases/entry)
    reg        wt_crc2;             // pending second CRC byte (F7)
    reg [7:0]  wt_v;                // byte being emitted (doubled copy)
    reg        tb_dirty;            // buffer differs from the media
    reg        flush_idle;          // flush without a pending command
    reg        ready_d;
    reg [1:0]  dam_sel;             // Type II a1a0: DAM = 0xFB - dam_sel
    reg [15:0] crc;
    reg [1:0]  wphase;              // 0 DAM, 1 data, 2 crc hi, 3 crc lo
    reg [7:0]  wval;
    reg [5:0]  entry;               // IDAM table index
    reg [5:0]  ra_cur;              // Read Address rotational cursor
    reg [12:0] ptr;                 // current IDAM offset
    reg        e_dd;                // entry is double density
    reg [2:0]  id_i;                // ID walk index
    reg [7:0]  id_tk;
    reg [1:0]  id_ln;
    reg [12:0] rd_pos;              // buffer read cursor
    reg [12:0] rd_n_left;           // bytes left in the transfer
    reg [5:0]  dam_hunt;            // DAM search window
    reg [7:0]  us_byte;             // byte-cadence counter
    reg [2:0]  ip_cnt;              // index pulses toward RNF
    reg        ip_d;
    reg        rd_pend;             // registered-read settle flag

    // effective per-entry byte step: doubled SD bytes vs single/DD
    wire [1:0]  estep  = (tb_dbl && !e_dd) ? 2'd2 : 2'd1;
    // FM is one byte per 64 us, MFM one per 32 us — per the density of
    // the sector/track in flight
    wire [7:0]  byte_us_w = e_dd ? {1'b0, BYTE_US_DD} : {1'b0, BYTE_US};
    // write track: the byte this cell emits (control bytes translated)
    wire [7:0]  wt_next = wt_crc2            ? crc[7:0]
                        : drq                ? 8'h00
                        : (data == 8'hF7)    ? crc[15:8]
                        : (e_dd && data == 8'hF5) ? 8'hA1
                        : (e_dd && data == 8'hF6) ? 8'hC2
                        :                      data;
    wire [12:0] step_w = {11'd0, estep};
    wire [5:0]  entry_n = entry + 6'd1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            track    <= 8'd0;
            sector   <= 8'd0;
            data     <= 8'd0;
            busy     <= 1'b0;
            seek_err <= 1'b0;
            drq      <= 1'b0;
            lost     <= 1'b0;
            rnf      <= 1'b0;
            rec_type <= 2'd0;
            t2ctx    <= 1'b0;
            intrq    <= 1'b0;
            step     <= 1'b0;
            dirc     <= 1'b0;
            wr_d     <= 1'b0;
            wa_d     <= 2'd0;
            wd_d     <= 8'd0;
            rd_stat_d <= 1'b0;
            rd_data_d <= 1'b0;
            fstate   <= F_IDLE;
            op       <= OP_RESTORE;
            upd      <= 1'b0;
            rate_us  <= 15'd0;
            us_cnt   <= 15'd0;
            guard    <= 9'd0;
            rstate   <= R_IDLE;
            is_ra    <= 1'b0;
            entry    <= 6'd0;
            ra_cur   <= 6'd0;
            ptr      <= 13'd0;
            e_dd     <= 1'b0;
            id_i     <= 3'd0;
            id_tk    <= 8'd0;
            id_ln    <= 2'd0;
            rd_pos   <= 13'd0;
            rd_n_left <= 13'd0;
            dam_hunt <= 6'd0;
            us_byte  <= 8'd0;
            ip_cnt   <= 3'd0;
            ip_d     <= 1'b0;
            rd_pend  <= 1'b0;
            is_wr    <= 1'b0;
            is_rt    <= 1'b0;
            is_wt    <= 1'b0;
            dden     <= 1'b0;
            wt_n     <= 6'd0;
            fin_i    <= 7'd0;
            wt_crc2  <= 1'b0;
            wt_v     <= 8'd0;
            s_wprt   <= 1'b0;
            tb_dirty <= 1'b0;
            flush_idle <= 1'b0;
            ready_d  <= 1'b0;
            dam_sel  <= 2'd0;
            crc      <= 16'd0;
            wphase   <= 2'd0;
            wval     <= 8'd0;
            tbw_en   <= 1'b0;
            tbw_addr <= 13'd0;
            tbw_data <= 8'd0;
            trk_wb_req <= 1'b0;
            tb_addr  <= 13'd0;
            tbv      <= 1'b0;
            tb_drv   <= 2'd0;
            tb_trk   <= 7'd0;
            tb_len   <= 13'd0;
            tb_dbl   <= 1'b0;
            trk_req  <= 1'b0;
            trk_drv  <= 2'd0;
            trk_track <= 7'd0;
        end else begin
            step    <= 1'b0;
            trk_req <= 1'b0;
            trk_wb_req <= 1'b0;
            tbw_en  <= 1'b0;
            ip_d    <= ip;
            ready_d <= ready;

            // idle flush: the drive was deselected / the motor timed out
            // while the buffer holds unwritten data
            if (rstate == R_IDLE && tb_dirty && ready_d && !ready) begin
                trk_drv    <= tb_drv;
                trk_track  <= tb_trk;
                trk_wb_req <= 1'b1;
                flush_idle <= 1'b1;
                rstate     <= R_FLUSH;
            end

            // INTRQ clear: trailing edge of a status read
            rd_stat_d <= rd_stat;
            if (rd_stat_d && !rd_stat)
                intrq <= 1'b0;
            // DRQ clear: trailing edge of a data read
            rd_data_d <= rd_data;
            if (rd_data_d && !rd_data)
                drq <= 1'b0;

            // latch writes, act on the trailing edge of the strobe
            wr_d <= wr_here;
            if (wr_here) begin
                wa_d <= a;
                wd_d <= din;
            end
            if (wr_d && !wr_here) begin
                case (wa_d)
                    2'd0: begin                          // command
                        intrq <= 1'b0;
                        if (wd_d == 8'hFE || wd_d == 8'hFF) begin
                            // Percom Doubler density latch (0xFF = DD);
                            // NO busy/INTRQ/status side effects — probed
                            // against trs80gp -ddp/-ddx 2026-07-25
                            if (percom_en)
                                dden <= wd_d[0];
                        end else if (wd_d[7:4] == 4'hD) begin // force intr
                            busy   <= 1'b0;
                            fstate <= F_IDLE;
                            if (rstate != R_FLUSH)       // a flush is media
                                rstate <= R_IDLE;        // work, not a cmd
                            drq    <= 1'b0;
                            // 177x: forced interrupt with no command
                            // running reverts the status mux to Type I
                            // (NEWDOS/80 D0s after every read, then polls
                            // S1 for index pulses); mid-command the other
                            // status bits are left as-is
                            if (!busy) t2ctx <= 1'b0;
                            if (wd_d[3]) intrq <= 1'b1;  // immediate-INT flag
                        end else if (!busy) begin
                            if (!wd_d[7]) begin          // Type I
                                t2ctx    <= 1'b0;
                                busy     <= 1'b1;
                                seek_err <= 1'b0;
                                upd      <= 1'b0;
                                guard    <= 9'd255;
                                case (wd_d[6:4])
                                    3'b000: op <= OP_RESTORE;   // 0x0X
                                    3'b001: op <= OP_SEEK;      // 0x1X
                                    default: begin              // 0x2X-0x7X
                                        op  <= OP_STEP;
                                        upd <= wd_d[4];
                                        if (wd_d[6:5] == 2'b10) dirc <= 1'b1;
                                        if (wd_d[6:5] == 2'b11) dirc <= 1'b0;
                                    end
                                endcase
                                case (wd_d[1:0])
                                    2'd0: rate_us <= RATE0_US;
                                    2'd1: rate_us <= RATE1_US;
                                    2'd2: rate_us <= RATE2_US;
                                    2'd3: rate_us <= RATE3_US;
                                endcase
                                fstate <= F_START;
                            end else if (rstate == R_IDLE) begin
                                // Type II Read (100x) / Write (101x)
                                // Sector, Type III Read Address (1100),
                                // Read Track (1110), Write Track (1111)
                                t2ctx    <= 1'b1;
                                drq      <= 1'b0;
                                lost     <= 1'b0;
                                rnf      <= 1'b0;
                                rec_type <= 2'd0;
                                s_wprt   <= 1'b0;
                                is_ra    <= (wd_d[7:4] == 4'hC);
                                is_rt    <= (wd_d[7:4] == 4'hE);
                                is_wt    <= (wd_d[7:2] == 6'b111101);
                                is_wr    <= (wd_d[7:5] == 3'b101);
                                dam_sel  <= wd_d[1:0];
                                if (!ready) begin
                                    intrq <= 1'b1;       // not ready: refuse
                                end else if (wprt
                                             && (wd_d[7:5] == 3'b101
                                                 || wd_d[7:2] == 6'b111101))
                                begin
                                    s_wprt <= 1'b1;      // protected: refuse
                                    intrq  <= 1'b1;
                                end else begin
                                    busy   <= 1'b1;
                                    ip_cnt <= 3'd0;
                                    if (wd_d[7:5] == 3'b101
                                        || wd_d[7:2] == 6'b111101)
                                        drq <= 1'b1;     // preload byte 0
                                    rstate <= R_SETUP;
                                end
                            end
                        end
                    end
                    2'd1: track  <= wd_d;
                    2'd2: sector <= wd_d;
                    2'd3: begin
                        data <= wd_d;
                        drq  <= 1'b0;        // any data access clears DRQ
                    end
                endcase
            end

            // ---- Type I engine ----------------------------------------
            case (fstate)
                F_IDLE: ;

                F_START: begin
                    case (op)
                        OP_RESTORE:
                            if (tr00) begin
                                track  <= 8'd0;
                                fstate <= F_DONE;
                            end else begin
                                dirc   <= 1'b0;
                                fstate <= F_STEP;
                            end
                        OP_SEEK:
                            if (track == data)
                                fstate <= F_DONE;
                            else begin
                                dirc   <= (data > track);
                                fstate <= F_STEP;
                            end
                        default:
                            fstate <= F_STEP;
                    endcase
                end

                F_STEP: begin
                    step <= 1'b1;
                    if (op == OP_SEEK || (op == OP_STEP && upd))
                        track <= dirc ? track + 8'd1 : track - 8'd1;
                    us_cnt <= rate_us;
                    fstate <= F_WAIT;
                end

                F_WAIT:
                    if (en_1m) begin
                        if (us_cnt <= 15'd1) begin
                            case (op)
                                OP_RESTORE:
                                    if (tr00) begin
                                        track  <= 8'd0;
                                        fstate <= F_DONE;
                                    end else if (guard == 9'd0) begin
                                        seek_err <= 1'b1;
                                        fstate   <= F_DONE;
                                    end else begin
                                        guard  <= guard - 9'd1;
                                        fstate <= F_STEP;
                                    end
                                OP_SEEK:
                                    fstate <= F_START;   // re-compare
                                default:
                                    fstate <= F_DONE;    // single step
                            endcase
                        end else
                            us_cnt <= us_cnt - 15'd1;
                    end

                F_DONE: begin
                    busy   <= 1'b0;
                    intrq  <= 1'b1;
                    fstate <= F_IDLE;
                end

                default: fstate <= F_IDLE;
            endcase

            // ---- Type II/III engine -----------------------------------
            // registered-read settle: every buffer access sets tb_addr
            // and rd_pend; the byte is in tb_q one state later
            if (rd_pend)
                rd_pend <= 1'b0;

            case (rstate)
                R_IDLE: ;

                R_SETUP: begin
                    if (tbv && tb_drv == sel_drv && tb_trk == pos_sel) begin
                        if (is_wt)
                            rstate <= T_WTWAIT;
                        else if (is_rt) begin
                            // raw stream from the index (offset 128);
                            // doubled images deliver every other byte,
                            // like the real controller would see them
                            e_dd      <= dden;
                            rd_pos    <= 13'd128;
                            rd_n_left <= (tb_dbl && !dden)
                                         ? ((tb_len - 13'd128) >> 1)
                                         : (tb_len - 13'd128);
                            us_byte   <= byte_us_w;
                            rstate    <= R_TICK;
                        end else begin
                            entry   <= is_ra ? ra_cur : 6'd0;
                            tb_addr <= {6'd0, (is_ra ? ra_cur : 6'd0), 1'b0};
                            rd_pend <= 1'b1;
                            rstate  <= R_PTR_L;
                        end
                    end else if (tbv && tb_dirty) begin
                        trk_drv    <= tb_drv;       // flush the old track
                        trk_track  <= tb_trk;
                        trk_wb_req <= 1'b1;
                        flush_idle <= 1'b0;
                        rstate     <= R_FLUSH;
                    end else begin
                        tbv       <= 1'b0;
                        trk_drv   <= sel_drv;
                        trk_track <= pos_sel;
                        trk_req   <= 1'b1;
                        rstate    <= R_FETCH;
                    end
                end

                R_FETCH: begin
                    // bytes land via the write port above
                    if (trk_err)
                        rstate <= R_NFWAIT;              // media gone: RNF
                    else if (trk_done) begin
                        tbv    <= 1'b1;
                        tb_drv <= sel_drv;
                        tb_trk <= pos_sel;
                        tb_len <= trk_len;
                        tb_dbl <= trk_dbl;
                        rstate <= R_SETUP;
                    end
                end

                R_PTR_L: if (!rd_pend) begin
                    ptr[7:0] <= tb_q;
                    tb_addr  <= {6'd0, entry, 1'b1};
                    rd_pend  <= 1'b1;
                    rstate   <= R_PTR_H;
                end

                R_PTR_H: if (!rd_pend) begin
                    if ({tb_q[5:0], ptr[7:0]} == 14'd0) begin
                        // end of the pointer list
                        if (is_ra && entry != 6'd0) begin
                            ra_cur  <= 6'd0;             // wrap the cursor
                            entry   <= 6'd0;
                            tb_addr <= 13'd0;
                            rd_pend <= 1'b1;
                            rstate  <= R_PTR_L;
                        end else
                            rstate <= R_NFWAIT;
                    end else if ({tb_q[4:0], ptr[7:0]} >= tb_len
                                 || tb_q[5]) begin
                        entry   <= entry_n;              // implausible: skip
                        tb_addr <= {6'd0, entry_n, 1'b0};
                        rd_pend <= 1'b1;
                        rstate  <= (entry == 6'd63) ? R_NFWAIT : R_PTR_L;
                    end else if (tb_q[7] != dden) begin
                        entry   <= entry_n;              // wrong density:
                        tb_addr <= {6'd0, entry_n, 1'b0};// the other chip's
                        rd_pend <= 1'b1;                 // sector
                        rstate  <= (entry == 6'd63) ? R_NFWAIT : R_PTR_L;
                    end else begin
                        ptr[12:8] <= tb_q[4:0];
                        e_dd      <= tb_q[7];
                        id_i      <= 3'd0;
                        rd_pos    <= {tb_q[4:0], ptr[7:0]};
                        tb_addr   <= {tb_q[4:0], ptr[7:0]};
                        rd_pend   <= 1'b1;
                        rstate    <= R_ID;
                    end
                end

                // walk FE tk sd sc ln (stride estep); rd_pos rides along
                R_ID: if (!rd_pend) begin
                    if ((id_i == 3'd0 && tb_q != 8'hFE)
                        || (id_i == 3'd3 && !is_ra && tb_q != sector)
                        || (id_i == 3'd4 && !is_ra && id_tk != track)) begin
                        entry   <= entry_n;              // no match: next
                        tb_addr <= {6'd0, entry_n, 1'b0};
                        rd_pend <= 1'b1;
                        rstate  <= (entry == 6'd63) ? R_NFWAIT : R_PTR_L;
                    end else if (id_i == 3'd4) begin
                        id_ln <= tb_q[1:0];
                        if (is_ra) begin
                            // stream the 6 ID bytes, track byte first
                            ra_cur    <= entry_n;
                            rd_pos    <= ptr + step_w;
                            rd_n_left <= 13'd6;
                            us_byte   <= byte_us_w;
                            rstate    <= R_TICK;
                        end else begin
                            // rd_pos sits on the ln byte; skip BOTH ID
                            // CRC bytes before hunting (a CRC byte can
                            // legitimately be F8..FB) — gap starts +3
                            dam_hunt <= 6'd43;
                            rd_pos   <= rd_pos + step_w + step_w + step_w;
                            tb_addr  <= rd_pos + step_w + step_w + step_w;
                            rd_pend  <= 1'b1;
                            rstate   <= R_DAM;
                        end
                    end else begin
                        if (id_i == 3'd1) id_tk <= tb_q;
                        // id_i 2 = side byte: the Model 1 ignores it
                        id_i    <= id_i + 3'd1;
                        rd_pos  <= rd_pos + step_w;
                        tb_addr <= rd_pos + step_w;
                        rd_pend <= 1'b1;
                    end
                end

                R_DAM: if (!rd_pend) begin
                    if (tb_q >= 8'hF8 && tb_q <= 8'hFB) begin
                        if (is_wr) begin
                            // overwrite in place from the DAM on: DAM,
                            // 128<<ln data bytes, then a fresh CRC
                            rd_n_left <= 13'd128 << id_ln;
                            wphase    <= 2'd0;
                            us_cnt    <= GAP2_US;
                            rstate    <= R_GAP;
                        end else begin
                            // 1771 (FM): S6:S5 = ~DAM[1:0] — four record
                            // types; 1791 (MFM): S5 = deleted DAM, S6 = 0
                            rec_type  <= e_dd ? {1'b0, ~&tb_q[1:0]}
                                              : ~tb_q[1:0];
                            rd_pos    <= rd_pos + step_w;
                            rd_n_left <= 13'd128 << id_ln;
                            us_cnt    <= GAP2_US;
                            rstate    <= R_GAP;
                        end
                    end else if (dam_hunt == 6'd0) begin
                        entry   <= entry_n;              // no DAM: next IDAM
                        tb_addr <= {6'd0, entry_n, 1'b0};
                        rd_pend <= 1'b1;
                        rstate  <= (entry == 6'd63) ? R_NFWAIT : R_PTR_L;
                    end else begin
                        dam_hunt <= dam_hunt - 6'd1;
                        rd_pos   <= rd_pos + step_w;
                        tb_addr  <= rd_pos + step_w;
                        rd_pend  <= 1'b1;
                    end
                end

                R_GAP:
                    if (en_1m) begin
                        if (us_cnt <= 15'd1) begin
                            us_byte <= byte_us_w;
                            rstate  <= is_wr ? W_TICK : R_TICK;
                        end else
                            us_cnt <= us_cnt - 15'd1;
                    end

                R_TICK:
                    if (en_1m) begin
                        if (us_byte <= 8'd1) begin
                            if (!dreg_busy) begin
                                tb_addr <= rd_pos;
                                rd_pend <= 1'b1;
                                rstate  <= R_BYTE;
                            end
                        end else
                            us_byte <= us_byte - 8'd1;
                    end

                R_BYTE: if (!rd_pend) begin
                    if (drq)
                        lost <= 1'b1;                    // unserviced byte
                    data <= tb_q;
                    drq  <= 1'b1;
                    rd_pos <= rd_pos + step_w;
                    if (rd_n_left == 13'd1) begin
                        us_byte <= {byte_us_w[6:0], 1'b0};  // 2 byte times
                        rstate  <= R_LAST;
                    end else begin
                        rd_n_left <= rd_n_left - 13'd1;
                        us_byte   <= byte_us_w;
                        rstate    <= R_TICK;
                    end
                end

                R_LAST:
                    if (en_1m) begin
                        if (us_byte <= 8'd1)
                            rstate <= R_DONE;
                        else
                            us_byte <= us_byte - 8'd1;
                    end

                W_TICK:
                    if (en_1m) begin
                        if (us_byte <= 8'd1 && dreg_busy)
                            ;                            // defer: in-flight
                        else if (us_byte <= 8'd1) begin
                            // choose this byte-time's value
                            case (wphase)
                                2'd0: begin              // the DAM itself
                                    wval <= 8'hFB - {6'd0, dam_sel};
                                    crc  <= crc16_step(
                                            e_dd ? 16'hCDB4 : 16'hFFFF,
                                            8'hFB - {6'd0, dam_sel});
                                end
                                2'd1: begin              // data via DRQ
                                    if (drq) begin
                                        lost <= 1'b1;    // unserviced: 00
                                        wval <= 8'h00;
                                        crc  <= crc16_step(crc, 8'h00);
                                    end else begin
                                        wval <= data;
                                        crc  <= crc16_step(crc, data);
                                    end
                                end
                                2'd2: wval <= crc[15:8];
                                default: wval <= crc[7:0];
                            endcase
                            rstate <= W_BYTE;
                        end else
                            us_byte <= us_byte - 8'd1;
                    end

                W_BYTE: begin
                    tbw_en   <= 1'b1;
                    tbw_addr <= rd_pos;
                    tbw_data <= wval;
                    tb_dirty <= 1'b1;
                    rd_pos   <= rd_pos + 13'd1;
                    if (estep == 2'd2)
                        rstate <= W_BYTE2;
                    else
                        rstate <= W_TICK;                // fallthrough below
                    // sequencing shared with W_BYTE2 via wnext
                    if (estep != 2'd2) begin
                        case (wphase)
                            2'd0: begin
                                wphase <= 2'd1;
                                drq    <= drq;           // byte 0 pending
                            end
                            2'd1: begin
                                if (rd_n_left == 13'd1)
                                    wphase <= 2'd2;
                                else begin
                                    rd_n_left <= rd_n_left - 13'd1;
                                    drq       <= 1'b1;   // next byte please
                                end
                            end
                            2'd2: wphase <= 2'd3;
                            default: rstate <= R_DONE;   // CRC lo written
                        endcase
                        us_byte <= byte_us_w;
                    end
                end

                W_BYTE2: begin
                    tbw_en   <= 1'b1;                    // doubled copy
                    tbw_addr <= rd_pos;
                    tbw_data <= wval;
                    rd_pos   <= rd_pos + 13'd1;          // second half step
                    rstate   <= W_TICK;
                    case (wphase)
                        2'd0: wphase <= 2'd1;
                        2'd1: begin
                            if (rd_n_left == 13'd1)
                                wphase <= 2'd2;
                            else begin
                                rd_n_left <= rd_n_left - 13'd1;
                                drq       <= 1'b1;
                            end
                        end
                        2'd2: wphase <= 2'd3;
                        default: rstate <= R_DONE;
                    endcase
                    us_byte <= byte_us_w;
                end

                R_FLUSH: begin
                    if (trk_wb_fetch)
                        tb_addr <= trk_wb_idx;
                    if (trk_wb_done || trk_wb_err) begin
                        tb_dirty <= 1'b0;                // media has it (or
                                                         // is gone for good)
                        if (flush_idle)
                            rstate <= R_IDLE;
                        else
                            rstate <= R_SETUP;
                    end
                end

                // ---- write track (format): index edge to index edge --
                T_WTWAIT:
                    if (ip && !ip_d) begin
                        rd_pos  <= 13'd128;              // raw start
                        wt_n    <= 6'd0;
                        wt_crc2 <= 1'b0;
                        e_dd    <= dden;                 // whole track in
                                                         // the latch density
                        us_byte <= byte_us_w;
                        rstate  <= T_WTTICK;
                    end

                T_WTTICK:
                    if ((ip && !ip_d)
                        || rd_pos >= tb_len - 13'd2) begin
                        fin_i  <= 7'd0;                  // one revolution
                        rstate <= T_WTFIN;               // (or buffer full)
                    end else if (en_1m) begin
                        if (us_byte <= 8'd1) begin
                            if (!dreg_busy)
                                rstate <= T_WTBYTE;
                        end else
                            us_byte <= us_byte - 8'd1;
                    end

                T_WTBYTE: begin
                    wt_v <= wt_next;                     // for the 2nd copy
                    if (wt_crc2)
                        wt_crc2 <= 1'b0;                 // F7's second byte
                    else if (drq) begin
                        lost <= 1'b1;                    // unserviced: 00
                        crc  <= crc16_step(crc, 8'h00);
                        drq  <= 1'b1;
                    end else begin
                        if (data == 8'hFE) begin         // ID address mark
                            if (wt_n != 6'd63) begin
                                idam_list[wt_n] <= rd_pos;
                                wt_n <= wt_n + 6'd1;
                            end
                            crc <= e_dd ? crc16_step(crc, 8'hFE)
                                        : crc16_step(16'hFFFF, 8'hFE);
                        end else if (data >= 8'hF8 && data <= 8'hFB)
                            crc <= e_dd ? crc16_step(crc, data)
                                        : crc16_step(16'hFFFF, data);
                        else if (data == 8'hF7)
                            wt_crc2 <= 1'b1;             // lo comes next
                        else if (e_dd && data == 8'hF5)
                            crc <= 16'hCDB4;             // A1: CRC preset
                        else if (e_dd && data == 8'hF6)
                            ;                            // C2: CRC untouched
                        else
                            crc <= crc16_step(crc, data);
                        drq <= 1'b1;                     // next byte please
                    end
                    tbw_en   <= 1'b1;
                    tbw_addr <= rd_pos;
                    tbw_data <= wt_next;
                    tb_dirty <= 1'b1;
                    rd_pos   <= rd_pos + 13'd1;
                    rstate   <= (estep == 2'd2) ? T_WTB2 : T_WTTICK;
                    us_byte  <= byte_us_w;
                end

                T_WTB2: begin
                    tbw_en   <= 1'b1;                    // doubled copy
                    tbw_addr <= rd_pos;
                    tbw_data <= wt_v;
                    rd_pos   <= rd_pos + 13'd1;
                    rstate   <= T_WTTICK;
                end

                T_WTFIN: begin
                    // rebuild the pointer table: 64 x 16-bit LE entries,
                    // low byte then high byte (bit 15 = 0: FM)
                    tbw_en   <= 1'b1;
                    tbw_addr <= {6'd0, fin_i};
                    tbw_data <= fin_i[0]
                                ? ({1'b0, fin_i[6:1]} < {1'b0, wt_n}
                                   ? {e_dd, 2'd0,
                                      idam_list[fin_i[6:1]][12:8]} : 8'd0)
                                : (({1'b0, fin_i[6:1]} < {1'b0, wt_n})
                                   ? idam_list[fin_i[6:1]][7:0] : 8'd0);
                    if (fin_i == 7'd127) begin
                        drq    <= 1'b0;
                        rstate <= R_DONE;
                    end else
                        fin_i <= fin_i + 7'd1;
                end

                R_NFWAIT:
                    if (ip && !ip_d) begin
                        if (ip_cnt == 3'd4) begin
                            rnf    <= 1'b1;
                            rstate <= R_DONE;
                        end else
                            ip_cnt <= ip_cnt + 3'd1;
                    end

                R_DONE: begin
                    busy  <= 1'b0;
                    intrq <= 1'b1;
                    if (drq) begin
                        drq  <= 1'b0;                    // last byte unread
                        lost <= 1'b1;
                    end
                    if (is_ra && !rnf)
                        sector <= id_tk;                 // 1771 quirk
                    rstate <= R_IDLE;
                end

                default: rstate <= R_IDLE;
            endcase
        end
    end

    // CCITT CRC16 (0x1021, init 0xFFFF), one byte per step — the same
    // polynomial the 1771 generates on the medium (build_dmk.py partner)
    function automatic [15:0] crc16_step(input [15:0] c, input [7:0] d);
        integer i;
        reg [15:0] x;
        begin
            x = c ^ {d, 8'h00};
            for (i = 0; i < 8; i = i + 1)
                x = x[15] ? (x << 1) ^ 16'h1021 : (x << 1);
            crc16_step = x;
        end
    endfunction

    // ------------------------------------------------------------------
    // Bus read mux
    // ------------------------------------------------------------------
    assign dout = (a == 2'd0) ? status
                : (a == 2'd1) ? track
                : (a == 2'd2) ? sector
                :               data;
    assign dout_en = sel && !rd_n;

endmodule
