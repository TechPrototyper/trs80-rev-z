// Testbench: tmds_encoder — DVI 8b/10b properties.
//
// Checks, per DVI 1.0:
//   1. decode-back identity: running the published decode rule over the
//      encoder output recovers the input byte, for all 256 values twice
//      (both disparity approaches) and for 4096 random bytes,
//   2. the running disparity of the emitted symbols stays bounded (the
//      whole point of stage 2),
//   3. de = 0 emits exactly the four fixed control tokens.

`timescale 1ns / 1ps

module tb_tmds;

    logic       clk;
    logic       de;
    logic [1:0] ctrl;
    logic [7:0] din;
    wire  [9:0] q;

    initial clk = 0;
    always #12.5 clk = ~clk;

    tmds_encoder dut (.clk(clk), .de(de), .ctrl(ctrl), .din(din), .q_out(q));

    int errors = 0;

    function automatic [7:0] tmds_decode(input [9:0] c);
        logic [7:0] w;
        int i;
        begin
            w = c[9] ? ~c[7:0] : c[7:0];
            tmds_decode[0] = w[0];
            for (i = 1; i < 8; i++)
                tmds_decode[i] = c[8] ? (w[i] ^ w[i-1]) : ~(w[i] ^ w[i-1]);
        end
    endfunction

    function automatic int ones10(input [9:0] c);
        int i;
        begin
            ones10 = 0;
            for (i = 0; i < 10; i++) ones10 += int'(c[i]);
        end
    endfunction

    int disparity;     // running ones-minus-zeros over video symbols
    int disp_peak;

    // din is stable before the clock edge; q after the edge encodes it.
    task automatic feed_and_check(input [7:0] b);
        din = b;
        @(posedge clk); #1;
        if (tmds_decode(q) !== b) begin
            $display("FAIL  decode(%b) = %02h, want %02h", q, tmds_decode(q), b);
            errors++;
        end
        disparity += ones10(q) - (10 - ones10(q));
        if (disparity > disp_peak)  disp_peak = disparity;
        if (-disparity > disp_peak) disp_peak = -disparity;
    endtask

    initial begin
        int i;
        logic [7:0] b;

        de = 0; ctrl = 2'b00; din = 8'h00;
        disparity = 0; disp_peak = 0;

        // --- control tokens ---
        for (i = 0; i < 4; i++) begin
            ctrl = i[1:0];
            @(posedge clk); #1;   // registered output
            @(posedge clk); #1;
            case (i[1:0])
                2'b00: if (q !== 10'b1101010100) begin $display("FAIL ctrl 00"); errors++; end
                2'b01: if (q !== 10'b0010101011) begin $display("FAIL ctrl 01"); errors++; end
                2'b10: if (q !== 10'b0101010100) begin $display("FAIL ctrl 10"); errors++; end
                2'b11: if (q !== 10'b1010101011) begin $display("FAIL ctrl 11"); errors++; end
            endcase
        end

        // --- video: all bytes twice, then random ---
        de = 1;
        din = 8'h00;
        @(posedge clk); #1;                 // first video symbol
        disparity = 0; disp_peak = 0;
        for (i = 0; i < 512; i++)  feed_and_check(i[7:0]);
        for (i = 0; i < 4096; i++) begin
            b = 8'($urandom());
            feed_and_check(b);
        end

        // The encoder's own state variable tracks the 8-bit data disparity;
        // the wire-level running DC (all ten bits) legitimately swings a few
        // bits wider. Peak ~16 over thousands of random symbols is balanced;
        // a broken stage 2 drifts into the hundreds here.
        if (disp_peak > 24) begin
            $display("FAIL  running disparity unbounded: peak %0d", disp_peak);
            errors++;
        end

        if (errors == 0)
            $display("ALL CHECKS PASSED (decode identity, disparity peak %0d)", disp_peak);
        else
            $display("%0d CHECKS FAILED", errors);
        $finish;
    end

endmodule
