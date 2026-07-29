// TRS-80 Rev Z — the drive bay: four virtual mini-floppy drives (EI stage 2)
//
// The physical-drive half of the Shugart interface: per-drive head
// positions moved by STEP/DIRC, TRACK 0 and INDEX for the selected
// drive, and the READY composition. The "disk in the drive" input comes
// from whoever owns the media — on the board that is m1_sd_fs's
// drv_mounted (a DMK per TRS80/DRIVEn/); benches drive it directly.
//
// Facts mirrored from trs80gp probing (2026-07-24): ready is immediate
// (no spin-up modelled) whenever a selected drive holds a disk and the
// motor line is on; write protect is 0 for now (the DMK header WP bit
// joins in stage 3 with the media layer). Index: 300 rpm -> one pulse
// every 200 ms while the selected disk spins. Nothing timing-critical
// reads INDEX in the stage-2 goldens (the tags mask it) — it exists so
// the bit behaves plausibly and stage 3 can hang rotation off it.
//
// The step/dirc/select/motor events at this boundary are also exactly
// the event stream a drive-sound emulator wants (HANDOFF note 3b).

module m1_drives #(
    parameter [17:0] INDEX_PERIOD_US = 18'd200000,   // 300 rpm
    parameter [17:0] INDEX_PULSE_US  = 18'd2000,
    parameter [6:0]  MAX_TRACK       = 7'd84         // stepper end stop
) (
    input  wire       clk,          // dot clock
    input  wire       rst_n,
    input  wire       en_1m,        // 1 MHz enable

    input  wire [3:0] ds,           // drive select (Z36 latch, one-hot)
    input  wire       motor_on,
    input  wire [3:0] disk,         // media present per drive
    input  wire [3:0] disk_wp,      // write-protect per drive (DMK header)

    input  wire       step,         // one-clk pulse from the FDC
    input  wire       dirc,         // 1 = toward higher tracks

    output wire       tr00,
    output wire       ip,
    output wire       wprt,
    output wire       ready,
    output wire [1:0] sel_idx,      // selected drive index (FDC track fetch)
    output wire [6:0] pos_sel       // its head position
);

    // selected drive: lowest set select line wins (one-hot by convention)
    wire       any_sel = |ds;
    wire [1:0] seli = ds[0] ? 2'd0 : ds[1] ? 2'd1 : ds[2] ? 2'd2 : 2'd3;
    assign sel_idx = seli;
    assign pos_sel = pos[seli];

    reg [6:0] pos [0:3];
    reg [17:0] rot_us;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pos[0] <= 7'd0;
            pos[1] <= 7'd0;
            pos[2] <= 7'd0;
            pos[3] <= 7'd0;
            rot_us <= 18'd0;
        end else begin
            if (step && any_sel) begin
                if (dirc) begin
                    if (pos[seli] != MAX_TRACK)
                        pos[seli] <= pos[seli] + 7'd1;
                end else begin
                    if (pos[seli] != 7'd0)
                        pos[seli] <= pos[seli] - 7'd1;
                end
            end
            // rotation clock for the index pulse train
            if (en_1m) begin
                if (motor_on && any_sel && disk[seli])
                    rot_us <= (rot_us == INDEX_PERIOD_US - 18'd1)
                              ? 18'd0 : rot_us + 18'd1;
                else
                    rot_us <= 18'd0;
            end
        end
    end

    assign tr00  = any_sel && (pos[seli] == 7'd0);
    assign ip    = motor_on && any_sel && disk[seli]
                   && (rot_us < INDEX_PULSE_US);
    assign wprt  = any_sel && disk_wp[seli];
    assign ready = any_sel && disk[seli] && motor_on;

endmodule
