// TRS-80 Rev Z — system ROM (Level II wiring)
//
// Hardware modeled (RetroStack "ROM.kicad_sch" + "RAM_ROM_Interface.kicad_sch"):
//   Z33:      ROM A, 2364-type 8K×8, ~OE = ROMA*  (0x0000-0x1FFF)
//   Z34:      ROM B, 2332-type 4K×8, ~OE = ROMB*  (0x2000-0x2FFF)
//   Z67/Z68:  74LS367 read buffers between ROMD/RAMD and the data bus,
//             enabled by MEM* — modeled as dout plus dout_en (chapter-3 idiom)
//
// Deliberate deviations:
//   - Both mask ROMs are one 12 KiB array indexed by A0..A13; the chip
//     selects guarantee the index stays below 0x3000.
//   - Mask contents are NOT in this repository (roms/README.md). The array
//     powers up cleared and is filled at runtime through the loader port —
//     the same port the board-level loader (SD/ESP32, milestone M1) will
//     drive. In simulation the testbench plays the loader.
//   - The read is REGISTERED (one dot-clock latency) so the array infers
//     ECP5 block RAM (DP16KD) instead of distributed LUTRAM. The mask ROMs
//     answer combinationally (450 ns access), but every bus read strobe
//     spans several dot clocks and the CPU samples late in the cycle, so
//     the extra clock is invisible on the bus contract (verified by the
//     chapter testbenches and the golden run).

module m1_rom (
    input  wire        clk,
    input  wire [13:0] a,       // A0..A13
    input  wire        roma_n,  // ROMA* select (Z33 ~OE)
    input  wire        romb_n,  // ROMB* select (Z34 ~OE)
    input  wire        mem_n,   // MEM*: read buffers Z67/Z68
    output wire [7:0]  dout,
    output wire        dout_en,

    // loader port (board: SD/ESP32; sim: testbench)
    input  wire        ld_en,
    input  wire [13:0] ld_addr,
    input  wire [7:0]  ld_data
);

    reg [7:0] mem [0:12287];

    integer i;
    initial begin
        for (i = 0; i < 12288; i = i + 1)
            mem[i] = 8'h00;
    end

    always @(posedge clk)
        if (ld_en)
            mem[ld_addr] <= ld_data;

    reg [7:0] rdata;
    always @(posedge clk)
        rdata <= mem[a];

    assign dout    = rdata;
    assign dout_en = (~roma_n | ~romb_n) & ~mem_n;

endmodule
