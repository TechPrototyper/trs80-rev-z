// TRS-80 Rev Z — ULX3S board top-level (skeleton, milestone M1)
//
// The first hardware wrapper around `m1_core`. This skeleton proves the
// machine builds, places, routes and closes timing as a *board* bitstream
// (real pins, real PLL) and gives the bring-up a heartbeat on the LEDs.
// It is deliberately minimal; the next stages grow onto the marked seams:
//
//   - ROM loader:  two stages on the same ld_* seam. At power-on,
//                  m1_selftest_loader streams the repository's own
//                  golden-verified test image into the ROM (machine held
//                  in reset until done) — the card-less fallback shows
//                  "TRS-80 REV Z  OK". In parallel, m1_sd_fs mounts
//                  the FAT32 SD card; if TRS80/LEVEL2.ROM exists, the
//                  machine is put back into reset, the ROM is re-loaded
//                  from the card, and Level II BASIC comes up. No card /
//                  no file: the self-test stays (led[2] tells which).
//                  Afterwards it mounts TRS80/DRIVE0..3/ disk images and
//                  serves their sectors — the seam the FDC will use.
//   - keyboard:    a USB keyboard on the US2 port drives the matrix:
//                  vendored usb_hid_host (ADR-0004, 12 MHz from the DVI
//                  PLL) -> m1_hid_keys (glyph-faithful HID->matrix map,
//                  2-FF CDC) -> m1_core.keys. Host-side 15K pull-downs
//                  come from the usb_fpga_pu_* pins driven low.
//   - video:       the authentic pixel stream is captured into a dual-clock
//                  framebuffer (m1_scan_fb) and shown as 800x600@60 DVI on
//                  the GPDI port — 2x3 scaling, the original tube geometry.
//   - cassette:    cass_in tied low; cass_out/motor unused (M2).
//
// Board facts (ULX3S v2.x/v3.x): 25 MHz oscillator on G2; eight LEDs;
// btn[0] is the PWR button (pull-up, pressed = 0) — left alone; btn[1]
// (FIRE1, pull-down, pressed = 1) is our reset. PLL: 25 MHz -> 10.6443 MHz
// (ecppll, 19 ppm below the 10.6445 MHz dot clock — well inside the
// original crystal's tolerance).

