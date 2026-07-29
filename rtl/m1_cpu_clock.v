// TRS-80 Rev Z — CPU clock divider
//
// Hardware modeled: Z56 (74LS92, divide-by-6 section) + Z72 buffer, Sheet 1 of the
// TRS-80 Technical Manual (1978). The Z80 clock is a separate ÷6 of the master
// crystal, NOT a tap of the video divider chain — same frequency as the character
// rate, phase set at reset. See docs/chapters/01-clock-and-dividers.md §2 and
// docs/decisions/0001-synchronous-model-of-ripple-counters.md.
//
// Single clock domain: `clk` is the 10.6445 MHz dot clock; `cpu_cen` is a one-cycle
// enable at 1.77408 MHz for the Z80 core and everything in its domain.

module m1_cpu_clock (
    input  wire clk,     // dot clock, 10.6445 MHz
    input  wire rst_n,
    output reg  cpu_cen  // one-clk enable, master/6 = 1.77408 MHz
);

    reg [2:0] div;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div     <= 3'd0;
            cpu_cen <= 1'b0;
        end else begin
            div     <= (div == 3'd5) ? 3'd0 : div + 3'd1;
            cpu_cen <= (div == 3'd5);
        end
    end

endmodule
