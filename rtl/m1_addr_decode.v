// TRS-80 Rev Z — address decoder
//
// Hardware modeled (Sheet 1 / RetroStack "AddressDecoder.kicad_sch"):
//   decoder:   Z21 (74LS156, dual 2-to-4 open collector wired as 3-to-8:
//              A12/A13 on the select inputs, A14 on both C inputs — side b
//              decodes A14=0, side a decodes A14=1; both strobes on
//              Z73b = OR(A15, RAS*), so the decoder only fires on memory
//              cycles below 0x8000)
//   shunt:     X3 (DIP shunt in position Z3) wire-ORs the open-collector
//              outputs into the selects — the Level II "programming":
//              ROMA* = 0xxx·1xxx (8K), ROMB* = 2xxx (4K), RAM* = 4xxx..7xxx
//              (16K); pull-ups R61/R68/R62, R48 on the 3xxx output
//   gates:     Z37b (NOR as inverter, A11), Z36b/c/d (74LS32),
//              Z52a/f (74LS04), Z74b/c/d (74LS00), Z73c (74LS32)
//
// Documented behavior (TRS-80 Technical Manual 1978, pp. 8-11 "Address
// Decoder" — the text walks the Level I configuration; the Rev G sheet
// carries the Level II shunt wiring modeled here): RAS* is the buffered
// ~MREQ (Z72), "the same signal". Only A10..A15 are decoded — everything
// below is left to the selected subsystem, which is why the keyboard
// matrix mirrors through 0x3800-0x3BFF and reads of 0x3000-0x37FF select
// nothing at all (open bus). MEM* opens the ROM/RAM data buffers on reads
// only; writes need no buffer ("the RAM data inputs are on the output
// side"). KYBD has its own buffers, VID has Z60/Z44 (chapter 3).
//
// This module is pure combinational logic — the real chips plus wire.
// The only modeling liberty: open-collector wire-ORs are written as the
// AND of the participating outputs (identical truth function).

module m1_addr_decode (
    input  wire [15:10] a,      // only A15..A10 reach the decoder
    input  wire         ras_n,  // RAS* = buffered ~MREQ (Z72)
    input  wire         rd_n,   // RD*

    output wire         roma_n, // ROM A select, 0x0000-0x1FFF (8K)
    output wire         romb_n, // ROM B select, 0x2000-0x2FFF (4K)
    output wire         ram_n,  // RAM select,   0x4000-0x7FFF
    output wire         kybd_n, // keyboard,     0x3800-0x3BFF (matrix mirrors)
    output wire         vid_n,  // video RAM,    0x3C00-0x3FFF (chapter 3's ~VID)
    output wire         mem_n   // ROM/RAM read: opens the data-bus buffers
);

    // Z73b: the decoder strobe — memory cycle in the lower 32K
    wire en = ~a[15] & ~ras_n;

    // Z21 + X3: the eight open-collector outputs, wire-ORed per Level II
    assign roma_n = ~(en & ~a[14] & ~a[13]);            // outputs 0+1 (0xxx,1xxx)
    assign romb_n = ~(en & ~a[14] &  a[13] & ~a[12]);   // output 2    (2xxx)
    assign ram_n  = ~(en &  a[14]);                     // outputs 4-7 (4xxx-7xxx)
    wire   q3b_n  = ~(en & ~a[14] &  a[13] &  a[12]);   // output 3    (3xxx, R48)

    // Z37b + Z36b: the 0x3800-0x3FFF window ("incorrectly drawn OR gate":
    // both inputs low -> low). Z52a + Z36c/d: A10 splits it.
    wire   win38_n = q3b_n | ~a[11];
    assign kybd_n  = win38_n |  a[10];                  // Z36d: A10 = 0
    assign vid_n   = win38_n | ~a[10];                  // Z36c: A10 = 1

    // Z74c = NAND(ROMA*, RAM*), Z74d = NAND(ROMB*, ROMB*), Z73c = OR,
    // Z52f inverts RD*, Z74b: MEM* = (any ROM/RAM selected) AND read
    assign mem_n = ~(~rd_n & (~roma_n | ~ram_n | ~romb_n));

endmodule
