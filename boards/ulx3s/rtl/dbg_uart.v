// TRS-80 Rev Z — debug host link over the FTDI UART (ADR-0006 D1)
//
// Shovels bytes between the board's FTDI serial lines and m1_core's
// debug byte port: 8N1, DIVISOR clocks per bit, no flow control needed —
// the debug engine drains commands orders of magnitude faster than any
// sane baud rate delivers them, and the TX side simply back-pressures
// the core's out port while a byte is shifting. RX majority/mid-bit
// sampling with a 2-FF synchronizer; a framing error drops the byte.
//
// The same dbg_* seam later belongs to the ESP32 debug server; who owns
// it is a board-top mux decision (single-owner rule, ESP32 services ADR).

module dbg_uart #(
    parameter [15:0] DIVISOR = 16'd23   // 10.6443 MHz / 23 = 462.8 kBd (~460800)
) (
    input  wire       clk,
    input  wire       rst_n,

    input  wire       uart_rx,          // from the FTDI (host transmits)
    output reg        uart_tx,          // to the FTDI (host receives)

    // to m1_core's debug port
    output reg        cmd_valid,
    output reg  [7:0] cmd_data,
    input  wire       cmd_ready,
    input  wire       rsp_valid,
    input  wire [7:0] rsp_data,
    output wire       rsp_ready
);

    // ---- RX ----
    reg [1:0]  rx_sync;
    always @(posedge clk) rx_sync <= {rx_sync[0], uart_rx};
    wire rxd = rx_sync[1];

    localparam [1:0] R_IDLE = 2'd0, R_BITS = 2'd1, R_STOP = 2'd2;
    reg [1:0]  rxs;
    reg [15:0] rcnt;
    reg [3:0]  rbit;
    reg [7:0]  rsh;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rxs   <= R_IDLE;
            rcnt  <= 16'd0;
            rbit  <= 4'd0;
            rsh   <= 8'd0;
            cmd_valid <= 1'b0;
            cmd_data  <= 8'd0;
        end else begin
            if (cmd_valid && cmd_ready)
                cmd_valid <= 1'b0;

            case (rxs)
                R_IDLE:
                    if (!rxd) begin              // start edge: verify at mid
                        rcnt <= {1'b0, DIVISOR[15:1]};
                        rxs  <= R_BITS;
                        rbit <= 4'd0;
                    end
                R_BITS:
                    if (rcnt != 16'd0)
                        rcnt <= rcnt - 16'd1;
                    else if (rbit == 4'd0) begin
                        // mid-start verification
                        if (rxd) rxs <= R_IDLE;          // glitch, ignore
                        else begin
                            rbit <= 4'd1;
                            rcnt <= DIVISOR;
                        end
                    end else begin
                        rsh  <= {rxd, rsh[7:1]};         // LSB first
                        rbit <= rbit + 4'd1;
                        rcnt <= DIVISOR;
                        if (rbit == 4'd8)
                            rxs <= R_STOP;
                    end
                default:                          // R_STOP
                    if (rcnt != 16'd0)
                        rcnt <= rcnt - 16'd1;
                    else begin
                        if (rxd) begin            // valid stop bit
                            cmd_data  <= rsh;
                            cmd_valid <= 1'b1;    // engine consumes fast;
                        end                       // overrun impossible at
                        rxs <= R_IDLE;            // serial timescales
                    end
            endcase
        end
    end

    // ---- TX ----
    reg [15:0] tcnt;
    reg [3:0]  tbit;                     // 0 idle, 1 start, 2..9 data, 10 stop
    reg [7:0]  tsh;

    assign rsp_ready = (tbit == 4'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            uart_tx <= 1'b1;
            tcnt    <= 16'd0;
            tbit    <= 4'd0;
            tsh     <= 8'd0;
        end else begin
            if (tbit == 4'd0) begin
                if (rsp_valid) begin
                    tsh     <= rsp_data;
                    uart_tx <= 1'b0;             // start bit
                    tcnt    <= DIVISOR;
                    tbit    <= 4'd1;
                end
            end else if (tcnt != 16'd0)
                tcnt <= tcnt - 16'd1;
            else begin
                tcnt <= DIVISOR;
                if (tbit <= 4'd8) begin
                    uart_tx <= tsh[0];
                    tsh     <= {1'b1, tsh[7:1]};
                    tbit    <= tbit + 4'd1;
                end else if (tbit == 4'd9) begin
                    uart_tx <= 1'b1;             // stop bit
                    tbit    <= 4'd10;
                end else
                    tbit <= 4'd0;                // line idle, next byte
            end
        end
    end

endmodule