module ulx3s_top (
    input  wire       clk_25mhz,
    input  wire [6:0] btn,
    input  wire [3:0] sw,        // DIP switches (memory configuration)
    output wire [7:0] led,
    output wire [3:0] gpdi_dp,

    // US2 USB host port (keyboard)
    inout  wire       usb_fpga_bd_dp,
    inout  wire       usb_fpga_bd_dn,
    output wire       usb_fpga_pu_dp,   // pull resistor controls:
    output wire       usb_fpga_pu_dn,   // both low = host-side 15K pull-downs

    // micro-SD socket, SPI mode (ROM loader). Named per SPI role; the
    // LPF maps them onto the sd_d[3:0] pads (MISO = DAT0, CS# = DAT3).
    // No tristates: DAT1/DAT2 are meaningless in SPI mode and are driven
    // high (the pull-up polarity), which keeps abc9 off tribuf nets.
    output wire       sd_clk,
    output wire       sd_cmd,           // MOSI
    input  wire       sd_miso,          // DAT0
    output wire       sd_csn,           // DAT3
    output wire       sd_d1,
    output wire       sd_d2,

    // The SD lines are shared with the ESP32 (WiFi GPIOs). Holding the
    // ESP32 in reset gives this bitstream deterministic ownership of the
    // card; the ESP32 companion returns with its own ADR (post-M3).
    output wire       wifi_en,

    // FTDI serial: the debug host link (ADR-0006 D1) — JSON-RPC bridge
    // on the PC, binary protocol v0 on this wire
    input  wire       ftdi_rxd,   // host transmits
    output wire       ftdi_txd    // host receives
);

    // ------------------------------------------------------------------
    // Clock: 25 MHz -> 10.6443 MHz dot clock (rtl/m1_pll.v, ecppll)
    // ------------------------------------------------------------------
    wire clk, pll_locked;
    m1_pll u_pll (.clkin(clk_25mhz), .clkout0(clk), .locked(pll_locked));

    // ------------------------------------------------------------------
    // Power-on reset: hold the core in reset until the PLL locks and a
    // few hundred dot clocks have passed.
    // ------------------------------------------------------------------
    // The two buttons of a real Model 1, mapped onto FIRE1/FIRE2:
    //   FIRE1 = RESET  (back-left on the keyboard case): warm reset of
    //           the machine only — loaders/mounts survive.
    //   FIRE2 = POWER  (back-right): a cold start. Holding it pulls the
    //           power-on reset, releasing it re-runs everything — the
    //           self-test, the SD init (with retries), the ROM load and
    //           the drive mounts. Also the way to pick up a card that
    //           was inserted after power-up.
    reg [1:0] btn2_sync = 2'b00;
    always @(posedge clk) btn2_sync <= {btn2_sync[0], btn[2]};

    reg [7:0] por_cnt = 8'd0;
    wire      por_rst_n = &por_cnt;

    always @(posedge clk or negedge pll_locked) begin
        if (!pll_locked)         por_cnt <= 8'd0;
        else if (btn2_sync[1])   por_cnt <= 8'd0;    // POWER pressed
        else if (!por_rst_n)     por_cnt <= por_cnt + 8'd1;
    end

    // A second power-on reset for the DEBUG subsystem: true FPGA power
    // only, NOT the POWER button. FIRE2 resets the machine (por_rst_n)
    // but leaves the debugger standing, so a cold start looks to the
    // debug core exactly like a real TRS-80 pressing its own reset —
    // it observes and reports it instead of dying with the machine
    // (ADR-0006 §3a). This is the FPGA rehearsal of the ribbon-cable case.
    reg [7:0] dbg_por_cnt = 8'd0;
    wire      dbg_por_rst_n = &dbg_por_cnt;
    always @(posedge clk or negedge pll_locked) begin
        if (!pll_locked)             dbg_por_cnt <= 8'd0;
        else if (!dbg_por_rst_n)     dbg_por_cnt <= dbg_por_cnt + 8'd1;
    end

    // FIRE1 (pressed = 1) acts as the front-panel reset button (active low
    // into the core), synchronized into the dot-clock domain.
    reg [1:0] btn1_sync = 2'b00;
    always @(posedge clk) btn1_sync <= {btn1_sync[0], btn[1]};
    wire reset_btn_n = ~btn1_sync[1];

    // ------------------------------------------------------------------
    // USB keyboard: vendored HID host (usbclk domain) -> matrix bits.
    // ------------------------------------------------------------------
    assign usb_fpga_pu_dp = 1'b0;   // host mode: 15K pull-downs on D+/D-
    assign usb_fpga_pu_dn = 1'b0;

    wire [1:0] usb_typ;
    wire       usb_report, usb_conerr;
    wire [7:0] usb_mod, usb_k1, usb_k2, usb_k3, usb_k4;

    usb_hid_host u_usb (
        .usbclk        (clk_usb),
        .usbrst_n      (pll_dvi_locked),
        .usb_dm        (usb_fpga_bd_dn),
        .usb_dp        (usb_fpga_bd_dp),
        .typ           (usb_typ),
        .report        (usb_report),
        .conerr        (usb_conerr),
        .key_modifiers (usb_mod),
        .key1(usb_k1), .key2(usb_k2), .key3(usb_k3), .key4(usb_k4),
        /* unused device classes */
        .mouse_btn(), .mouse_dx(), .mouse_dy(),
        .game_l(), .game_r(), .game_u(), .game_d(),
        .game_a(), .game_b(), .game_x(), .game_y(),
        .game_sel(), .game_sta(),
        .dbg_hid_report()
    );

    wire [63:0] keys;
    m1_hid_keys u_keys (
        .usbclk        (clk_usb),
        .usbrst_n      (pll_dvi_locked),
        .typ           (usb_typ),
        .report        (usb_report),
        .key_modifiers (usb_mod),
        .key1(usb_k1), .key2(usb_k2), .key3(usb_k3), .key4(usb_k4),
        .clk_dot       (clk),
        .keys          (keys)
    );

    // ------------------------------------------------------------------
    // ROM loading, two stages on one seam:
    //   1. bring-up self-test — our own test image, machine in reset
    //      until the last byte is written (card-less fallback);
    //   2. SD loader — mounts the FAT32 card in parallel, and once the
    //      self-test released the machine (ld_gate) re-loads the ROM
    //      with TRS80/LEVEL2.ROM behind a second reset.
    // ------------------------------------------------------------------
    wire        st_en, st_done;
    wire [13:0] st_addr;
    wire [7:0]  st_data;

    m1_selftest_loader u_loader (
        .clk     (clk),
        .rst_n   (por_rst_n),
        .ld_en   (st_en),
        .ld_addr (st_addr),
        .ld_data (st_data),
        .done    (st_done)
    );

    assign wifi_en = 1'b0;              // ESP32 in reset: SD bus is ours

    assign sd_d1 = 1'b1;                // unused in SPI mode: park high
    assign sd_d2 = 1'b1;

    wire        sd_en, sd_loading, sd_sys_ready, sd_ok, sd_err, sd_init_err;
    wire [13:0] sd_addr;
    wire [7:0]  sd_data;
    wire [3:0]  drv_mounted;

    m1_sd_fs u_sd_fs (
        .clk     (clk),
        .rst_n   (por_rst_n),
        .sd_sck  (sd_clk),
        .sd_mosi (sd_cmd),
        .sd_miso (sd_miso),
        .sd_cs_n (sd_csn),
        .ld_gate (st_done),
        .ld_en   (sd_en),
        .ld_addr (sd_addr),
        .ld_data (sd_data),
        .loading (sd_loading),
        .sys_ready(sd_sys_ready),
        .ok      (sd_ok),
        .err     (sd_err),
        .init_err(sd_init_err),
        // drive mounts + sector server: the mount mask feeds the drive
        // bay (media present), the sector port feeds the DMK fetcher
        .rq_req  (rq_req),
        .rq_drv  (rq_drv),
        .rq_fsec (rq_fsec),
        .drv_mounted (drv_mounted),
        .fs_ready    (fs_ready),
        .rq_vld(rq_vld), .rq_dat(rq_dat), .rq_idx(rq_idx),
        .rq_done(rq_done), .rq_err(rq_err),
        // sector-write port: the fetcher's dirty-track write-back
        .wq_req(wq_req), .wq_drv(wq_drv), .wq_fsec(wq_fsec),
        .wq_fetch(wq_fetch), .wq_idx(wq_idx), .wq_dat(wq_dat),
        .wq_done(wq_done), .wq_err(wq_err)
    );

    // ------------------------------------------------------------------
    // DMK track fetcher: serves the FDC's track buffer from the card
    // (EI stage 3). One raw DMK track per request, header-checked.
    // ------------------------------------------------------------------
    wire        fs_ready, rq_req, rq_vld, rq_done, rq_err;
    wire [1:0]  rq_drv;
    wire [12:0] rq_fsec;
    wire [7:0]  rq_dat;
    wire [8:0]  rq_idx;

    wire        trk_req, trk_vld, trk_done, trk_err, trk_dbl;
    wire [1:0]  trk_drv;
    wire [6:0]  trk_track;
    wire [7:0]  trk_data;
    wire [12:0] trk_idx, trk_len;
    wire        wq_req, wq_fetch, wq_done, wq_err;
    wire [1:0]  wq_drv;
    wire [12:0] wq_fsec;
    wire [8:0]  wq_idx;
    wire [7:0]  wq_dat;
    wire        trk_wb_req, trk_wb_fetch, trk_wb_done, trk_wb_err;
    wire [12:0] trk_wb_idx;
    wire [7:0]  trk_wb_data;
    wire [3:0]  drv_wp;

    m1_dmk_fetch u_dmk (
        .clk(clk), .rst_n(por_rst_n),
        .fs_ready(fs_ready), .drv_mounted(drv_mounted),
        .rq_req(rq_req), .rq_drv(rq_drv), .rq_fsec(rq_fsec),
        .rq_vld(rq_vld), .rq_dat(rq_dat), .rq_idx(rq_idx),
        .rq_done(rq_done), .rq_err(rq_err),
        .wq_req(wq_req), .wq_drv(wq_drv), .wq_fsec(wq_fsec),
        .wq_fetch(wq_fetch), .wq_idx(wq_idx), .wq_dat(wq_dat),
        .wq_done(wq_done), .wq_err(wq_err),
        .trk_req(trk_req), .trk_drv(trk_drv), .trk_track(trk_track),
        .trk_vld(trk_vld), .trk_data(trk_data), .trk_idx(trk_idx),
        .trk_done(trk_done), .trk_err(trk_err),
        .trk_len(trk_len), .trk_dbl(trk_dbl), .drv_wp(drv_wp),
        .trk_wb_req(trk_wb_req), .trk_wb_fetch(trk_wb_fetch),
        .trk_wb_idx(trk_wb_idx), .trk_wb_data(trk_wb_data),
        .trk_wb_done(trk_wb_done), .trk_wb_err(trk_wb_err)
    );

    // the seam m1_rom sees: self-test first, SD re-load afterwards
    wire        ld_en   = sd_loading ? sd_en   : st_en;
    wire [13:0] ld_addr = sd_loading ? sd_addr : st_addr;
    wire [7:0]  ld_data = sd_loading ? sd_data : st_data;

    // the machine leaves reset exactly once, when the whole boot
    // (self-test image + SD ROM phase + drive mounts) is done — no
    // run-then-reset glitch for the debug core to mistake for a
    // target reset (ADR-0006 §3a)
    wire core_rst_n = por_rst_n & sd_sys_ready;

    // ------------------------------------------------------------------
    // The machine.
    // ------------------------------------------------------------------
    wire        pixel, hdrv, vdrv, dot_en, modesel;
    wire [6:0]  col;
    wire [3:0]  line;
    wire [4:0]  row;
    wire [1:0]  cass_out;
    wire        cass_motor;
    wire [15:0] addr;
    wire        m1_n, halt_n, cpu_cen;

    // Memory configuration (ADR-0005): both DIP switches OFF = the full
    // 48K machine; SW2 on = 32K system; SW1 on = bare 16K keyboard unit.
    wire [1:0] ei_ram_cfg = sw[0] ? 2'b00
                          : sw[1] ? 2'b01
                          :         2'b10;

    // ---- debug host link over the FTDI UART (ADR-0006 D1) ----
    wire       dbg_cmd_valid, dbg_cmd_ready, dbg_rsp_valid, dbg_rsp_ready;
    wire [7:0] dbg_cmd_data, dbg_rsp_data;
    dbg_uart u_dbg_uart (
        .clk(clk), .rst_n(dbg_por_rst_n),
        .uart_rx(ftdi_rxd), .uart_tx(ftdi_txd),
        .cmd_valid(dbg_cmd_valid), .cmd_data(dbg_cmd_data),
        .cmd_ready(dbg_cmd_ready),
        .rsp_valid(dbg_rsp_valid), .rsp_data(dbg_rsp_data),
        .rsp_ready(dbg_rsp_ready)
    );

    m1_core u_core (
        .clk         (clk),
        .por_rst_n   (core_rst_n),    // held until the self-test image is in
        .dbg_rst_n   (dbg_por_rst_n), // debugger survives machine resets
        .reset_btn_n (reset_btn_n),
        .test_n      (1'b1),
        .int_n       (1'b1),
        .wait_n      (1'b1),

        .ld_en       (ld_en),         // same seam the SD/ESP32 loader will use
        .ld_addr     (ld_addr),
        .ld_data     (ld_data),

        .ei_ram_cfg  (ei_ram_cfg),    // EI RAM population (ADR-0005)
        .fdc_disk    (drv_mounted),   // media = mounted DMKs from the card
        .fdc_wp      (drv_wp),        // WP straight from the DMK headers
        .percom_en   (~sw[3]),        // DIP4 OFF = Doubler fitted
        .trk_req(trk_req), .trk_drv(trk_drv), .trk_track(trk_track),
        .trk_vld(trk_vld), .trk_data(trk_data), .trk_idx(trk_idx),
        .trk_done(trk_done), .trk_err(trk_err),
        .trk_len(trk_len), .trk_dbl(trk_dbl),
        .trk_wb_req(trk_wb_req), .trk_wb_fetch(trk_wb_fetch),
        .trk_wb_idx(trk_wb_idx), .trk_wb_data(trk_wb_data),
        .trk_wb_done(trk_wb_done), .trk_wb_err(trk_wb_err),

        .dbg_in_valid(dbg_cmd_valid), .dbg_in_data(dbg_cmd_data),
        .dbg_in_ready(dbg_cmd_ready),
        .dbg_out_valid(dbg_rsp_valid), .dbg_out_data(dbg_rsp_data),
        .dbg_out_ready(dbg_rsp_ready),
        .keys        (keys),          // USB-HID front end (ADR-0004)

        .cass_in     (1'b0),
        .cass_out    (cass_out),
        .cass_motor  (cass_motor),

        .pixel       (pixel),
        .hdrv        (hdrv),
        .vdrv        (vdrv),
        .dot_en      (dot_en),
        .modesel     (modesel),
        .col         (col),
        .line        (line),
        .row         (row),

        .addr        (addr),
        .m1_n        (m1_n),
        .halt_n      (halt_n),
        .cpu_cen     (cpu_cen)
    );

    // ------------------------------------------------------------------
    // Video: capture the authentic pixel stream, show it as 800x600 DVI.
    // Second clock domain pair (40 MHz pixel / 200 MHz TMDS shift) — the
    // machine itself stays single-domain (ADR-0001); the display is a
    // consumer behind the framebuffer.
    // ------------------------------------------------------------------
    wire clk_shift, clk_pixel, clk_usb, pll_dvi_locked;
    m1_pll_dvi u_pll_dvi (.clkin(clk_25mhz), .clk_shift(clk_shift),
                          .clk_pixel(clk_pixel), .clk_usb(clk_usb),
                          .locked(pll_dvi_locked));

    wire [16:0] rd_addr;
    wire        rd_bit;

    m1_scan_fb u_fb (
        .clk_dot (clk),
        .pixel   (pixel),
        .col     (col),
        .line    (line),
        .row     (row),
        .clk_pix (clk_pixel),
        .rd_addr (rd_addr),
        .rd_bit  (rd_bit)
    );

    wire de, hs, vs, pix;
    dvi_800x600 u_disp (
        .clk_pix (clk_pixel),
        .rd_addr (rd_addr),
        .rd_bit  (rd_bit),
        .de      (de),
        .hs      (hs),
        .vs      (vs),
        .pix     (pix)
    );

    wire [7:0] lum = pix ? 8'hFF : 8'h00;   // white on black, like the tube
    wire [9:0] tm_b, tm_g, tm_r;

    tmds_encoder u_tm_b (.clk(clk_pixel), .de(de), .ctrl({vs, hs}), .din(lum), .q_out(tm_b));
    tmds_encoder u_tm_g (.clk(clk_pixel), .de(de), .ctrl(2'b00),    .din(lum), .q_out(tm_g));
    tmds_encoder u_tm_r (.clk(clk_pixel), .de(de), .ctrl(2'b00),    .din(lum), .q_out(tm_r));

    dvi_serializer u_ser (
        .clk_shift (clk_shift),
        .clk_pixel (clk_pixel),
        .d_blue    (tm_b),
        .d_green   (tm_g),
        .d_red     (tm_r),
        .gpdi_dp   (gpdi_dp)
    );

    // ------------------------------------------------------------------
    // Heartbeat + SD diagnosis: prove the machine is alive without a
    // display, and say WHY a card did not come up.
    //   led[7]   frame beat  (VDRV divided — ~1 Hz-ish blink)
    //   led[6]   drive 0 mounted (a DMK found in TRS80/DRIVE0/)
    //   led[5]   filesystem ready (mount phase finished)
    //   led[4]   CARD init failed (SPI level: insertion/contact/
    //            compatibility — the card never answered)
    //   led[3]   loader error (card answered, but no FAT32 / no
    //            TRS80/LEVEL2.ROM — e.g. an exFAT-formatted card)
    //   led[2]   SD ROM loaded (on = Level II from card; off = self-test
    //            fallback)
    //   led[1]   halt_n (should stay high: NOP sled never halts)
    //   led[0]   PLL locked
    // ------------------------------------------------------------------
    reg [5:0] frame_cnt = 6'd0;
    reg       vdrv_d    = 1'b0;
    always @(posedge clk) begin
        vdrv_d <= vdrv;
        if (vdrv & ~vdrv_d)
            frame_cnt <= frame_cnt + 6'd1;
    end

    reg [15:0] px_stretch = 16'd0;
    always @(posedge clk)
        px_stretch <= pixel ? 16'hFFFF : {px_stretch[14:0], 1'b0};

    assign led = {frame_cnt[5], drv_mounted[0], fs_ready, sd_init_err,
                  sd_err, sd_ok, halt_n, pll_locked};

endmodule
