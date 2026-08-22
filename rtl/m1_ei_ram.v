// TRS-80 Rev Z — Expansion Interface RAM (upper 32K, ADR-0005 stage 1)
//
// Hardware modeled (Tandy Expansion Interface, RAM sheets; RetroStack EI
// Rev D recreation as the schematic reference):
//   - up to two banks of eight 4116 DRAMs, 16K×8 each:
//       bank 1: 0x8000-0xBFFF, bank 2: 0xC000-0xFFFF
//   - the EI decodes the upper 32K itself: the keyboard unit's Z21 decoder
//     is strobed with ~A15 (chapter 4) and never fires up here; the EI
//     watches A15=1 memory cycles (RAS*) on the 40-pin bus
//   - reads reach the bus through the EI's own 74LS367-class buffers,
//     enabled on read cycles only; writes take data from the unbuffered
//     bus, exactly like the keyboard-unit RAM (chapter 3/4 idiom)
//
// Deliberate deviations (same liberties as m1_ram, chapter 4):
//   - flat array instead of DRAM row/column sequencing and refresh
//   - the read is REGISTERED (one dot-clock latency) for ECP5 DP16KD
//     inference; bus strobes span several dot clocks, so the contract
//     holds (proven by the chapter benches and the golden runs)
//   - `cfg` stands in for the population option of the real EI:
//     00 = no EI RAM (16K system), 01 = bank 1 only (32K system),
//     1x = both banks (48K system). An unpopulated bank behaves like the
//     real machine: reads float the bus (no dout_en), writes vanish.

module m1_ei_ram (
    input  wire        clk,
    input  wire [14:0] a,       // A0..A14
    input  wire        a15,     // A15: the EI's region qualifier
    input  wire        ras_n,   // RAS* = buffered ~MREQ (memory cycle)
    input  wire        rd_n,    // RD*: enables the EI read buffers
    input  wire        wr_n,    // WR* memory write strobe
    input  wire [1:0]  cfg,     // population: 00 none, 01 16K, 1x 32K
    input  wire [7:0]  din,     // data bus (unbuffered into the DRAM DIN)
    output wire [7:0]  dout,
    output wire        dout_en,

    // debug read port (non-intrusive READ_MEM): second DP16KD port,
    // registered. Population gating happens in the parent — this is the
    // raw array (an unpopulated bank is folded to 0xFF there).
    input  wire [14:0] a2,
    output reg  [7:0]  dout2
);

    // bank selects: A15=1 memory cycle, split on A14
    wire sel_b1 = a15 & ~ras_n & ~a[14];       // 0x8000-0xBFFF
    wire sel_b2 = a15 & ~ras_n &  a[14];       // 0xC000-0xFFFF
    wire populated = (sel_b1 & (cfg != 2'b00)) | (sel_b2 & cfg[1]);

    reg [7:0] mem [0:32767];

    always @(posedge clk)
        if (populated && !wr_n)
            mem[a] <= din;

    reg [7:0] rdata;
    always @(posedge clk)
        rdata <= mem[a];

    always @(posedge clk)
        dout2 <= mem[a2];

    assign dout    = rdata;
    assign dout_en = populated & ~rd_n;

endmodule
