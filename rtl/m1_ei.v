// TRS-80 Rev Z — Expansion Interface container (EI stage 1, ADR-0005)
//
// The non-RAM half of the Expansion Interface: interrupt structure, the
// 0x37E0 register, the drive-select latch and the motor one-shot — the
// frame the WD1771 FDC (stage 2) plugs into.
//
// Hardware modeled (EI Service Manual 26-1140, schematic sheet 3):
//   - Z31/Y1: the EI's own 4 MHz oscillator, /4 -> 1 MHz FDC clock, and
//     the Z25-Z27 divider chain -> 25 ms heartbeat. Per ADR-0005 both
//     become ONE phase-accumulator 1 MHz enable in the dot-clock domain
//     (structurally faithful: a single source for FDC timing and RTC).
//   - Z28: the interrupt flip-flop. RTC tick (40 Hz) sets it; reading
//     0x37E0 clears the RTC part and returns the PRE-clear status. The
//     FDC INTRQ input joins here in stage 2 (cleared by 37EC status
//     read, not by 37E0). INT* is level-active while anything pends.
//   - Z36 (74LS175): drive-select latch, write 0x37E0-0x37E3, D0..D3 ->
//     DS0..DS3. Each write retriggers the motor one-shot.
//   - Z29 (74LS123, 200K/33uF ~= 3 s): MOTOR ON one-shot.
//
// 0x37E0 read value (verified against trs80gp 2.5.5, 2026-07-24 — the
// PLAN-EI-FDC open point): {rtc_pending, fdc_intrq, 6'b111111}; the RTC
// latch is SET at power-on (trs80gp does the same; the real FF wakes in
// an undefined state and DOS clears it by reading). Undriven bus bits
// float high on the TRS-80 bus, hence the 6'b111111.
//
// The read decode is exactly 0x37E0; the write (drive-select) decode is
// the 0x37E0-0x37E3 window (Z42/Z43 granularity). 0x37EC-0x37EF are the
// FDC window (m1_fdc, EI stage 2), with m1_drives as the bay behind it.

