// TRS-80 Rev Z — video data latch, character/graphics generation, shift path
//
// Hardware modeled (Sheets 1-2 / RetroStack "Video Latch.kicad_sch" and
// "VideoGen.kicad_sch"):
//   data latch:     Z28 (74LS174: VD0..VD5 -> LB0..LB5),
//                   Z27 (74LS175: ~VD7 -> ~GRAPHICS/GRAPHICS, BLANK* -> ~BLANK,
//                        L8 -> ~CHARGAP, VD6 -> LB6), both cleared by VCLR*
//   clear logic:    Z7 (74LS74: VCLR* set by ~VID low, released at next LATCH*)
//   "sneaky bit":   VD6 = NOR(VD5, VD7) — Z30 unit on the VideoRAM sheet;
//                   modeled here so this module sees the raw seven RAM outputs
//   char generator: Z29 (MCM6670P: LB0..LB6 address, L1/L2/L4 row select,
//                        five dot outputs D4..D0, D4 = leftmost)
//   graphics gen:   Z8  (74LS153 dual 4:1 mux: {L8,L4} select LB0/2/4 -> left,
//                        LB1/3/5 -> right)
//   shift registers:Z10 (74LS166, alpha: H=GND, G..C = D4..D0),
//                   Z11 (74LS166, graphics: H,G,F = left, E,D,C = right)
//   load gating:    Z26 (74LS20: alpha load = ~BLANK&~GRAPHICS&~CHARGAP&LATCH,
//                        graphics load = ~BLANK&GRAPHICS&LATCH), Z9 (LATCH inv)
//   pixel combine:  Z30 unit 1 (NOR of the two serial outputs)
//
// Documented behavior (TRS-80 Technical Manual 1978, pp. 17-20): one-character
// pipeline RAM -> latch; glyphs are 5x7 in a 6x12 cell with the blank column
// on the LEFT (74LS166 input H, grounded, shifts out first) and the glyph on
// scan lines 1..7 (chip row 0 is blank; L8 gates lines 8..11 for text);
// graphics cells are 2x3 blocks of 3 dots x 4 lines covering all 12 lines.
//
// Deliberate deviations (module-level; see ADR-0001):
//   - Single clock domain. The real shift registers clock on the inverted
//     SHIFT ("delays clock", Rev G note) — loads happen half a dot after the
//     counters. Here everything moves on posedge clk gated by dot_en; the
//     half-dot skew is not modeled, dot-grid behavior is identical.
//   - VCLR* is an async preset in hardware; here it clears synchronously
//     (visible at most one dot later, inside a region that is dark anyway).
//   - The chargen table (rtl/mcm6670_cg1.hex, provenance in ADR-0002) holds
//     all 128 glyphs like the physical chip; on a stock machine only
//     0x20..0x5F are reachable with visible output (the sneaky bit forces
//     bit 6, and VCLR* clears ~BLANK along with LB6).
//   - The chargen read is REGISTERED (one dot-clock latency) so the table
//     infers ECP5 block RAM. The MCM6670 answers combinationally, but its
//     address (LB latch + line select) is stable for a full character cell
//     before the shift registers load at the next LATCH* — the extra clock
//     changes no loaded value and no dot on the grid.
//
// The serial output `pixel` is active high; the physical net PIXEL at Z30
// pin 1 is its complement (the video mixer inverts again).

