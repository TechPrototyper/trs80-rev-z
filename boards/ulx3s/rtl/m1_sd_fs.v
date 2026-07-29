// TRS-80 Rev Z — SD filesystem layer: ROM load + drive mounts + sector server
//
// Own work (MIT). One FAT32 brain over one sd_spi_host (the single bus
// owner), in three phases:
//
//   1. ROM load  — reads TRS80/LEVEL2.ROM and streams it into the system
//                  ROM through the ld_* seam (unchanged from the verified
//                  m1_sd_loader; the self-test image stays as the visible
//                  fallback when the card or the file is missing).
//   2. Mounts    — for each of TRS80/DRIVE0..DRIVE3/ takes the FIRST
//                  *.DMK entry (8.3 extension match, directory order),
//                  walks its cluster chain ONCE and caches it as a
//                  cluster->LBA table in BRAM. A missing directory, a
//                  missing image or an implausible file simply leaves
//                  that drive unmounted — never an error.
//   3. Serve     — random access: a request (rq_drv, rq_fsec) streams one
//                  512-byte sector of that drive's image; file offset to
//                  LBA is an O(1) table lookup. This is the seam the FDC
//                  track buffer reads through (EI stage plan, ADR-0005).
//                  Stage 5 adds the mirror write port (wq_*): in-place
//                  CMD24 through the same map — DMK files never change
//                  size, so the FAT is never rewritten.
//
// No sector buffer anywhere: every field is snapped from the byte stream
// in flight, so the whole reader is a state machine plus registers.
//
// Filesystem facts (Microsoft FAT specification):
//   - sector 0 is either an MBR (partition 1 must be type 0x0B/0x0C) or,
//     on "superfloppy" cards, the FAT32 volume boot record itself
//   - FAT32 VBR: bytes/sector 11-12 (must be 512), sectors/cluster 13
//     (power of two), reserved sectors 14-15, FAT count 16 (1 or 2),
//     FAT size 36-39, root cluster 44-47; FAT32 is recognized by
//     FATSz16 == 0 and RootEntCnt == 0; 0x55AA signature at 510-511
//   - directory entries are 32 bytes: name 0-10 (8.3, blank padded),
//     attributes 11 (0x0F = LFN -> skip, bit3 volume, bit4 directory),
//     first cluster 20-21 (hi) / 26-27 (lo), file size 28-31;
//     first byte 0xE5 = deleted, 0x00 = end of directory
//   - cluster chain: FAT entry = 4 bytes at fat_lba + clus/128, offset
//     (clus % 128) * 4, masked to 28 bits; >= 0x0FFFFFF8 ends the chain
//
// Cluster map: 4 x 256 entries x 32 bit (one shared 1K x 32 BRAM,
// addressed {drive, index}), each entry the LBA of a cluster's first
// sector. 256 clusters cover any real DMK on any real card (>= 4 GB
// FAT32 cards use >= 4 KiB clusters -> >= 1 MiB per image); a chain
// that would not fit, or a file >= 2 MiB, leaves the drive unmounted.
//
// Error strategy (ROM phase unchanged): any failure before the first ROM
// write leaves the ROM untouched; any failure after writing began
// zero-fills the remainder. `err` = the ROM did not come (cleanly) from
// the card. A card-level failure during mount/serve drops all drives and
// parks in a dead state that answers every request with rq_err.

