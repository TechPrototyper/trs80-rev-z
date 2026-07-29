// TRS-80 Rev Z — video RAM and CPU/counter-chain arbitration
//
// Hardware modeled (Sheet 1-2 / RetroStack "VideoAccessMultiplexer.kicad_sch"
// and "VideoRAM.kicad_sch"):
//   address muxes:  Z64, Z49, Z31 (74LS157, select = ~VID on all twelve
//                   sections, strobes grounded):
//                     VA0..VA5 = A0..A5 (CPU) / C1..C32 (chain)
//                     VA6..VA9 = A6..A9 (CPU) / R1..R8  (chain)
//   strobe muxing:  Z49 sections b/d: ~VRD = ~RD, ~VWR = ~WR while the CPU
//                   owns the RAM; both pulled high through R49 while the
//                   chain owns it (the chain never writes, never reads onto
//                   the CPU bus)
//   video RAM:      seven 2102 1Kx1 static RAMs — Z48/Z47/Z46/Z45/Z61/Z62
//                   (bits 0..5) and Z63 (bit 7, the graphic/alpha flag).
//                   ~CE grounded (always enabled), R/~W = ~VWR in parallel,
//                   DIN straight off the CPU data bus, DOUT always driving
//   sneaky bit:     Z30 unit 4 (74LS02): VD6 = NOR(VD5, VD7) — lives on the
//                   VideoRAM sheet and feeds BOTH consumers: the chargen
//                   address path (replicated in m1_video_gen, same physical
//                   gate) and, via Z60, bit 6 of every CPU read
//   read buffers:   Z44 (bits 0..3), Z60 (bits 4..7), 74LS367 tri-state,
//                   enabled by ~VRD low — modeled as dout + dout_en
//
// Documented behavior (TRS-80 Technical Manual 1978, pp. 16-17, 20):
// the CPU is never made to wait. The address decoder (chapter 4; here the
// vid_n input) drops ~VID the moment the CPU addresses 0x3C00-0x3FFF, the
// three muxes flip instantly, and the counter chain loses the RAM mid-cell.
// The display consequence is handled downstream: ~VID also clears the data
// latches via Z7/VCLR* (m1_video_gen), which is why the artifact is a BLACK
// streak, not garbage — "black streaks all over the screen while graphics
// are being drawn". A write needs no arbitration because the beam's view is
// blanked anyway; a read additionally opens Z60/Z44 onto the CPU bus.
// Accesses placed in the blanking intervals leave no trace on screen —
// snow/streaks and beam-hack capability are the same property (SPEC §6).
//
// CPU-visible quirks that fall out of the structure (and are verified):
//   - bit 6 does not exist in silicon: written bit 6 is dropped, read bit 6
//     is NOR(bit5, bit7) — PEEKing the screen returns 0x00..0x1F as
//     0x40..0x5F, and 0x60..0x7F can never be read back.
//   - in 32-character mode C1 is held low (chapter 1), so only even
//     addresses reach the screen; the RAM itself still has all 1024 cells.
//
// Deliberate deviations (see ADR-0001):
//   - The 2102 write is level-sensitive on R/~W; here the cell is written
//     synchronously on every clk while ~VWR is low — same end state, since
//     the CPU holds address and data stable for the whole strobe.
//   - DOUT is a REGISTERED read (one dot-clock latency) so the seven-RAM
//     array infers ECP5 block RAM (DP16KD). The real parts answer within
//     "nanoseconds" (manual), but the latch pipeline grants them six dot
//     times: the counter-chain address is stable for a whole character cell
//     before LATCH* samples, and CPU strobes span several dot clocks — so
//     no dot-grid or bus-contract difference exists (verified by the
//     chapter testbenches and the golden run).
//   - The Z60/Z44 tri-state outputs become dout plus a dout_en qualifier;
//     bus merging happens at the top level, not on a shared wire.

module m1_vram (
    input  wire       clk,      // dot clock, 10.6445 MHz

    // counter-chain side (from m1_video_timing)
    input  wire [5:0] col,      // C1..C32  (col[0] pinned low in 32-char mode)
    input  wire [3:0] row,      // R1..R8   (wraps to 0..5 inside VDRV — as in hardware)

    // CPU side
    input  wire       vid_n,    // ~VID: address decoder saw 0x3C00-0x3FFF
    input  wire       rd_n,     // ~RD CPU read strobe
    input  wire       wr_n,     // ~WR CPU write strobe
    input  wire [9:0] a,        // A0..A9
    input  wire [5:0] din,      // CPU data bus D0..D5 (RAM DIN pins)
    input  wire       din7,     // CPU data bus D7 (Z63 DIN) — D6 has no RAM pin
    output wire [7:0] dout,     // CPU data bus, read data (valid while dout_en)
    output wire       dout_en,  // Z60/Z44 drive the bus (~VRD low)

    // video side (to m1_video_gen)
    output wire [5:0] vd,       // VD0..VD5
    output wire       vd7       // VD7 (Z63, graphic/alpha flag)
);

    // ------------------------------------------------------------------
    // Z64/Z49/Z31: the address and strobe multiplexers. ~VID low = CPU.
    // ------------------------------------------------------------------
    wire [9:0] va    = vid_n ? {row, col} : a;
    wire       vrd_n = vid_n | rd_n;     // Z49b (R49 pull-up when ~VID high)
    wire       vwr_n = vid_n | wr_n;     // Z49d (R49 pull-up when ~VID high)

    // ------------------------------------------------------------------
    // The seven RAMs. One array, bit 6 = Z63's graphic flag (VD7);
    // there is no storage behind data-bus bit 6.
    // ------------------------------------------------------------------
    reg [6:0] ram [0:1023];

    always @(posedge clk) begin
        if (!vwr_n)
            ram[va] <= {din7, din};
    end

    reg [6:0] q;                         // DOUT, always driving (~CE = GND);
    always @(posedge clk)                // registered for block-RAM inference
        q <= ram[va];

    assign vd  = q[5:0];
    assign vd7 = q[6];

    // ------------------------------------------------------------------
    // Z30 unit 4 (sneaky bit, on this sheet in hardware) and the Z60/Z44
    // read buffers back onto the CPU data bus.
    // ------------------------------------------------------------------
    wire vd6 = ~(q[5] | q[6]);

    assign dout_en = ~vrd_n;
    assign dout    = {q[6], vd6, q[5:0]};

endmodule