module m1_ei #(
    parameter [24:0] ACC_K    = 25'd1576139,   // 2^24 / 10.6445: 1 MHz enable
    parameter [14:0] HB_DIV   = 15'd25000,     // 1 MHz / 25000 = 40 Hz
    parameter [21:0] MOTOR_US = 22'd3000000    // ~3 s one-shot (0.45*R*C)
) (
    input  wire        clk,          // dot clock
    input  wire        rst_n,
    input  wire        en,           // EI attached (bare keyboard unit: 0)

    // bus idiom (memory-mapped: the 0x37xx gap)
    input  wire [15:0] a,
    input  wire [7:0]  din,
    input  wire        rd_n,
    input  wire        wr_n,
    output wire [7:0]  dout,
    output wire        dout_en,

    // interrupt structure
    output wire        int_n,        // to the CPU (level, active low)

    // media (board: m1_sd_fs drv_mounted; benches drive it directly)
    input  wire [3:0]  disk,
    input  wire [3:0]  disk_wp,
    input  wire        percom_en,

    // track fetch port (media provider: board DMK fetcher / bench model)
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

    // observability (drive-sound event stream, HANDOFF 3b)
    output reg  [3:0]  drive_sel,    // Z36: DS0..DS3, one-hot by convention
    output wire        motor_on,     // Z29 one-shot output
    output wire        en_1m,        // 1 MHz enable (FDC clock base)
    output wire        fdc_step,     // step pulse toward the drives
    output wire        fdc_dirc
);

    // ------------------------------------------------------------------
    // 1 MHz enable: 24-bit phase accumulator (ADR-0001/0005 idiom)
    // ------------------------------------------------------------------
    reg  [23:0] acc;
    wire [24:0] acc_n = {1'b0, acc} + ACC_K;
    assign en_1m = acc_n[24];

    // ------------------------------------------------------------------
    // Decode
    // ------------------------------------------------------------------
    wire sel_rd  = en && (a == 16'h37E0) && !rd_n;
    wire sel_wr  = en && (a[15:2] == 14'b00110111111000) && !wr_n;
    wire sel_fdc = en && (a[15:2] == 14'b00110111111011);   // 37EC-37EF

    reg  sel_rd_d;                   // trailing-edge detect: the value on
                                     // the bus is the PRE-clear status

    // ------------------------------------------------------------------
    // Heartbeat + interrupt latch
    // ------------------------------------------------------------------
    reg  [14:0] hb_cnt;
    reg         rtc_pending;
    wire        hb_tick = en_1m && (hb_cnt == HB_DIV - 15'd1);

    // ------------------------------------------------------------------
    // Motor one-shot
    // ------------------------------------------------------------------
    reg  [21:0] motor_cnt;
    assign motor_on = (motor_cnt != 22'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc         <= 24'd0;
            hb_cnt      <= 15'd0;
            rtc_pending <= 1'b1;     // power-on state (see header)
            sel_rd_d    <= 1'b0;
            drive_sel   <= 4'd0;
            motor_cnt   <= 22'd0;
        end else begin
            acc <= acc_n[23:0];

            if (en_1m)
                hb_cnt <= (hb_cnt == HB_DIV - 15'd1) ? 15'd0
                                                     : hb_cnt + 15'd1;

            // clear on the trailing edge of the read strobe; a tick that
            // lands on the same cycle wins (no heartbeat is ever lost)
            sel_rd_d <= sel_rd;
            if (hb_tick)
                rtc_pending <= 1'b1;
            else if (sel_rd_d && !sel_rd)
                rtc_pending <= 1'b0;

            // drive-select latch + motor retrigger (level strobe: the
            // data is stable for the whole write cycle)
            if (sel_wr) begin
                drive_sel <= din[3:0];
                motor_cnt <= MOTOR_US;
            end else if (en_1m && motor_cnt != 22'd0)
                motor_cnt <= motor_cnt - 22'd1;
        end
    end

    // ------------------------------------------------------------------
    // FDC (WD1771) + the drive bay behind it (EI stage 2)
    // ------------------------------------------------------------------
    wire       fdc_intrq;
    wire [7:0] fdc_dout;
    wire       fdc_den;
    wire       drv_tr00, drv_ip, drv_wprt, drv_ready;
    wire [1:0] drv_sel_idx;
    wire [6:0] drv_pos_sel;
    wire       drv_side;

    m1_fdc u_fdc (
        .clk(clk), .rst_n(rst_n), .en_1m(en_1m),
        .percom_en(percom_en),
        .sel(sel_fdc), .a(a[1:0]), .din(din), .rd_n(rd_n), .wr_n(wr_n),
        .dout(fdc_dout), .dout_en(fdc_den),
        .intrq(fdc_intrq),
        .step(fdc_step), .dirc(fdc_dirc),
        .tr00(drv_tr00), .ip(drv_ip), .wprt(drv_wprt), .ready(drv_ready),
        .sel_drv(drv_sel_idx), .pos_sel(drv_pos_sel), .sel_side(drv_side),
        .trk_req(trk_req), .trk_drv(trk_drv), .trk_track(trk_track),
        .trk_side(trk_side),
        .trk_vld(trk_vld), .trk_data(trk_data), .trk_idx(trk_idx),
        .trk_done(trk_done), .trk_err(trk_err),
        .trk_len(trk_len), .trk_dbl(trk_dbl),
        .trk_wb_req(trk_wb_req), .trk_wb_fetch(trk_wb_fetch),
        .trk_wb_idx(trk_wb_idx), .trk_wb_data(trk_wb_data),
        .trk_wb_done(trk_wb_done), .trk_wb_err(trk_wb_err)
    );

    m1_drives u_drives (
        .clk(clk), .rst_n(rst_n), .en_1m(en_1m),
        .ds(drive_sel), .motor_on(motor_on), .disk(disk),
        .disk_wp(disk_wp),
        .step(fdc_step), .dirc(fdc_dirc),
        .tr00(drv_tr00), .ip(drv_ip), .wprt(drv_wprt), .ready(drv_ready),
        .sel_idx(drv_sel_idx), .pos_sel(drv_pos_sel), .side(drv_side)
    );

    assign int_n   = ~(en && (rtc_pending || fdc_intrq));
    assign dout    = fdc_den ? fdc_dout
                             : {rtc_pending, fdc_intrq, 6'b111111};
    assign dout_en = sel_rd | fdc_den;

    // Z36 is a 4-bit latch; D4-D7 are simply not connected on the EI
    wire _unused_ok = &{1'b0, din[7:4]};

endmodule
