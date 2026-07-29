// TRS-80 Rev Z — DVI output serializer (ECP5, GPDI pseudo-differential)
//
// Serializes three 10-bit TMDS words plus the pixel-rate clock pattern onto
// the ULX3S GPDI pins: 10 bits per pixel, 2 bits per clk_shift cycle through
// ODDRX1F DDR output registers (clk_shift = 5 x clk_pixel, same PLL). The
// load strobe is derived from a pixel-domain toggle observed in the shift
// domain, so the 5-cycle phase locks to the pixel clock deterministically.
//
// ECP5 vendor primitives (ODDRX1F) live only here — this module is synthesis
// territory and stays out of the Verilator testbenches; everything upstream
// of it is plain Verilog and simulated.
//
// Pin order (ULX3S GPDI): gpdi_dp[0] blue, [1] green, [2] red, [3] clock.
// LVCMOS33D drives the complementary pad automatically.

module dvi_serializer (
    input  wire       clk_shift,   // 200 MHz
    input  wire       clk_pixel,   // 40 MHz
    input  wire [9:0] d_blue,
    input  wire [9:0] d_green,
    input  wire [9:0] d_red,
    output wire [3:0] gpdi_dp
);

    // pixel-domain toggle -> shift-domain load strobe (once per pixel)
    reg tgl_pix = 1'b0;
    always @(posedge clk_pixel) tgl_pix <= ~tgl_pix;

    reg [2:0] tgl_s = 3'b000;
    always @(posedge clk_shift) tgl_s <= {tgl_s[1:0], tgl_pix};
    wire load = tgl_s[2] ^ tgl_s[1];

    // 10-bit shift registers, two bits out per cycle, LSB first
    reg [9:0] sr_b = 10'd0, sr_g = 10'd0, sr_r = 10'd0, sr_c = 10'd0;

    always @(posedge clk_shift) begin
        sr_b <= load ? d_blue          : {2'b00, sr_b[9:2]};
        sr_g <= load ? d_green         : {2'b00, sr_g[9:2]};
        sr_r <= load ? d_red           : {2'b00, sr_r[9:2]};
        sr_c <= load ? 10'b0000011111  : {2'b00, sr_c[9:2]};
    end

    ODDRX1F ser_b (.SCLK(clk_shift), .RST(1'b0), .D0(sr_b[0]), .D1(sr_b[1]), .Q(gpdi_dp[0]));
    ODDRX1F ser_g (.SCLK(clk_shift), .RST(1'b0), .D0(sr_g[0]), .D1(sr_g[1]), .Q(gpdi_dp[1]));
    ODDRX1F ser_r (.SCLK(clk_shift), .RST(1'b0), .D0(sr_r[0]), .D1(sr_r[1]), .Q(gpdi_dp[2]));
    ODDRX1F ser_c (.SCLK(clk_shift), .RST(1'b0), .D0(sr_c[0]), .D1(sr_c[1]), .Q(gpdi_dp[3]));

endmodule