module m1_video_gen (
    input  wire       clk,      // dot clock, 10.6445 MHz
    input  wire       rst_n,

    // from m1_video_timing
    input  wire       latch_n,  // LATCH* (low in the last dot of each cell)
    input  wire       dot_en,   // SHIFT as an enable (every clk / every 2nd)
    input  wire [3:0] line,     // scan line in row, 0..11 (L1..L8)
    input  wire       hdrv,     // blanking sources for BLANK* = NOR(HDRV,VDRV)
    input  wire       vdrv,

    // video RAM side (chapter 3 puts the real arbitration here). There are
    // seven RAMs: six data bits plus the graphic/alpha bit — bit 6 of the
    // "byte" does not exist in silicon and is reconstructed internally.
    input  wire [5:0] vd,       // VD0..VD5, the six data RAMs
    input  wire       vd7,      // VD7, the graphic/alpha RAM Z63
    input  wire       vid_n,    // ~VID: low while the CPU steals video RAM

    output wire       pixel     // serial dot stream, active high
);

    // ------------------------------------------------------------------
    // Sneaky bit 6 and BLANK* — combinational, upstream of the latches.
    // ------------------------------------------------------------------
    wire vd6     = ~(vd[5] | vd7);     // Z30: 0x00..0x3F stored -> 0x40..0x5F shown
    wire blank_i = ~(hdrv | vdrv);     // Z30: high = beam in the visible region

    // ------------------------------------------------------------------
    // Z7: VCLR* — set (latches cleared) the moment the CPU takes video
    // RAM, released at the first LATCH* after it lets go.
    // ------------------------------------------------------------------
    reg vclr_n;
    wire latch_edge = ~latch_n & dot_en;   // the LATCH* rising edge, as an enable

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          vclr_n <= 1'b0;
        else if (!vid_n)     vclr_n <= 1'b0;
        else if (latch_edge) vclr_n <= 1'b1;
    end

    // ------------------------------------------------------------------
    // Z28/Z27: the data latches. One-character pipeline stage.
    // ------------------------------------------------------------------
    reg [6:0] lb;          // LB0..LB6 (Z28 + Z27 bit 4)
    reg       graphics;    // Z27: VD7 latched (Q* of the inverted input)
    reg       dly_blank;   // Z27: BLANK* latched ("Delay BLANK")
    reg       chargap_n;   // Z27: ~L8 latched (high while in glyph rows 0..7)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lb <= 7'd0; graphics <= 1'b0; dly_blank <= 1'b0; chargap_n <= 1'b0;
        end else if (!vclr_n || !vid_n) begin
            lb <= 7'd0; graphics <= 1'b0; dly_blank <= 1'b0; chargap_n <= 1'b0;
        end else if (latch_edge) begin
            lb        <= {vd6, vd};
            graphics  <= vd7;
            dly_blank <= blank_i;
            chargap_n <= ~line[3];
        end
    end

    // ------------------------------------------------------------------
    // Z29: character generator. 128 glyphs x 8 rows, addressed by LB6..LB0,
    // row select L1/L2/L4. Line 7 reads the all-zero row 7; the glyph sits
    // in rows 1..7.
    // ------------------------------------------------------------------
    parameter FONT_HEX = "../rtl/mcm6670_cg1.hex";
    reg [4:0] font [0:1023];         // bit 0 = leftmost dot
    initial $readmemh(FONT_HEX, font);

    reg [4:0] char_dots;                       // registered for block-RAM inference
    always @(posedge clk)
        char_dots <= font[{lb, line[2:0]}];

    // ------------------------------------------------------------------
    // Z8: graphics "generator" — two 4:1 muxes steering the latched cell
    // bits. {L8,L4} = 00 upper, 01 middle, 10 lower pair.
    // ------------------------------------------------------------------
    reg gfx_left, gfx_right;
    always @* begin
        case ({line[3], line[2]})
            2'b00:   {gfx_left, gfx_right} = {lb[0], lb[1]};
            2'b01:   {gfx_left, gfx_right} = {lb[2], lb[3]};
            default: {gfx_left, gfx_right} = {lb[4], lb[5]};   // 2'b11 unreachable
        endcase
    end

    // ------------------------------------------------------------------
    // Z26 + Z10/Z11: load gating and the two shift registers.
    // Both 74LS166s modeled as one 8-bit register each, H-position out
    // first (sr[7]); serial input is grounded, so zeros follow the cell.
    // ------------------------------------------------------------------
    wire load_alpha = dly_blank & ~graphics & chargap_n & ~latch_n;
    wire load_gfx   = dly_blank &  graphics             & ~latch_n;

    reg [7:0] sr_alpha, sr_gfx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sr_alpha <= 8'd0;
            sr_gfx   <= 8'd0;
        end else if (dot_en) begin
            // H, G, F, E, D, C, B, A — H shifts out first (leftmost dot)
            sr_alpha <= load_alpha
                ? {1'b0, char_dots[0], char_dots[1], char_dots[2],
                         char_dots[3], char_dots[4], 2'b00}
                : {sr_alpha[6:0], 1'b0};
            sr_gfx   <= load_gfx
                ? {{3{gfx_left}}, {3{gfx_right}}, 2'b00}
                : {sr_gfx[6:0], 1'b0};
        end
    end

    // Z30 unit 1 combines the two streams (inverted on the real board).
    assign pixel = sr_alpha[7] | sr_gfx[7];

endmodule
