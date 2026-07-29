// TRS-80 Rev Z — bring-up self-test loader
//
// Plays the ROM loader port after power-on: streams this repository's OWN
// test image (sim/tools/build_test_image.py — the golden-verified program,
// never a Tandy ROM) into m1_rom, holding the machine in reset until the
// last byte is in. First flash shows "TRS-80 REV Z  OK" on the monitor with
// no SD card or ESP32 attached — the whole verified chain, on hardware.
//
// This is bring-up equipment, not the ROM story: the SD/ESP32 loader will
// drive the same ld_* port; ROM policy (roms/README.md) is untouched. The
// image lands in an EBR at synthesis time because it is repository code —
// the policy forbids bundling *Tandy's* masks, not our own program.

module m1_selftest_loader #(
    parameter IMG_HEX = "../../sim/build/testimg.hex",
    parameter IMG_LEN = 4096
) (
    input  wire        clk,        // dot clock
    input  wire        rst_n,      // board power-on reset

    output reg         ld_en,
    output reg  [13:0] ld_addr,
    output wire [7:0]  ld_data,
    output reg         done        // high once the image is loaded
);

    reg [7:0] img [0:IMG_LEN-1];
    initial $readmemh(IMG_HEX, img);

    // cnt runs 0 .. IMG_LEN; byte (cnt-1) is presented while cnt counts.
    // ld_addr and rdata are registered off the SAME index at the SAME edge,
    // so the pair m1_rom samples is always consistent; the read register
    // keeps the image array inferable as EBR (same idiom as m1_rom).
    reg  [12:0] cnt;
    wire [12:0] idx = cnt - 13'd1;

    reg [7:0] rdata;
    always @(posedge clk) rdata <= img[idx[11:0]];
    assign ld_data = rdata;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt     <= 13'd0;
            ld_addr <= 14'd0;
            ld_en   <= 1'b0;
            done    <= 1'b0;
        end else if (!done) begin
            if (cnt != 13'd0) begin
                ld_en   <= 1'b1;
                ld_addr <= {1'b0, idx};
            end
            // done one count AFTER the last index was presented, so the
            // write of byte IMG_LEN-1 completes with ld_en still high.
            if (cnt == 13'(IMG_LEN + 1)) begin
                done  <= 1'b1;
                ld_en <= 1'b0;
            end else
                cnt <= cnt + 13'd1;
        end else
            ld_en <= 1'b0;
    end

endmodule
