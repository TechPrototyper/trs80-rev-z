// TRS-80 Rev Z — system RAM (16K configuration)
//
// Hardware modeled (RetroStack "RAM.kicad_sch" + "RAM_ROM_Interface.kicad_sch"):
//   Z13-Z20:  eight 4116 dynamic RAMs, 16K×1 each — 16 KiB total,
//             0x4000-0x7FFF behind the RAM* select
//   Z35/Z51:  74LS157 row/column address multiplexers (MUX)
//   Z67/Z68:  74LS367 read buffers to the data bus, enabled by MEM*;
//             the RAM data *inputs* hang on the bus unbuffered — writes
//             need no buffer (Technical Manual 1978, decoder chapter)
//
// Deliberate deviations:
//   - The DRAM array is a flat 16 KiB memory indexed by A0..A13. The
//     RAS/MUX/CAS row-column sequencing (generated in m1_cpu for the
//     waveforms) and refresh are not consumed: FPGA block RAM neither
//     multiplexes nor forgets. This is the one subsystem where modeling
//     the chip-level protocol would add state without adding testable
//     behavior — the bus-visible contract (RAM* + WR*/MEM* strobes) is
//     preserved exactly.
//   - Writes retrigger on every dot clock while WR* is low; the value is
//     stable, so the repeat is invisible — same liberty as chapter 3's 2102s.
//   - The read is REGISTERED (one dot-clock latency) for ECP5 block-RAM
//     (DP16KD) inference; the 4116s answer combinationally after CAS*, but
//     the bus strobes span several dot clocks, so the contract holds
//     (same argument as m1_rom, verified by testbenches + golden).

module m1_ram (
    input  wire        clk,
    input  wire [13:0] a,      // A0..A13
    input  wire        ram_n,  // RAM* select
    input  wire        wr_n,   // WR* memory write strobe
    input  wire        mem_n,  // MEM*: read buffers Z67/Z68
    input  wire [7:0]  din,    // data bus (unbuffered into the 4116 DIN pins)
    output wire [7:0]  dout,
    output wire        dout_en
);

    reg [7:0] mem [0:16383];

    always @(posedge clk)
        if (!ram_n && !wr_n)
            mem[a] <= din;

    reg [7:0] rdata;
    always @(posedge clk)
        rdata <= mem[a];

    assign dout    = rdata;
    assign dout_en = ~ram_n & ~mem_n;

endmodule
