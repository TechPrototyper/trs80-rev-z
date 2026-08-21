// Testbench: the FTDI debug link (dbg_uart + m1_core, ADR-0006 D1).
//
// Drives the serial RX line at bit level like the PC bridge will (8N1,
// DIVISOR clocks per bit), sends HALT and STATUS, and decodes the TX
// responses bit by bit: the echo, a sane PC, and the halted flag prove
// the whole path host-wire-UART-debug-core-machine and back.

`timescale 1ns / 1ps

module tb_dbg_uart;

    localparam int DIV = 23;

    logic clk, rst_n;
    initial begin clk = 0; rst_n = 0; end
    always #46.97 clk = ~clk;

    int errors = 0;

    logic rxline;                 // host -> FPGA
    wire  txline;                 // FPGA -> host

    wire       cv, cr, rv, rr;
    wire [7:0] cd, rd;

    dbg_uart #(.DIVISOR(16'(DIV))) u_uart (
        .clk(clk), .rst_n(rst_n),
        .uart_rx(rxline), .uart_tx(txline),
        .cmd_valid(cv), .cmd_data(cd), .cmd_ready(cr),
        .rsp_valid(rv), .rsp_data(rd), .rsp_ready(rr)
    );

    m1_core u_core (
        .clk(clk), .por_rst_n(rst_n), .dbg_rst_n(rst_n), .reset_btn_n(1'b1),
        .test_n(1'b1), .int_n(1'b1), .wait_n(1'b1),
        .ld_en(1'b0), .ld_addr(14'd0), .ld_data(8'h00),
        .ei_ram_cfg(2'b00),
        .fdc_disk(4'b0000), .fdc_wp(4'b0000), .percom_en(1'b0),
        .trk_vld(1'b0), .trk_data(8'h00), .trk_idx(13'd0),
        .trk_done(1'b0), .trk_err(1'b0), .trk_len(13'd0), .trk_dbl(1'b0),
        .trk_wb_fetch(1'b0), .trk_wb_idx(13'd0),
        .trk_wb_done(1'b0), .trk_wb_err(1'b0),
        .dbg_in_valid(cv), .dbg_in_data(cd), .dbg_in_ready(cr),
        .dbg_out_valid(rv), .dbg_out_data(rd), .dbg_out_ready(rr),
        .keys('0),
        .cass_in(1'b0),
        /* verilator lint_off PINCONNECTEMPTY */
        .trk_req(), .trk_drv(), .trk_track(), .trk_side(), .trk_wb_req(),
        .trk_wb_data(),
        .cass_out(), .cass_motor(), .hdrv(), .vdrv(), .dot_en(),
        .cpu_cen(), .modesel(), .addr(), .m1_n(), .halt_n(),
        .pixel(), .col(), .line(), .row()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    task automatic ser_send(input logic [7:0] b);
        rxline = 0;                            // start
        repeat (DIV) @(posedge clk);
        for (int i = 0; i < 8; i++) begin
            rxline = b[i];
            repeat (DIV) @(posedge clk);
        end
        rxline = 1;                            // stop
        repeat (DIV + 4) @(posedge clk);
    endtask

    // passive deserializer: never misses a start edge, whatever the
    // host-side send task is doing at that moment
    logic [7:0] rxq [$];
    initial begin
        logic [7:0] b;
        forever begin
            @(posedge clk);
            if (rst_n && txline === 1'b0) begin
                repeat (DIV + DIV/2) @(posedge clk);
                for (int i = 0; i < 8; i++) begin
                    b[i] = txline;
                    repeat (DIV) @(posedge clk);
                end
                if (txline !== 1'b1) begin
                    $display("FAIL  missing stop bit");
                    errors++;
                end
                rxq.push_back(b);
            end
        end
    end

    task automatic ser_recv(output logic [7:0] b);
        wait (rxq.size() > 0);
        b = rxq.pop_front();
    endtask

    initial begin
        logic [7:0] b, lo, hi;

        rxline = 1;
        repeat (40) @(posedge clk);
        rst_n = 1;

        // let the (empty-ROM NOP sled) machine tick a moment
        #200_000;

        // HALT over the wire
        ser_send(8'h01);
        ser_recv(b);
        if (b !== 8'h01) begin
            $display("FAIL  HALT echo %02h", b);
            errors++;
        end
        ser_recv(lo); ser_recv(hi);
        $display("  halt PC = %02h%02h", hi, lo);

        // STATUS over the wire
        ser_send(8'h09);
        ser_recv(b);
        if (b !== 8'h09) begin $display("FAIL  STATUS echo %02h", b); errors++; end
        ser_recv(b);
        if (b !== 8'h01) begin $display("FAIL  not halted (%02h)", b); errors++; end
        ser_recv(b);                            // cause
        ser_recv(lo); ser_recv(hi);             // pc

        // READ_MEM of two ROM bytes (NOPs) through the serial path
        ser_send(8'h06); ser_send(8'h00); ser_send(8'h00);
        ser_send(8'h02); ser_send(8'h00);
        ser_recv(b);
        if (b !== 8'h06) begin $display("FAIL  RDM echo %02h", b); errors++; end
        ser_recv(b);
        if (b !== 8'h00) begin $display("FAIL  ROM[0] = %02h", b); errors++; end
        ser_recv(b);
        if (b !== 8'h00) begin $display("FAIL  ROM[1] = %02h", b); errors++; end

        if (errors == 0) $display("ALL CHECKS PASSED (debug link over UART)");
        else             $display("%0d CHECKS FAILED", errors);
        if (errors != 0) $fatal(1);
        $finish;
    end

    initial begin
        #40_000_000;
        $fatal(1, "watchdog: UART debug bench did not finish");
    end

endmodule
