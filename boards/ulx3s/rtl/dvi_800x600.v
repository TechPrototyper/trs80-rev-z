// TRS-80 Rev Z — 800x600@60 display timing and 2x3 scaler
//
// Reads the 384x192 capture framebuffer and presents it as a standard
// 800x600@60 (VESA, 40.000 MHz pixel clock) frame: each TRS-80 dot becomes
// 2 pixels wide and 3 lines tall — 768x576 centered with 16/12-pixel
// borders. The 2:3 dot cell reproduces the original tube's geometry: 384
// dots span a 4:3 width and 192 lines its height, so a dot is 1.5x taller
// than wide. Exactly VESA 800x600: hsync/vsync positive polarity,
// 40+128+88 / 1+4+23 blanking.
//
// The framebuffer read is registered (one clk_pix), so the control strip
// (de/hs/vs/window) runs one stage behind the counters to stay aligned.

module dvi_800x600 (
    input  wire        clk_pix,     // 40 MHz
    output wire [16:0] rd_addr,     // to m1_scan_fb
    input  wire        rd_bit,      // registered, arrives one cycle later

    output reg         de,          // aligned with pix
    output reg         hs,
    output reg         vs,
    output wire        pix          // 1 = white TRS-80 dot
);

    localparam H_VIS = 800, H_TOT = 1056, HS_BEG = 840, HS_END = 968;
    localparam V_VIS = 600, V_TOT = 628,  VS_BEG = 601, VS_END = 605;
    localparam WIN_X0 = 16,  WIN_X1 = 784;   // 768 wide
    localparam WIN_Y0 = 12,  WIN_Y1 = 588;   // 576 tall

    reg [10:0] hcnt = 11'd0;
    reg [9:0]  vcnt = 10'd0;

    // vertical 1/3 scaler: src_y advances every third window line
    reg [1:0] y3    = 2'd0;
    reg [7:0] src_y = 8'd0;

    always @(posedge clk_pix) begin
        if (hcnt == H_TOT-1) begin
            hcnt <= 11'd0;
            vcnt <= (vcnt == V_TOT-1) ? 10'd0 : vcnt + 10'd1;

            // update the vertical scaler for the line about to start
            if (vcnt + 10'd1 == WIN_Y0[9:0]) begin
                y3 <= 2'd0; src_y <= 8'd0;
            end else if (vcnt + 10'd1 > WIN_Y0[9:0] && vcnt + 10'd1 < WIN_Y1[9:0]) begin
                if (y3 == 2'd2) begin
                    y3 <= 2'd0; src_y <= src_y + 8'd1;
                end else
                    y3 <= y3 + 2'd1;
            end
        end else
            hcnt <= hcnt + 11'd1;
    end

    // horizontal 1/2 scaler + read address (combinational off the counters)
    wire        in_win = (hcnt >= WIN_X0) && (hcnt < WIN_X1)
                      && (vcnt >= WIN_Y0) && (vcnt < WIN_Y1);
    wire [9:0]  wx     = hcnt[9:0] - WIN_X0[9:0];
    wire [8:0]  src_x  = wx[9:1];
    assign rd_addr = {1'd0, src_y, 8'd0} + {2'd0, src_y, 7'd0}   // src_y*(256+128)
                   + {8'd0, src_x};

    // control strip, one stage behind to meet the registered read
    reg win_d = 1'b0;
    always @(posedge clk_pix) begin
        de    <= (hcnt < H_VIS) && (vcnt < V_VIS);
        hs    <= (hcnt >= HS_BEG) && (hcnt < HS_END);
        vs    <= (vcnt >= VS_BEG) && (vcnt < VS_END);
        win_d <= in_win;
    end

    assign pix = win_d & rd_bit;        // both one stage behind the counters

endmodule