module m1_sd_fs #(
    parameter [87:0] DIR_NAME  = "TRS80      ",   // 8.3: name(8)+ext(3)
    parameter [87:0] FILE_NAME = "LEVEL2  ROM",
    parameter [13:0] ROM_LEN   = 14'd12288,
    parameter [7:0]  HALF_INIT = 8'd20,
    parameter [7:0]  HALF_FAST = 8'd2,
    parameter [23:0] RETRY_DLY = 24'd2128900
) (
    input  wire        clk,        // dot clock
    input  wire        rst_n,

    // SPI pads (SD card socket)
    output wire        sd_sck,
    output wire        sd_mosi,
    input  wire        sd_miso,
    output wire        sd_cs_n,

    // ROM loader seam (mux'd with the self-test loader in the top level)
    input  wire        ld_gate,    // permission to write (self-test done)
    output reg         ld_en,
    output reg  [13:0] ld_addr,
    output reg  [7:0]  ld_data,

    output reg         loading,    // hold the core in reset while writing
    output reg         sys_ready,  // latched: ROM phase + mounts done, the
                                   // machine may run — monotonic, so it
                                   // leaves reset exactly ONCE (no run-then-
                                   // reset glitch during SD metadata reads)
    output reg         ok,         // ROM replaced from the card
    output reg         err,        // ROM not (cleanly) from the card (LED)
    output wire        init_err,   // the CARD never initialized (SPI level)

    // drive mounts (phase 2 results)
    output reg  [3:0]  drv_mounted,
    output reg         fs_ready,   // mounts finished, server accepting

    // sector server: one 512-byte sector of a mounted drive's image.
    // Requests are only valid once fs_ready is high; the reply is either
    // rq_done (after 512 rq_vld bytes) or rq_err (unmounted drive, sector
    // beyond the image, or the card died).
    input  wire        rq_req,     // pulse
    input  wire [1:0]  rq_drv,
    input  wire [12:0] rq_fsec,    // 512-byte sector index within the image
    output wire        rq_vld,
    output wire [7:0]  rq_dat,
    output wire [8:0]  rq_idx,
    output reg         rq_done,
    output reg         rq_err,

    // sector write server (stage 5): same addressing, pull-style data —
    // wq_fetch pulses with wq_idx, the consumer presents wq_dat two
    // clocks later. In-place CMD24 through the same cluster map; DMK
    // files never change size, so the FAT is never touched.
    input  wire        wq_req,     // pulse
    input  wire [1:0]  wq_drv,
    input  wire [12:0] wq_fsec,
    output wire        wq_fetch,
    output wire [8:0]  wq_idx,
    input  wire [7:0]  wq_dat,
    output reg         wq_done,
    output reg         wq_err
);

    // ------------------------------------------------------------------
    // SPI host
    // ------------------------------------------------------------------
    wire        h_ready, h_init_err, h_rd_done, h_rd_err;
    assign init_err = h_init_err;
    wire        h_wr_done, h_wr_err;
    wire        b_vld;
    wire [7:0]  b_dat;
    wire [8:0]  b_idx;
    reg         rd_req;
    reg  [31:0] rd_lba;
    reg         wr_req;
    reg  [31:0] wr_lba;

    /* verilator lint_off PINCONNECTEMPTY */
    sd_spi_host #(.HALF_INIT(HALF_INIT), .HALF_FAST(HALF_FAST),
                  .RETRY_DLY(RETRY_DLY)) u_spi (
        .clk(clk), .rst_n(rst_n),
        .sck(sd_sck), .mosi(sd_mosi), .miso(sd_miso), .cs_n(sd_cs_n),
        .ready(h_ready), .init_err(h_init_err), .sdhc(),
        .rd_req(rd_req), .rd_lba(rd_lba),
        .byte_vld(b_vld), .byte_data(b_dat), .byte_idx(b_idx),
        .rd_done(h_rd_done), .rd_err(h_rd_err),
        .wr_req(wr_req), .wr_lba(wr_lba),
        .wr_fetch(wq_fetch), .wr_idx(wq_idx), .wr_byte(wq_dat),
        .wr_done(h_wr_done), .wr_err(h_wr_err)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // ------------------------------------------------------------------
    // Snapped filesystem fields (shared by the sector-0 and VBR passes)
    // ------------------------------------------------------------------
    reg [15:0] byts_per_sec;
    reg [7:0]  sec_per_clus;
    reg [15:0] rsvd_secs;
    reg [7:0]  num_fats;
    reg [15:0] root_ent_cnt;
    reg [15:0] fat_sz16;
    reg [31:0] fat_sz32;
    reg [31:0] root_clus;
    reg [7:0]  pt_type;      // MBR partition 1
    reg [31:0] pt_lba;
    reg        sig55, sigAA;

    wire vbr_is_fat32 = (byts_per_sec == 16'd512) && (root_ent_cnt == 16'd0)
                        && (fat_sz16 == 16'd0) && sig55 && sigAA;

    // sectors/cluster must be a power of two; derive the shift and the
    // last sector index of a cluster in one decode
    reg [2:0] spc_shift;
    reg [6:0] spc_last;
    reg       spc_ok;
    always @(*) begin
        spc_ok = 1'b1;
        case (sec_per_clus)
            8'd1:   begin spc_shift = 3'd0; spc_last = 7'd0;   end
            8'd2:   begin spc_shift = 3'd1; spc_last = 7'd1;   end
            8'd4:   begin spc_shift = 3'd2; spc_last = 7'd3;   end
            8'd8:   begin spc_shift = 3'd3; spc_last = 7'd7;   end
            8'd16:  begin spc_shift = 3'd4; spc_last = 7'd15;  end
            8'd32:  begin spc_shift = 3'd5; spc_last = 7'd31;  end
            8'd64:  begin spc_shift = 3'd6; spc_last = 7'd63;  end
            8'd128: begin spc_shift = 3'd7; spc_last = 7'd127; end
            default: begin spc_shift = 3'd0; spc_last = 7'd0; spc_ok = 1'b0; end
        endcase
    end

    // ------------------------------------------------------------------
    // Volume geometry and cluster walking
    // ------------------------------------------------------------------
    reg  [31:0] part_lba, fat_lba, data_lba;
    reg  [31:0] cur_clus;
    reg  [6:0]  sec_i;               // sector index inside the cluster
    reg  [12:0] hop_cnt;             // FAT hops; runaway-chain guard

    wire [31:0] clus_m    = cur_clus & 32'h0FFF_FFFF;
    wire [31:0] clus_lba  = data_lba + ((clus_m - 32'd2) << spc_shift)
                            + {25'd0, sec_i};
    wire [31:0] fat_ent_lba = fat_lba + {7'd0, clus_m[31:7]};

    reg  [31:0] fat_next;            // snapped FAT entry
    wire [31:0] fat_next_m = fat_next & 32'h0FFF_FFFF;
    wire        fat_eoc    = (fat_next_m >= 32'h0FFF_FFF8);
    wire        fat_bad    = (fat_next_m == 32'h0FFF_FFF7)
                             || (fat_next_m < 32'd2);

    // ------------------------------------------------------------------
    // Directory entry matcher (streaming, 32-byte aligned entries).
    // ext_match relaxes the name half: any live entry whose extension
    // matches search_name[23:0] — "first *.DMK in directory order".
    // ------------------------------------------------------------------
    reg  [87:0] search_name;
    reg         want_dir;
    reg         ext_match;
    reg         e_match;
    reg         dir_end;
    reg  [31:0] e_clus;
    reg  [23:0] e_size;    // bytes 28-30; byte 31 joins directly in f_size
    reg         found;
    reg  [31:0] f_clus, f_size;

    wire [4:0]  eoff = b_idx[4:0];   // offset inside the directory entry

    // ------------------------------------------------------------------
    // ROM load bookkeeping (phase 1)
    // ------------------------------------------------------------------
    reg  [31:0] file_clus, file_size;
    reg  [13:0] load_len, rom_cnt;
    reg  [1:0]  resume;              // after a FAT hop: 0 dir, 1 file, 2 map
    reg  [4:0]  prep_cnt;
    reg         err_pending;         // failure after ROM writes began

    // ------------------------------------------------------------------
    // Scan sequencing: which search the shared dir/FAT states serve
    // ------------------------------------------------------------------
    localparam [1:0]
        SJ_ROOT = 2'd0,              // TRS80/ in the root directory
        SJ_ROMF = 2'd1,              // LEVEL2.ROM in TRS80/
        SJ_DRVD = 2'd2,              // DRIVEn/ in TRS80/
        SJ_DMK  = 2'd3;              // first *.DMK in DRIVEn/

    localparam [87:0] EXT_DMK = "????????DMK";   // name half unused

    reg  [1:0]  scan_job;
    reg  [31:0] trs_clus;            // TRS80/ start cluster (mounts rescan it)
    reg  [1:0]  drv_i;               // drive being mounted
    wire [7:0]  drv_digit = 8'h30 + {6'd0, drv_i};

    // ------------------------------------------------------------------
    // Cluster map (phase 2 product, phase 3 lookup): {drive, index} ->
    // LBA of the cluster's first sector. Registered read for EBR.
    // ------------------------------------------------------------------
    reg  [31:0] cmap [0:1023];
    reg  [31:0] cmap_q;
    reg  [9:0]  map_raddr;
    reg  [7:0]  map_idx;
    reg  [8:0]  need_n;              // map entries this image needs
    reg  [12:0] drv_secs [0:3];      // image length in 512-byte sectors

    // image geometry, valid while f_size < 2 MiB (checked first)
    wire [12:0] f_secs_w = {1'b0, f_size[20:9]} + {12'd0, |f_size[8:0]};
    wire [12:0] need_w   = (f_secs_w + {6'd0, spc_last}) >> spc_shift;

    // serve-side lookup
    wire [12:0] fsec_c = rq_fsec >> spc_shift;
    wire [12:0] wsec_c = wq_fsec >> spc_shift;
    reg  [6:0]  s_off;               // sector offset inside the cluster

    localparam [4:0]
        L_WAIT      = 5'd0,
        L_S0_REQ    = 5'd1,
        L_S0        = 5'd2,
        L_VBR_REQ   = 5'd3,
        L_VBR       = 5'd4,
        L_CALC      = 5'd5,
        L_DIR_REQ   = 5'd6,
        L_DIR       = 5'd7,
        L_FAT_REQ   = 5'd8,
        L_FAT       = 5'd9,
        L_GATE      = 5'd10,
        L_PREP      = 5'd11,
        L_FILE_REQ  = 5'd12,
        L_FILE      = 5'd13,
        L_FILL      = 5'd14,
        L_FOUND     = 5'd15,
        L_NFOUND    = 5'd16,
        L_MNT       = 5'd17,
        L_MAP_INIT  = 5'd18,
        L_MAP_STORE = 5'd19,
        L_MNT_NEXT  = 5'd20,
        L_SERVE     = 5'd21,
        L_SRV_LK    = 5'd22,
        L_SRV_REQ   = 5'd23,
        L_SRV_RD    = 5'd24,
        L_DEAD      = 5'd25,
        L_SWR_LK    = 5'd26,
        L_SWR_REQ   = 5'd27,
        L_SWR_WR    = 5'd28;

    reg [4:0] state;

    // serve-phase byte stream, gated to the read we issued
    assign rq_vld = b_vld && (state == L_SRV_RD);
    assign rq_dat = b_dat;
    assign rq_idx = b_idx;

    // cluster map BRAM (write during the walk — sec_i is 0 there, so
    // clus_lba is exactly the cluster's first sector)
    always @(posedge clk) begin
        if (state == L_MAP_STORE)
            cmap[{drv_i, map_idx}] <= clus_lba;
        cmap_q <= cmap[map_raddr];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= L_WAIT;
            rd_req       <= 1'b0;
            rd_lba       <= 32'd0;
            byts_per_sec <= 16'd0;
            sec_per_clus <= 8'd0;
            rsvd_secs    <= 16'd0;
            num_fats     <= 8'd0;
            root_ent_cnt <= 16'd0;
            fat_sz16     <= 16'd0;
            fat_sz32     <= 32'd0;
            root_clus    <= 32'd0;
            pt_type      <= 8'd0;
            pt_lba       <= 32'd0;
            sig55        <= 1'b0;
            sigAA        <= 1'b0;
            part_lba     <= 32'd0;
            fat_lba      <= 32'd0;
            data_lba     <= 32'd0;
            cur_clus     <= 32'd0;
            sec_i        <= 7'd0;
            hop_cnt      <= 13'd0;
            fat_next     <= 32'd0;
            search_name  <= 88'd0;
            want_dir     <= 1'b0;
            ext_match    <= 1'b0;
            e_match      <= 1'b0;
            dir_end      <= 1'b0;
            e_clus       <= 32'd0;
            e_size       <= 24'd0;
            found        <= 1'b0;
            f_clus       <= 32'd0;
            f_size       <= 32'd0;
            file_clus    <= 32'd0;
            file_size    <= 32'd0;
            load_len     <= 14'd0;
            rom_cnt      <= 14'd0;
            resume       <= 2'd0;
            prep_cnt     <= 5'd0;
            err_pending  <= 1'b0;
            scan_job     <= SJ_ROOT;
            trs_clus     <= 32'd0;
            drv_i        <= 2'd0;
            map_raddr    <= 10'd0;
            map_idx      <= 8'd0;
            need_n       <= 9'd0;
            s_off        <= 7'd0;
            drv_mounted  <= 4'b0000;
            fs_ready     <= 1'b0;
            rq_done      <= 1'b0;
            rq_err       <= 1'b0;
            wq_done      <= 1'b0;
            wq_err       <= 1'b0;
            wr_req       <= 1'b0;
            wr_lba       <= 32'd0;
            ld_en        <= 1'b0;
            ld_addr      <= 14'd0;
            ld_data      <= 8'd0;
            loading      <= 1'b0;
            sys_ready    <= 1'b0;
            ok           <= 1'b0;
            err          <= 1'b0;
        end else begin
            rd_req  <= 1'b0;
            wr_req  <= 1'b0;
            ld_en   <= 1'b0;
            // the boot phase is over once the FS serves drive requests (or
            // has given up on a dead card); latch it, monotonic
            if (state == L_SERVE || state == L_DEAD)
                sys_ready <= 1'b1;
            rq_done <= 1'b0;
            rq_err  <= 1'b0;
            wq_done <= 1'b0;
            wq_err  <= 1'b0;

            // Error escape: a host error mid-flight would otherwise strand
            // the wait-for-rd_done states. During the ROM load the
            // remainder is zero-filled deterministically; anywhere else
            // the card is unusable — drop to L_DEAD (failing a serve
            // request that was in flight).
            if (state != L_SERVE && state != L_DEAD && state != L_FILL
                && state != L_WAIT
                && (h_init_err || h_rd_err || h_wr_err)) begin
                if (loading) begin
                    err_pending <= 1'b1;
                    state       <= L_FILL;
                end else begin
                    if (state == L_SRV_LK || state == L_SRV_REQ
                        || state == L_SRV_RD)
                        rq_err <= 1'b1;
                    if (state == L_SWR_LK || state == L_SWR_REQ
                        || state == L_SWR_WR)
                        wq_err <= 1'b1;
                    state <= L_DEAD;
                end
            end else case (state)

                L_WAIT: begin
                    if (h_init_err)     state <= L_DEAD;
                    else if (h_ready)   state <= L_S0_REQ;
                end

                // ---- sector 0: MBR or superfloppy VBR ----------------
                L_S0_REQ: begin
                    rd_lba <= 32'd0;
                    rd_req <= 1'b1;
                    sig55  <= 1'b0;
                    sigAA  <= 1'b0;
                    state  <= L_S0;
                end
                L_S0: begin
                    if (b_vld) begin
                        case (b_idx)
                            9'd11:  byts_per_sec[7:0]  <= b_dat;
                            9'd12:  byts_per_sec[15:8] <= b_dat;
                            9'd13:  sec_per_clus       <= b_dat;
                            9'd14:  rsvd_secs[7:0]     <= b_dat;
                            9'd15:  rsvd_secs[15:8]    <= b_dat;
                            9'd16:  num_fats           <= b_dat;
                            9'd17:  root_ent_cnt[7:0]  <= b_dat;
                            9'd18:  root_ent_cnt[15:8] <= b_dat;
                            9'd22:  fat_sz16[7:0]      <= b_dat;
                            9'd23:  fat_sz16[15:8]     <= b_dat;
                            9'd36:  fat_sz32[7:0]      <= b_dat;
                            9'd37:  fat_sz32[15:8]     <= b_dat;
                            9'd38:  fat_sz32[23:16]    <= b_dat;
                            9'd39:  fat_sz32[31:24]    <= b_dat;
                            9'd44:  root_clus[7:0]     <= b_dat;
                            9'd45:  root_clus[15:8]    <= b_dat;
                            9'd46:  root_clus[23:16]   <= b_dat;
                            9'd47:  root_clus[31:24]   <= b_dat;
                            9'd450: pt_type            <= b_dat;
                            9'd454: pt_lba[7:0]        <= b_dat;
                            9'd455: pt_lba[15:8]       <= b_dat;
                            9'd456: pt_lba[23:16]      <= b_dat;
                            9'd457: pt_lba[31:24]      <= b_dat;
                            9'd510: sig55 <= (b_dat == 8'h55);
                            9'd511: sigAA <= (b_dat == 8'hAA);
                            default: ;
                        endcase
                    end
                    if (h_rd_done) begin
                        if (vbr_is_fat32 && spc_ok) begin
                            part_lba <= 32'd0;       // superfloppy: sector 0
                            state    <= L_CALC;      // was the VBR itself
                        end else if (sig55 && sigAA
                                     && (pt_type == 8'h0B || pt_type == 8'h0C)) begin
                            part_lba <= pt_lba;
                            state    <= L_VBR_REQ;
                        end else
                            state <= L_DEAD;         // no FAT32 volume
                    end
                end

                // ---- volume boot record ------------------------------
                L_VBR_REQ: begin
                    rd_lba <= part_lba;
                    rd_req <= 1'b1;
                    sig55  <= 1'b0;
                    sigAA  <= 1'b0;
                    state  <= L_VBR;
                end
                L_VBR: begin
                    if (b_vld) begin
                        case (b_idx)
                            9'd11: byts_per_sec[7:0]  <= b_dat;
                            9'd12: byts_per_sec[15:8] <= b_dat;
                            9'd13: sec_per_clus       <= b_dat;
                            9'd14: rsvd_secs[7:0]     <= b_dat;
                            9'd15: rsvd_secs[15:8]    <= b_dat;
                            9'd16: num_fats           <= b_dat;
                            9'd17: root_ent_cnt[7:0]  <= b_dat;
                            9'd18: root_ent_cnt[15:8] <= b_dat;
                            9'd22: fat_sz16[7:0]      <= b_dat;
                            9'd23: fat_sz16[15:8]     <= b_dat;
                            9'd36: fat_sz32[7:0]      <= b_dat;
                            9'd37: fat_sz32[15:8]     <= b_dat;
                            9'd38: fat_sz32[23:16]    <= b_dat;
                            9'd39: fat_sz32[31:24]    <= b_dat;
                            9'd44: root_clus[7:0]     <= b_dat;
                            9'd45: root_clus[15:8]    <= b_dat;
                            9'd46: root_clus[23:16]   <= b_dat;
                            9'd47: root_clus[31:24]   <= b_dat;
                            9'd510: sig55 <= (b_dat == 8'h55);
                            9'd511: sigAA <= (b_dat == 8'hAA);
                            default: ;
                        endcase
                    end
                    if (h_rd_done)
                        state <= L_CALC;
                end

                // ---- validate the volume, derive the geometry --------
                // (reached from L_VBR, or straight from L_S0 on
                // superfloppy cards whose sector 0 is the VBR)
                L_CALC: begin
                    if (vbr_is_fat32 && spc_ok
                        && (num_fats == 8'd1 || num_fats == 8'd2)) begin
                        fat_lba  <= part_lba + {16'd0, rsvd_secs};
                        data_lba <= part_lba + {16'd0, rsvd_secs}
                                    + ((num_fats == 8'd2)
                                       ? (fat_sz32 << 1) : fat_sz32);
                        // search TRS80/ in the root directory
                        search_name <= DIR_NAME;
                        want_dir    <= 1'b1;
                        ext_match   <= 1'b0;
                        scan_job    <= SJ_ROOT;
                        cur_clus    <= root_clus;
                        sec_i       <= 7'd0;
                        found       <= 1'b0;
                        dir_end     <= 1'b0;
                        hop_cnt     <= 13'd0;
                        state       <= L_DIR_REQ;
                    end else
                        state <= L_DEAD;
                end

                // ---- directory scan (shared by all four searches) ----
                L_DIR_REQ: begin
                    rd_lba <= clus_lba;
                    rd_req <= 1'b1;
                    state  <= L_DIR;
                end
                L_DIR: begin
                    if (b_vld) begin
                        case (eoff)
                            5'd0: begin
                                if (b_dat == 8'h00) dir_end <= 1'b1;
                                e_match <= (ext_match
                                            ? (b_dat != 8'hE5 && b_dat != 8'h00)
                                            : (b_dat == search_name[87:80]))
                                           && !dir_end;
                            end
                            5'd1:  if (!ext_match && b_dat != search_name[79:72])
                                       e_match <= 1'b0;
                            5'd2:  if (!ext_match && b_dat != search_name[71:64])
                                       e_match <= 1'b0;
                            5'd3:  if (!ext_match && b_dat != search_name[63:56])
                                       e_match <= 1'b0;
                            5'd4:  if (!ext_match && b_dat != search_name[55:48])
                                       e_match <= 1'b0;
                            5'd5:  if (!ext_match && b_dat != search_name[47:40])
                                       e_match <= 1'b0;
                            5'd6:  if (!ext_match && b_dat != search_name[39:32])
                                       e_match <= 1'b0;
                            5'd7:  if (!ext_match && b_dat != search_name[31:24])
                                       e_match <= 1'b0;
                            5'd8:  if (b_dat != search_name[23:16]) e_match <= 1'b0;
                            5'd9:  if (b_dat != search_name[15:8])  e_match <= 1'b0;
                            5'd10: if (b_dat != search_name[7:0])   e_match <= 1'b0;
                            5'd11: // attributes: skip volume labels/LFN
                                   // entries, require the directory bit to
                                   // match what we search for
                                   if (b_dat[3] || (b_dat[4] != want_dir))
                                       e_match <= 1'b0;
                            5'd20: e_clus[23:16] <= b_dat;
                            5'd21: e_clus[31:24] <= b_dat;
                            5'd26: e_clus[7:0]   <= b_dat;
                            5'd27: e_clus[15:8]  <= b_dat;
                            5'd28: e_size[7:0]   <= b_dat;
                            5'd29: e_size[15:8]  <= b_dat;
                            5'd30: e_size[23:16] <= b_dat;
                            5'd31: if (e_match && !found) begin
                                       found  <= 1'b1;
                                       f_clus <= e_clus;
                                       f_size <= {b_dat, e_size};
                                   end
                            default: ;
                        endcase
                    end
                    if (h_rd_done) begin
                        if (found)
                            state <= L_FOUND;
                        else if (dir_end)
                            state <= L_NFOUND;
                        else if (sec_i != spc_last) begin
                            sec_i <= sec_i + 7'd1;
                            state <= L_DIR_REQ;
                        end else begin
                            resume <= 2'd0;
                            state  <= L_FAT_REQ;
                        end
                    end
                end

                // ---- search hit: dispatch by job ---------------------
                L_FOUND: begin
                    case (scan_job)
                        SJ_ROOT: begin           // TRS80/ found: ROM next
                            trs_clus    <= f_clus;
                            search_name <= FILE_NAME;
                            want_dir    <= 1'b0;
                            ext_match   <= 1'b0;
                            scan_job    <= SJ_ROMF;
                            cur_clus    <= f_clus;
                            sec_i       <= 7'd0;
                            found       <= 1'b0;
                            dir_end     <= 1'b0;
                            hop_cnt     <= 13'd0;
                            state       <= L_DIR_REQ;
                        end
                        SJ_ROMF: begin           // ROM file: go load it
                            file_clus <= f_clus;
                            file_size <= f_size;
                            state     <= L_GATE;
                        end
                        SJ_DRVD: begin           // DRIVEn/: find its DMK
                            search_name <= EXT_DMK;
                            want_dir    <= 1'b0;
                            ext_match   <= 1'b1;
                            scan_job    <= SJ_DMK;
                            cur_clus    <= f_clus;
                            sec_i       <= 7'd0;
                            found       <= 1'b0;
                            dir_end     <= 1'b0;
                            hop_cnt     <= 13'd0;
                            state       <= L_DIR_REQ;
                        end
                        SJ_DMK:                  // image file: map it
                            state <= L_MAP_INIT;
                    endcase
                end

                // ---- search miss: dispatch by job --------------------
                L_NFOUND: begin
                    case (scan_job)
                        SJ_ROOT: begin           // no TRS80/: nothing at all
                            err   <= 1'b1;
                            state <= L_SERVE;
                        end
                        SJ_ROMF: begin           // no ROM: fallback stays,
                            err   <= 1'b1;       // drives still mount
                            drv_i <= 2'd0;
                            state <= L_MNT;
                        end
                        default:                 // drive dir or DMK missing:
                            state <= L_MNT_NEXT; // that drive stays unmounted
                    endcase
                end

                // ---- follow the cluster chain ------------------------
                L_FAT_REQ: begin
                    rd_lba <= fat_ent_lba;
                    rd_req <= 1'b1;
                    state  <= L_FAT;
                end
                L_FAT: begin
                    if (b_vld && (b_idx[8:2] == clus_m[6:0])) begin
                        case (b_idx[1:0])
                            2'd0: fat_next[7:0]   <= b_dat;
                            2'd1: fat_next[15:8]  <= b_dat;
                            2'd2: fat_next[23:16] <= b_dat;
                            2'd3: fat_next[31:24] <= b_dat;
                        endcase
                    end
                    if (h_rd_done) begin
                        if (hop_cnt == 13'd4096) begin   // runaway chain
                            if (loading) begin
                                err_pending <= 1'b1;
                                state       <= L_FILL;
                            end else if (resume == 2'd2)
                                state <= L_MNT_NEXT;
                            else
                                state <= L_NFOUND;
                        end else if (fat_eoc) begin
                            // chain ended: while loading, the file was
                            // shorter than its directory size claims ->
                            // fill and flag; while mapping, the drive is
                            // unmountable; while searching, "not found"
                            if (resume == 2'd1) begin
                                if (rom_cnt < load_len) err_pending <= 1'b1;
                                state <= L_FILL;
                            end else if (resume == 2'd2)
                                state <= L_MNT_NEXT;
                            else
                                state <= L_NFOUND;
                        end else if (fat_bad) begin
                            if (loading) begin
                                err_pending <= 1'b1;
                                state       <= L_FILL;
                            end else if (resume == 2'd2)
                                state <= L_MNT_NEXT;
                            else
                                state <= L_NFOUND;
                        end else begin
                            cur_clus <= fat_next_m;
                            sec_i    <= 7'd0;
                            hop_cnt  <= hop_cnt + 13'd1;
                            if (resume == 2'd2) begin
                                map_idx <= map_idx + 8'd1;
                                state   <= L_MAP_STORE;
                            end else
                                state <= (resume == 2'd1) ? L_FILE_REQ
                                                          : L_DIR_REQ;
                        end
                    end
                end

                // ---- load the file into the ROM ----------------------
                L_GATE: begin
                    // sanity before touching the ROM; a bad entry leaves
                    // the fallback image and moves on to the mounts
                    if (file_clus[27:0] < 28'd2 || file_size == 32'd0) begin
                        err   <= 1'b1;
                        drv_i <= 2'd0;
                        state <= L_MNT;
                    end else if (ld_gate) begin
                        load_len <= (file_size >= {18'd0, ROM_LEN})
                                    ? ROM_LEN : file_size[13:0];
                        cur_clus <= file_clus;
                        sec_i    <= 7'd0;
                        rom_cnt  <= 14'd0;
                        prep_cnt <= 5'd0;
                        loading  <= 1'b1;    // core goes into reset now
                        state    <= L_PREP;
                    end
                end
                L_PREP: begin
                    // a few quiet cycles so the core is firmly in reset
                    // before the first ld_en write lands
                    prep_cnt <= prep_cnt + 5'd1;
                    if (&prep_cnt)
                        state <= L_FILE_REQ;
                end
                L_FILE_REQ: begin
                    rd_lba <= clus_lba;
                    rd_req <= 1'b1;
                    state  <= L_FILE;
                end
                L_FILE: begin
                    if (b_vld && (rom_cnt < load_len)) begin
                        ld_en   <= 1'b1;
                        ld_addr <= rom_cnt;
                        ld_data <= b_dat;
                        rom_cnt <= rom_cnt + 14'd1;
                    end
                    if (h_rd_done) begin
                        if (rom_cnt >= load_len)
                            state <= L_FILL;
                        else if (sec_i != spc_last) begin
                            sec_i <= sec_i + 7'd1;
                            state <= L_FILE_REQ;
                        end else begin
                            resume <= 2'd1;
                            state  <= L_FAT_REQ;
                        end
                    end
                end

                // ---- zero-fill up to ROM_LEN, release the core, then
                //      move on to the drive mounts ---------------------
                L_FILL: begin
                    if (rom_cnt < ROM_LEN) begin
                        ld_en   <= 1'b1;
                        ld_addr <= rom_cnt;
                        ld_data <= 8'h00;
                        rom_cnt <= rom_cnt + 14'd1;
                    end else begin
                        loading <= 1'b0;
                        ok      <= ~err_pending;
                        err     <= err_pending;
                        if (h_init_err || h_rd_err)
                            state <= L_DEAD;     // the card itself died
                        else begin
                            drv_i <= 2'd0;
                            state <= L_MNT;
                        end
                    end
                end

                // ---- phase 2: mount DRIVE0..DRIVE3 -------------------
                L_MNT: begin
                    search_name <= {"DRIVE", drv_digit, "     "};
                    want_dir    <= 1'b1;
                    ext_match   <= 1'b0;
                    scan_job    <= SJ_DRVD;
                    cur_clus    <= trs_clus;
                    sec_i       <= 7'd0;
                    found       <= 1'b0;
                    dir_end     <= 1'b0;
                    hop_cnt     <= 13'd0;
                    state       <= L_DIR_REQ;
                end
                L_MAP_INIT: begin
                    // implausible image -> leave the drive unmounted
                    if (f_clus[27:0] < 28'd2 || f_size == 32'd0
                        || f_size >= 32'h0020_0000       // >= 2 MiB
                        || need_w == 13'd0 || need_w > 13'd256)
                        state <= L_MNT_NEXT;
                    else begin
                        drv_secs[drv_i] <= f_secs_w;
                        need_n   <= need_w[8:0];
                        cur_clus <= f_clus;
                        sec_i    <= 7'd0;
                        map_idx  <= 8'd0;
                        hop_cnt  <= 13'd0;
                        state    <= L_MAP_STORE;
                    end
                end
                L_MAP_STORE: begin
                    // (the BRAM write for {drv_i, map_idx} happens above)
                    if ({1'b0, map_idx} == need_n - 9'd1) begin
                        drv_mounted[drv_i] <= 1'b1;      // map complete
                        state <= L_MNT_NEXT;
                    end else begin
                        resume <= 2'd2;
                        state  <= L_FAT_REQ;
                    end
                end
                L_MNT_NEXT: begin
                    if (drv_i == 2'd3)
                        state <= L_SERVE;
                    else begin
                        drv_i <= drv_i + 2'd1;
                        state <= L_MNT;
                    end
                end

                // ---- phase 3: sector server --------------------------
                L_SERVE: begin
                    fs_ready <= 1'b1;
                    if (rq_req) begin
                        if (!drv_mounted[rq_drv]
                            || rq_fsec >= drv_secs[rq_drv]
                            || fsec_c > 13'd255)
                            rq_err <= 1'b1;
                        else begin
                            s_off     <= rq_fsec[6:0] & spc_last;
                            map_raddr <= {rq_drv, fsec_c[7:0]};
                            state     <= L_SRV_LK;
                        end
                    end else if (wq_req) begin
                        if (!drv_mounted[wq_drv]
                            || wq_fsec >= drv_secs[wq_drv]
                            || wsec_c > 13'd255)
                            wq_err <= 1'b1;
                        else begin
                            s_off     <= wq_fsec[6:0] & spc_last;
                            map_raddr <= {wq_drv, wsec_c[7:0]};
                            state     <= L_SWR_LK;
                        end
                    end
                end
                L_SRV_LK:                        // registered BRAM read
                    state <= L_SRV_REQ;
                L_SRV_REQ: begin
                    rd_lba <= cmap_q + {25'd0, s_off};
                    rd_req <= 1'b1;
                    state  <= L_SRV_RD;
                end
                L_SRV_RD:                        // bytes flow via rq_vld
                    if (h_rd_done) begin
                        rq_done <= 1'b1;
                        state   <= L_SERVE;
                    end

                L_SWR_LK:                        // registered BRAM read
                    state <= L_SWR_REQ;
                L_SWR_REQ: begin
                    wr_lba <= cmap_q + {25'd0, s_off};
                    wr_req <= 1'b1;
                    state  <= L_SWR_WR;
                end
                L_SWR_WR:                        // bytes pulled via wq_fetch
                    if (h_wr_done) begin
                        wq_done <= 1'b1;
                        state   <= L_SERVE;
                    end

                // ---- card-level failure: everything unmounted --------
                L_DEAD: begin
                    err         <= 1'b1;
                    fs_ready    <= 1'b1;
                    drv_mounted <= 4'b0000;
                    if (rq_req) rq_err <= 1'b1;
                    if (wq_req) wq_err <= 1'b1;
                end

                default: state <= L_DEAD;
            endcase
        end
    end

endmodule
