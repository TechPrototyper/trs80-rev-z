// TRS-80 Rev Z — the machine, composed
//
// The whole Model 1 as one synthesizable module: clock divider, Z80 (tv80),
// address decoder, ROM, RAM, video RAM, the port-0xFF register, the keyboard
// matrix, and the video chain — wired on a single shared data bus. Chapters
// 1-7 built and verified each block; this is the block that instantiates them
// all, promoted out of the testbench into RTL every hardware target can build
// on.
//
// The data bus is a mux, not a tri-state net: inside an FPGA there is no bus,
// so each source drives (value, enable) and this module selects — the same
// value+enable idiom the individual modules already export. Exactly one source
// is enabled per cycle (the chapter-5 bench proves it); the default is 0xFF,
// the open-bus level a real machine floats to.
//
// External surface (what a board top-level connects):
//   - clk: the 10.6445 MHz dot clock (single clock domain, ADR-0001)
//   - reset in two flavors (power-on, front-panel button) + TEST*/INT*/WAIT*
//   - ROM loader port (SD/ESP32 on hardware; the ROM is never bundled)
//   - keys[63:0]: the pressed-key matrix (USB-HID front end drives it)
//   - cassette in/out + motor
//   - video: serial `pixel` plus HDRV/VDRV sync and dot_en/modesel for the
//     downstream display stage (HDMI/composite), and the raw row/col/line so a
//     framebuffer stage can place it
//   - a few CPU status lines for board-level debug/observability

