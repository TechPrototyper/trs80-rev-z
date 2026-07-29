// TRS-80 Rev Z — video divider chain
//
// Hardware modeled (Sheet 2 / RetroStack VideoCounter.kicad_sch):
//   input conditioning:  Z70 (74LS74 ÷2), Z43 (74LS157 mux, MODESEL),
//                        Z58 (74LS92 ÷12, DOT1/DOT2), Z24 (NAND → LATCH*)
//   divider chain:       Z65a ÷4 (C2,C4) → Z50 ÷14 (C8,C16,C32; QD=HDRV)
//                        → Z12 ÷12 (L1..L8) → Z65b ÷2 (R1)
//                        → Z32 ÷11 (R2,R4,R8; QD=VDRV)
//   terminal-count clears: Z66 (74LS11)
//
// Documented behavior (TRS-80 Technical Manual 1978, pp. 13-16):
//   CHAIN = 887.0416 kHz in BOTH screen modes; line = 112 character times
//   = 672 dots (HDRV high during columns 64..111); frame = 264 lines
//   (VDRV high during rows 16..21 = the 72 blank lines); LATCH* one dot wide
//   every 6 dots (64-char mode) / two dots wide every 12 (32-char mode);
//   C1 held low in 32-char mode (512 usable screen locations).
//
// Modeling style: single clock domain, ripple counters re-expressed as one
// synchronous cascade advanced by chain_en — externally cycle-identical, see
// docs/decisions/0001-synchronous-model-of-ripple-counters.md.
//
// The sub-character phase of latch_n is hardware-exact (chapter 1 §7,
// resolved): LATCH* = NAND(Z58 QA, QC) — the ÷2 prescaler and the ÷6 tap are
// both high only in the last dot of each 6-dot cell, and the chain boundary
// (QD; QC via Z43 in 32-char mode) ends with the second latch pulse.

module m1_video_timing (
    input  wire       clk,      // dot clock, 10.6445 MHz
    input  wire       rst_n,
    input  wire       modesel,  // 1 = 64 characters/line, 0 = 32 (double width)

    output wire       latch_n,  // character latch pulse, low-active (Z24)
    output wire       dot_en,   // pixel-rate enable: every clk (64) / every 2nd (32)
                                // ≙ SHIFT, the mode-conditioned dot clock (Z43)
    output wire       chain_en, // one-clk enable at 887.0416 kHz (chain advance)
    output wire [6:0] col,      // character column 0..111; col[5:0] = C1..C32
    output wire [3:0] line,     // scan line within row, 0..11 (L1..L8)
    output wire [4:0] row,      // character row 0..21; row[3:0] = R1..R8
    output wire       hdrv,     // high during columns 64..111 (Z50 QD)
    output wire       vdrv      // high during rows 16..21   (Z32 QD)
);

    // ------------------------------------------------------------------
    // Input conditioning (Z70/Z43/Z58/Z24): a 12-state phase counter.
    // In 64-char mode one state per dot; in 32-char mode each state lasts
    // two dots (Z58 is fed the halved clock via Z43).
    // ------------------------------------------------------------------
    // 64-char mode: Z58 runs at the full dot clock as ÷12 (chain from pin 8).
    // 32-char mode: Z58 runs at the halved clock (Z70/Z43) as ÷6 (chain from
    // pin 9) — CHAIN stays at 887.0416 kHz either way, and a character time
    // is 6 states of 1 dot (64) or 6 states of 2 dots (32).
    reg        half;         // Z70: toggles every dot (used in 32-char mode)
    reg  [3:0] phase;        // Z58 state: 0..11 (64-char) / 0..5 (32-char)
    wire       step       = modesel | half;   // advance Z58 this dot?
    wire [3:0] phase_last = modesel ? 4'd11 : 4'd5;
    wire       phase_wrap = step & (phase == phase_last);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            half  <= 1'b0;
            phase <= 4'd0;
        end else begin
            half <= ~half;
            if (step)
                phase <= (phase == phase_last) ? 4'd0 : phase + 4'd1;
        end
    end

    // LATCH*: low during the last state of each character time
    // (state 5 and state 11), i.e. once per character in both modes.
    assign latch_n  = ~((phase == 4'd5) | (phase == 4'd11));

    // SHIFT as an enable: the video shift registers run at the full dot rate
    // in 64-char mode and at half rate in 32-char mode (Z43 feeds them the
    // conditioned clock; Z42 inverts it — the half-dot skew is not modeled,
    // see ADR-0001).
    assign dot_en   = step;

    // CHAIN advances once per full Z58 cycle — 887.0416 kHz in both modes.
    assign chain_en = phase_wrap;

    // C1: toggles once per character (64-char mode); held low in 32-char
    // mode, halving the usable screen locations.
    wire c1 = modesel & (phase >= 4'd6);

    // ------------------------------------------------------------------
    // Divider chain: Z65a ÷4 → Z50 ÷14 → Z12 ÷12 → Z65b ÷2 → Z32 ÷11.
    // One synchronous cascade; each stage advances when all upstream
    // stages wrap (the ripple order of the original, without the ripple).
    // ------------------------------------------------------------------
    reg [1:0] z65a;   // C2, C4
    reg [3:0] z50;    // 0..13; [2:0] = C8,C16,C32; >=8 = HDRV
    reg [3:0] z12;    // 0..11; L1..L8
    reg       z65b;   // R1
    reg [3:0] z32;    // 0..10; [2:0] = R2,R4,R8; >=8 = VDRV

    wire z65a_wrap = (z65a == 2'd3);
    wire z50_wrap  = (z50  == 4'd13);
    wire z12_wrap  = (z12  == 4'd11);
    wire z65b_wrap = z65b;             // wraps on 1 -> 0
    wire z32_wrap  = (z32  == 4'd10);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            z65a <= 2'd0;
            z50  <= 4'd0;
            z12  <= 4'd0;
            z65b <= 1'b0;
            z32  <= 4'd0;
        end else if (chain_en) begin
            z65a <= z65a_wrap ? 2'd0 : z65a + 2'd1;
            if (z65a_wrap) begin
                z50 <= z50_wrap ? 4'd0 : z50 + 4'd1;
                if (z50_wrap) begin
                    z12 <= z12_wrap ? 4'd0 : z12 + 4'd1;
                    if (z12_wrap) begin
                        z65b <= ~z65b;
                        if (z65b_wrap)
                            z32 <= z32_wrap ? 4'd0 : z32 + 4'd1;
                    end
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Position outputs and blanking taps.
    // ------------------------------------------------------------------
    assign col  = {z50, z65a, c1};          // z50*8 + z65a*2 + c1 = 0..111
    assign line = z12;
    assign row  = {z32, z65b};              // z32*2 + z65b = 0..21
    assign hdrv = (z50 >= 4'd8);            // columns 64..111
    assign vdrv = (z32 >= 4'd8);            // rows 16..21

endmodule
