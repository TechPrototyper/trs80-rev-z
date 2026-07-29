// TRS-80 Rev Z — I/O port 0xFF (cassette latch + video mode select)
//
// Hardware modeled (RetroStack "Cassette.kicad_sch" + TRS-80 Technical Manual
// 1978, "Port Addressing"/"Cassette" pp. 519-552):
//   Z54 (74LS30 8-in NAND) + Z52c (74LS04): decode A1..A7 all high and A0 high
//     -> FF* low.  The Z80 uses only the low 8 address bits for I/O; the whole
//     machine has exactly ONE port, 0xFF, the cassette/mode register.
//   Z25c/b (74LS32 "backward" OR): OUTSIG* = OR(OUT*, FF*), INSIG* = OR(IN*, FF*).
//     Exactly one is ever low; both float high off port 0xFF.
//   Z59 (74LS175 quad D-latch), clocked by the RISING edge of OUTSIG*
//     (end of the OUT cycle):
//       D0 -> Q0      = cassette output level bit 0  (R53..R56 ladder)
//       D1 -> ~Q1     = cassette output level bit 1  (inverted tap used)
//       D2 -> Q2      = cassette motor relay (Z41), 1 = on
//       D3 -> ~Q3     = MODESEL  ->  so MODESEL = NOT(latched D3):
//                       write D3=0 -> MODESEL high -> 64-char mode
//                       write D3=1 -> MODESEL low  -> 32-char mode
//   Z44 (74LS367 tri-state), enabled by INSIG* on an IN 0xFF, drives:
//       D7 = cassette input flip-flop (Z24 SR latch)
//       D6 = MODESEL   (the current mode reads straight back)
//     D5..D0 are not driven by anything — the bus floats high, so the CPU
//     reads them as 1 (matches trs80gp: IN 0xFF = 0x7F in 64-char mode with no
//     cassette, 0x3F in 32-char mode).
//   Z24 (74LS132 SR latch): set by a cassette-input edge, reset by OUTSIG*.
//     Modeled minimally here — with no cassette connected the input stays 0;
//     full audio processing (Z4 filter/rectifier/detector) is the M2 cassette
//     milestone.
//
// Deliberate deviations:
//   - Single clock domain (ADR-0001): OUTSIG*'s rising edge is detected on the
//     dot clock instead of being a real edge-triggered latch clock.
//   - Tri-state read bus -> dout + dout_en (chapter 3/5 idiom).
//   - The 2-bit cassette output and motor are exported as plain signals for the
//     cassette chapter; nothing consumes them yet.

module m1_io (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] a,          // low 8 address bits (port number)
    input  wire       in_n,       // IN*  (port read strobe, chapter 5)
    input  wire       out_n,      // OUT* (port write strobe)
    input  wire [7:0] din,        // CPU data bus (write data)
    input  wire       cass_in,    // cassette input level (0 with no tape)

    output wire [7:0] dout,       // read data for IN 0xFF
    output wire       dout_en,    // Z44 drives the bus (INSIG* low)

    output wire       modesel,    // to m1_video_timing (64-char = high)
    output wire [1:0] cass_out,   // cassette output level (Q0, ~Q1)
    output wire       cass_motor, // cassette motor relay (Q2)

    // observability
    output wire       ff_n,       // FF* decode
    output wire       insig_n,    // INSIG*
    output wire       outsig_n    // OUTSIG*
);

    // Z54 + Z52c + Z36a: the port-0xFF decode (all 8 low address bits high)
    assign ff_n     = ~(&a);                 // FF* low iff a == 0xFF
    assign outsig_n = out_n | ff_n;          // Z25c
    assign insig_n  = in_n  | ff_n;          // Z25b

    // Z59: latch D0..D3 on the rising edge of OUTSIG*
    reg outsig_n_d;
    reg [3:0] latch;                         // {D3,D2,D1,D0} as written
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            outsig_n_d <= 1'b1;
            latch      <= 4'b0000;           // power-on: 64-char, motor off
        end else begin
            outsig_n_d <= outsig_n;
            if (outsig_n && !outsig_n_d)     // rising edge of OUTSIG*
                latch <= din[3:0];
        end
    end

    assign cass_out   = {~latch[1], latch[0]};   // {~Q1, Q0}
    assign cass_motor = latch[2];                // Q2
    assign modesel    = ~latch[3];               // ~Q3

    // Z24: cassette-input SR latch — set by a rising edge on cass_in,
    // reset (dominant) whenever OUTSIG* is asserted (motor/data write).
    reg cass_ff, cass_in_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cass_ff   <= 1'b0;
            cass_in_d <= 1'b0;
        end else begin
            cass_in_d <= cass_in;
            if (!outsig_n)                   // reset dominates (OUTSIG* low)
                cass_ff <= 1'b0;
            else if (cass_in && !cass_in_d)  // set on cassette-input edge
                cass_ff <= 1'b1;
        end
    end

    // Z44: IN 0xFF read.  D7 = cassette flip-flop, D6 = MODESEL, D5..D0 float 1.
    assign dout    = {cass_ff, modesel, 6'b111111};
    assign dout_en = ~insig_n;

    // The port latch only captures D0..D3 (Z59 is a quad latch); the upper
    // data bits reach this module on the shared bus but have no pin here.
    wire _unused_ok = &{1'b0, din[7:4]};

endmodule
