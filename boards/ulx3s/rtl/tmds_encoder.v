// TRS-80 Rev Z — TMDS channel encoder (DVI 1.0)
//
// Straight implementation of the DVI 1.0 specification, figure 3-5: 8b/10b
// transition-minimized encoding with running-disparity balance for the
// active-video region, and the four fixed control tokens for blanking.
// Own code (MIT); the algorithm is the published DVI standard.
//
// Output bit order: q_out[0] is transmitted first (LSB first on the wire).

module tmds_encoder (
    input  wire       clk,      // pixel clock
    input  wire       de,       // display enable (1 = video data)
    input  wire [1:0] ctrl,     // {c1, c0} sync bits while de = 0
    input  wire [7:0] din,      // pixel byte
    output reg  [9:0] q_out
);

    // popcount of the input byte
    function automatic [3:0] ones8(input [7:0] b);
        integer i;
        begin
            ones8 = 4'd0;
            for (i = 0; i < 8; i = i + 1)
                ones8 = ones8 + {3'b000, b[i]};
        end
    endfunction

    // stage 1: transition-minimized 9-bit code (XOR or XNOR chain)
    wire [3:0] n1_d  = ones8(din);
    wire       use_xnor = (n1_d > 4'd4) || (n1_d == 4'd4 && din[0] == 1'b0);

    wire [8:0] q_m;
    genvar g;
    assign q_m[0] = din[0];
    generate
        for (g = 1; g < 8; g = g + 1) begin : enc
            assign q_m[g] = use_xnor ? ~(q_m[g-1] ^ din[g])
                                     :  (q_m[g-1] ^ din[g]);
        end
    endgenerate
    assign q_m[8] = ~use_xnor;

    // stage 2: running-disparity balancing
    wire [3:0] n1_qm = ones8(q_m[7:0]);
    wire [3:0] n0_qm = 4'd8 - n1_qm;

    reg signed [4:0] cnt;   // running disparity (ones minus zeros, /2 units folded in)

    always @(posedge clk) begin
        if (!de) begin
            cnt <= 5'sd0;
            case (ctrl)
                2'b00: q_out <= 10'b1101010100;
                2'b01: q_out <= 10'b0010101011;
                2'b10: q_out <= 10'b0101010100;
                default: q_out <= 10'b1010101011;
            endcase
        end else begin
            if (cnt == 0 || n1_qm == n0_qm) begin
                q_out <= {~q_m[8], q_m[8], q_m[8] ? q_m[7:0] : ~q_m[7:0]};
                if (q_m[8] == 1'b0)
                    cnt <= cnt + $signed({1'b0, n0_qm}) - $signed({1'b0, n1_qm});
                else
                    cnt <= cnt + $signed({1'b0, n1_qm}) - $signed({1'b0, n0_qm});
            end else if ((cnt > 0 && n1_qm > n0_qm) ||
                         (cnt < 0 && n0_qm > n1_qm)) begin
                q_out <= {1'b1, q_m[8], ~q_m[7:0]};
                cnt   <= cnt + $signed({3'b000, q_m[8], 1'b0})
                             + $signed({1'b0, n0_qm}) - $signed({1'b0, n1_qm});
            end else begin
                q_out <= {1'b0, q_m[8], q_m[7:0]};
                cnt   <= cnt - $signed({3'b000, ~q_m[8], 1'b0})
                             + $signed({1'b0, n1_qm}) - $signed({1'b0, n0_qm});
            end
        end
    end

endmodule
