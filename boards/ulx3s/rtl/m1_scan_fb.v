// TRS-80 Rev Z — screen capture framebuffer (dot domain -> pixel domain)
//
// The bridge between the machine's authentic video chain and a modern
// display. The write side samples `pixel` in the 10.6443 MHz dot domain and
// places it exactly the way the verified chapter-8 testbench places dots
// when it dumps `frame_cpu.pgm`:
//
//     x = (col - 2) * 6 + dot_in_cell      (the shift path lags the column
//     y = row * 12 + line                   counter by two character cells)
//
// so the framebuffer holds the 384x192 screen precisely as the pipeline
// produced it — snow streaks, mode quirks and all. No re-rendering from
// VRAM: what the original latch/shift chain emits is what gets shown.
// The proof is a byte-diff of a captured frame against the testbench's
// `frame_cpu.pgm` (tb_scan_fb).
//
// The read side is a registered single-bit read in the display's pixel
// clock domain — the memory infers dual-clock EBR. A torn read during a
// write to the same cell shows one stale dot for one frame: the same class
// of transient the real machine's arbitration produces, and invisible.
//
// 32-char mode: the machine pins col[0] low and stretches dot_en; the
// capture keeps counting dot positions per column change, which reproduces
// what the testbench does (each stored dot pair lands in the cell). Golden
// coverage for 32-char capture rides on the same diff.

module m1_scan_fb (
    // write side — dot clock, straight off m1_core
    input  wire        clk_dot,
    input  wire        pixel,
    input  wire [6:0]  col,
    input  wire [3:0]  line,
    input  wire [4:0]  row,

    // read side — display pixel clock
    input  wire        clk_pix,
    input  wire [16:0] rd_addr,   // y*384 + x
    output reg         rd_bit
);

    reg fb [0:73727];             // 384 x 192, 1 bpp

    // dot position inside the character cell, testbench semantics:
    // index 0 the sample where `col` changes, +1 each dot after.
    reg  [6:0] prev_col;
    reg  [2:0] dot;               // next index if the column does not change
    initial begin prev_col = 7'h7F; dot = 3'd0; end   // power-up state
    wire       cell_start = (col != prev_col);
    wire [2:0] dot_now  = cell_start ? 3'd0 : dot;

    wire [6:0] a2      = col - 7'd2;
    wire       visible = (col >= 7'd2) && (col <= 7'd65)
                         && (row < 5'd16) && (dot_now < 3'd6);

    wire [7:0]  y     = {3'd0, row} * 8'd12 + {4'd0, line};
    wire [8:0]  x     = {2'd0, a2} * 9'd6 + {6'd0, dot_now};
    wire [16:0] waddr = {1'd0, y, 8'd0} + {2'd0, y, 7'd0} + {8'd0, x}; // y*(256+128) + x

    always @(posedge clk_dot) begin
        prev_col <= col;
        dot      <= (dot_now == 3'd7) ? 3'd7 : dot_now + 3'd1;
        if (visible)
            fb[waddr] <= pixel;
    end

    always @(posedge clk_pix)
        rd_bit <= fb[rd_addr];

endmodule