module m1_core #(
    // chargen table path (ADR-0002), forwarded to m1_video_gen so builds
    // running from other directories (boards/, board sims) can point at it
    parameter FONT_HEX = "../rtl/mcm6670_cg1.hex"
) (
    input  wire        clk,          // 10.6445 MHz dot clock
    input  wire        por_rst_n,    // MACHINE reset (async, active low)
    input  wire        dbg_rst_n,    // debug subsystem reset (FPGA POR) —
                                     // survives a machine reset so the
                                     // debugger can observe+report it
                                     // (ADR-0006 §3a); tie to por_rst_n
                                     // when no separate POR exists
    input  wire        reset_btn_n,  // front-panel reset button (low = pressed)
    input  wire        test_n,       // TEST* (external bus master)
    input  wire        int_n,        // INT* (EI heartbeat, M3)
    input  wire        wait_n,       // WAIT*

    // ROM loader (board: SD/ESP32; sim: testbench) — no ROM lives in the RTL
    input  wire        ld_en,
    input  wire [13:0] ld_addr,
    input  wire [7:0]  ld_data,

    // Expansion Interface RAM population (ADR-0005): 00 = none (16K
    // system), 01 = 16K (32K system), 1x = 32K (48K system)
    input  wire [1:0]  ei_ram_cfg,
    input  wire [3:0]  fdc_disk,     // media present per drive (EI stage 2)
    input  wire [3:0]  fdc_wp,       // write-protect per drive (stage 5)
    input  wire        percom_en,    // Percom Doubler fitted (stage 6)

    // FDC track fetch (EI stage 3): the board's DMK fetcher (or a bench
    // model) serves raw DMK tracks into the FDC's track buffer
    output wire        trk_req,
    output wire [1:0]  trk_drv,
    output wire [6:0]  trk_track,
    output wire        trk_side,
    input  wire        trk_vld,
    input  wire [7:0]  trk_data,
    input  wire [12:0] trk_idx,
    input  wire        trk_done,
    input  wire        trk_err,
    input  wire [12:0] trk_len,
    input  wire        trk_dbl,
    output wire        trk_wb_req,
    input  wire        trk_wb_fetch,
    input  wire [12:0] trk_wb_idx,
    output wire [7:0]  trk_wb_data,
    input  wire        trk_wb_done,
    input  wire        trk_wb_err,

    // keyboard matrix pressed-state, keys[8*row + col]
    input  wire [63:0] keys,

    // cassette
    input  wire        cass_in,
    output wire [1:0]  cass_out,
    output wire        cass_motor,

    // drive-sound event stream (M7): the m1_drives boundary events the
    // board's or emulator's sound engine consumes — {DS latch [3:0],
    // motor one-shot, step pulse, step direction}. Pure observability;
    // unread it costs nothing.
    output wire [6:0]  snd,

    // video output
    output wire        pixel,        // serial dot stream
    output wire        hdrv,         // horizontal drive (blank/sync source)
    output wire        vdrv,         // vertical drive
    output wire        dot_en,       // pixel-rate enable (mode-conditioned)
    output wire        modesel,      // 1 = 64-char, 0 = 32-char
    output wire [6:0]  col,          // character column 0..111
    output wire [3:0]  line,         // scan line within row 0..11
    output wire [4:0]  row,          // character row 0..21

    // debug host port (ADR-0006): byte commands in, byte responses out;
    // tie in_valid low and out_ready high when no debugger is attached
    input  wire        dbg_in_valid,
    input  wire [7:0]  dbg_in_data,
    output wire        dbg_in_ready,
    output wire        dbg_out_valid,
    output wire [7:0]  dbg_out_data,
    input  wire        dbg_out_ready,

    // observability
    output wire [15:0] addr,
    output wire        m1_n,
    output wire        halt_n,
    output wire        cpu_cen
);

    // ---- shared data bus (mux of the enabled source) ----
    wire [7:0] bus;

    // ---- clock; the debug core may withhold the enable (ADR-0006) ----
    wire cen_raw, dbg_freeze;
    m1_cpu_clock u_cc (.clk(clk), .rst_n(por_rst_n), .cpu_cen(cen_raw));
    assign cpu_cen = cen_raw & ~dbg_freeze;

    // ---- CPU + control layer ----
    wire        addr_en, dbout_n, dbin_n;
    wire [7:0]  cpu_dout;
    wire        ras_n, rd_n, wr_n, in_n, out_n, intak_n, sysres_n, mux, cas_n;
    wire        busak_n;

    // external INT* (bus connector) wire-ANDs with the EI's own (open
    // collector on the real bus)
    wire ei_int_n;
    // during instruction stuffing INT is masked (the pending level in the
    // EI survives and fires after the restore, like on a real ICE)
    wire dbg_stuff;
    wire cpu_int_n = (int_n & ei_int_n) | dbg_stuff;

    wire cpu_fetch_t1, cpu_fetch_lat, cpu_inte;

    m1_cpu u_cpu (
        .clk(clk), .cpu_cen(cpu_cen),
        .por_rst_n(por_rst_n), .reset_btn_n(reset_btn_n),
        .test_n(test_n), .int_n(cpu_int_n), .wait_n(wait_n),
        .din(bus),
        .addr(addr), .addr_en(addr_en),
        .dout(cpu_dout), .dbout_n(dbout_n), .dbin_n(dbin_n),
        .ras_n(ras_n), .rd_n(rd_n), .wr_n(wr_n),
        .in_n(in_n), .out_n(out_n), .intak_n(intak_n),
        .sysres_n(sysres_n), .mux(mux), .cas_n(cas_n),
        .m1_n(m1_n), .halt_n(halt_n), .busak_n(busak_n),
        .fetch_t1(cpu_fetch_t1), .fetch_lat(cpu_fetch_lat),
        .inte(cpu_inte)
    );

    // ---- debug core (ADR-0006): halts via the cen gate above and, while
    //      frozen, masters the address/strobe fabric below ----
    wire        dbg_master;
    wire [15:0] dbg_addr;
    wire [7:0]  dbg_wdata;
    wire        dbg_rd_n, dbg_wr_n;
    wire [7:0]  dbg_feed;

    m1_debug u_dbg (
        .clk(clk), .rst_n(dbg_rst_n), .tgt_rst_n(por_rst_n),
        .in_valid(dbg_in_valid), .in_data(dbg_in_data),
        .in_ready(dbg_in_ready),
        .out_valid(dbg_out_valid), .out_data(dbg_out_data),
        .out_ready(dbg_out_ready),
        .fetch_t1(cpu_fetch_t1), .fetch_lat(cpu_fetch_lat),
        .cpu_addr(addr), .bus(bus), .cpu_cen_raw(cen_raw),
        .cpu_rd_n(rd_n), .cpu_wr_n(wr_n),
        .cpu_m1_n(m1_n), .cpu_inte(cpu_inte),
        .freeze(dbg_freeze), .stuff(dbg_stuff), .feed(dbg_feed),
        .master(dbg_master), .mst_addr(dbg_addr), .mst_wdata(dbg_wdata),
        .mst_rd_n(dbg_rd_n), .mst_wr_n(dbg_wr_n)
    );

    // the fabric the decoder and memories see: the CPU, or — frozen — the
    // debug master, which therefore reads and writes exactly like the CPU
    wire [15:0] f_addr  = dbg_master ? dbg_addr              : addr;
    wire        f_ras_n = dbg_master ? (dbg_rd_n & dbg_wr_n)
                        : dbg_stuff  ? 1'b1                  : ras_n;
    wire        f_rd_n  = dbg_master ? dbg_rd_n
                        : dbg_stuff  ? 1'b1                  : rd_n;
    wire        f_wr_n  = dbg_master ? dbg_wr_n
                        : dbg_stuff  ? 1'b1                  : wr_n;

    // ---- address decoder ----
    wire roma_n, romb_n, ram_n, kybd_n, vid_n, mem_n;
    m1_addr_decode u_dec (
        .a(f_addr[15:10]), .ras_n(f_ras_n), .rd_n(f_rd_n),
        .roma_n(roma_n), .romb_n(romb_n), .ram_n(ram_n),
        .kybd_n(kybd_n), .vid_n(vid_n), .mem_n(mem_n)
    );

    // ---- ROM / RAM ----
    wire [7:0] rom_dout, ram_dout;
    wire       rom_en, ram_en;
    m1_rom u_rom (
        .clk(clk), .a(f_addr[13:0]),
        .roma_n(roma_n), .romb_n(romb_n), .mem_n(mem_n),
        .dout(rom_dout), .dout_en(rom_en),
        .ld_en(ld_en), .ld_addr(ld_addr), .ld_data(ld_data)
    );
    m1_ram u_ram (
        .clk(clk), .a(f_addr[13:0]),
        .ram_n(ram_n), .wr_n(f_wr_n), .mem_n(mem_n),
        .din(bus), .dout(ram_dout), .dout_en(ram_en)
    );

    // ---- Expansion Interface RAM (upper 32K, ADR-0005) ----
    wire [7:0] ei_ram_dout;
    wire       ei_ram_en;
    m1_ei_ram u_ei_ram (
        .clk(clk), .a(f_addr[14:0]), .a15(f_addr[15]),
        .ras_n(f_ras_n), .rd_n(f_rd_n), .wr_n(f_wr_n),
        .cfg(ei_ram_cfg),
        .din(bus), .dout(ei_ram_dout), .dout_en(ei_ram_en)
    );

    // ---- Expansion Interface container: heartbeat, 0x37E0, drive
    //      select, motor one-shot (EI stage 1, ADR-0005). Present in the
    //      32K and 48K configurations; the bare 16K keyboard unit
    //      (ei_ram_cfg == 2'b00) has no EI and therefore none of this.
    wire [7:0] ei_dout;
    wire       ei_dev_en;
    wire [3:0] ei_drive_sel;
    wire       ei_motor_on, ei_en_1m, ei_step, ei_dirc;
    m1_ei u_ei (
        .clk(clk), .rst_n(por_rst_n),
        .en(ei_ram_cfg != 2'b00),
        .a(f_addr), .din(bus), .rd_n(f_rd_n), .wr_n(f_wr_n),
        .dout(ei_dout), .dout_en(ei_dev_en),
        .int_n(ei_int_n),
        .disk(fdc_disk),              // media present (board: drv_mounted)
        .disk_wp(fdc_wp),
        .percom_en(percom_en),
        .trk_req(trk_req), .trk_drv(trk_drv), .trk_track(trk_track),
        .trk_side(trk_side),
        .trk_vld(trk_vld), .trk_data(trk_data), .trk_idx(trk_idx),
        .trk_done(trk_done), .trk_err(trk_err),
        .trk_len(trk_len), .trk_dbl(trk_dbl),
        .trk_wb_req(trk_wb_req), .trk_wb_fetch(trk_wb_fetch),
        .trk_wb_idx(trk_wb_idx), .trk_wb_data(trk_wb_data),
        .trk_wb_done(trk_wb_done), .trk_wb_err(trk_wb_err),
        .drive_sel(ei_drive_sel),
        .motor_on(ei_motor_on),
        .en_1m(ei_en_1m),
        .fdc_step(ei_step),
        .fdc_dirc(ei_dirc)
    );

    // ---- port 0xFF (cassette latch + MODESEL) ----
    wire [7:0] io_dout;
    wire       io_en, outsig_n;
    m1_io u_io (
        .clk(clk), .rst_n(por_rst_n), .a(addr[7:0]),
        .in_n(in_n), .out_n(out_n), .din(bus), .cass_in(cass_in),
        .dout(io_dout), .dout_en(io_en),
        .modesel(modesel), .cass_out(cass_out), .cass_motor(cass_motor),
        .outsig_n(outsig_n),
        /* verilator lint_off PINCONNECTEMPTY */
        .ff_n(), .insig_n()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    // ---- keyboard ----
    wire [7:0] kb_dout;
    wire       kb_en;
    m1_keyboard u_kb (
        .a(f_addr[7:0]), .kybd_n(kybd_n), .keys(keys),
        .dout(kb_dout), .dout_en(kb_en)
    );

    // ---- video timing + video RAM + video generator ----
    wire        latch_n;
    wire [5:0]  vd;
    wire        vd7;
    wire [7:0]  vram_dout;
    wire        vram_en;

    m1_video_timing u_vt (
        .clk(clk), .rst_n(por_rst_n), .modesel(modesel),
        /* verilator lint_off PINCONNECTEMPTY */
        .latch_n(latch_n), .dot_en(dot_en), .chain_en(),
        /* verilator lint_on PINCONNECTEMPTY */
        .col(col), .line(line), .row(row), .hdrv(hdrv), .vdrv(vdrv)
    );

    m1_vram u_vr (
        .clk(clk),
        .col(col[5:0]), .row(row[3:0]),
        .vid_n(vid_n), .rd_n(f_rd_n), .wr_n(f_wr_n),
        .a(f_addr[9:0]), .din(bus[5:0]), .din7(bus[7]),
        .dout(vram_dout), .dout_en(vram_en),
        .vd(vd), .vd7(vd7)
    );

    m1_video_gen #(.FONT_HEX(FONT_HEX)) u_vg (
        .clk(clk), .rst_n(por_rst_n),
        .latch_n(latch_n), .dot_en(dot_en), .line(line),
        .hdrv(hdrv), .vdrv(vdrv),
        .vd(vd), .vd7(vd7), .vid_n(vid_n), .pixel(pixel)
    );

    // ---- the bus mux (one enabled source; open bus = 0xFF). While the
    //      debug core masters the fabric, its write data (or the selected
    //      device) drives the bus instead of the frozen CPU's data buffer.
    wire [7:0] dev_bus = rom_en    ? rom_dout
                       : ram_en    ? ram_dout
                       : ei_ram_en ? ei_ram_dout
                       : ei_dev_en ? ei_dout
                       : vram_en   ? vram_dout
                       : kb_en     ? kb_dout
                       : io_en     ? io_dout
                       :             8'hFF;
    assign bus = dbg_master             ? (!dbg_wr_n ? dbg_wdata : dev_bus)
               : (dbg_stuff && dbout_n)  ? dbg_feed
               : !dbout_n                ? cpu_dout
               :                           dev_bus;

    // status lines the board may leave unread (some are watched only by the
    // testbench, hierarchically); the EI drive/motor/1MHz outputs are
    // consumed by the FDC in EI stage 2
    assign snd = {ei_drive_sel, ei_motor_on, ei_step, ei_dirc};

    wire _unused_ok = &{1'b0, addr_en, dbin_n, intak_n, sysres_n,
                        mux, cas_n, busak_n, outsig_n, ei_en_1m};

endmodule
