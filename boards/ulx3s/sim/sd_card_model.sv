// Testbench model: SD card in SPI mode.
//
// Bit-true SPI slave (mode 0: samples MOSI on rising SCK, changes MISO on
// falling SCK) with the command subset the host uses: CMD0, CMD8 (R7),
// CMD55/ACMD41 (busy for a few polls, then ready), CMD58 (OCR with CCS),
// CMD16, CMD17 (start token, 512 data bytes, 2 CRC bytes) and CMD24
// (start token in, 512 bytes into the image, data-response 0x05, a few
// busy bytes). The card image
// comes from +img=<file> ($readmemh, one byte per line — build_fat32.py).
//
// +sdsc switches the model to a byte-addressed standard-capacity card
// (OCR CCS = 0), exercising the host's CMD16 + LBA<<9 path.
//
// The byte/command layer runs entirely with blocking assignments inside
// one process (it is a behavioural model); only the shift registers that
// the other clock edge reads are nonblocking.

`timescale 1ns / 1ps

// Waivers (testbench-only, per repo policy): the byte/command layer is a
// deliberate single-process behavioural model — blocking assignments and
// initialized declarations are the point, not an oversight.
/* verilator lint_off BLKSEQ */
/* verilator lint_off PROCASSINIT */

module sd_card_model #(
    parameter int IMG_BYTES = 4 * 1024 * 1024
) (
    input  logic sck,
    input  logic mosi,
    input  logic cs_n,
    output logic miso
);

    logic [7:0] mem [0:IMG_BYTES-1];
    bit         sdsc;
    int         flaky_n = 0;

    initial begin
        string fn;
        sdsc = $test$plusargs("sdsc");
        if ($test$plusargs("sdflaky")) flaky_n = 40;
        if ($value$plusargs("img=%s", fn))
            $readmemh(fn, mem);
    end

    // ---- bit layer -----------------------------------------------------
    logic [2:0] bitc = 3'd0;
    logic [6:0] rxsh = 7'h7F;
    logic [7:0] txsh = 8'hFF;
    logic [7:0] tx_next = 8'hFF;

    assign miso = cs_n ? 1'b1 : txsh[7];

    wire [7:0] rx_byte = {rxsh, mosi};        // valid when bitc == 7

    always @(negedge sck or posedge cs_n) begin
        if (cs_n)
            txsh <= 8'hFF;
        else if (bitc == 3'd0)
            txsh <= tx_next;                  // fresh byte each boundary
        else
            txsh <= {txsh[6:0], 1'b1};
    end

    // ---- byte/command layer ---------------------------------------------
    typedef enum logic [3:0] {
        R_IDLE, R_NCR, R_R1, R_EXTRA, R_GAP, R_TOKEN, R_DATA, R_CRC,
        R_WTOK, R_WDAT, R_WCRC, R_WRESP, R_WBUSY
    } rstate_e;

    rstate_e     rstate = R_IDLE;
    /* verilator lint_off UNUSEDSIGNAL */   // [47:46] start marker, [7:0]
    logic [47:0] cmd_buf;                   // CRC slot: framing, never read
    /* verilator lint_on UNUSEDSIGNAL */
    int          col_n  = 0;
    bit          idle   = 1'b1;
    bit          acmd   = 1'b0;
    int          busy_left = 2;               // ACMD41 polls before ready
    logic [7:0]  r1val;
    logic [31:0] extra;
    int          extra_i, gap_i, crc_i, di, busy_i;
    bit          dataflg, writeflg;
    longint unsigned daddr;

    task automatic decode();
        logic [5:0]  ci;
        logic [31:0] arg;
        ci  = cmd_buf[45:40];
        arg = cmd_buf[39:8];
        r1val   = idle ? 8'h01 : 8'h00;
        extra   = 32'h0;
        extra_i = 0;
        dataflg = 1'b0;
        writeflg = 1'b0;
        case (ci)
            6'd0:  begin
                if (flaky_n > 0) begin
                    flaky_n -= 1;
                    r1val = 8'hFF;        // moody: no R1 at all
                end else begin
                    idle = 1'b1; r1val = 8'h01;
                end
            end
            6'd8:  begin extra = 32'h0000_01AA; extra_i = 4; end
            6'd55: acmd = 1'b1;
            6'd41: begin
                if (!acmd)
                    r1val = 8'h05;            // illegal without CMD55
                else if (busy_left > 0) begin
                    busy_left -= 1;
                    r1val = 8'h01;
                end else begin
                    idle  = 1'b0;
                    r1val = 8'h00;
                end
            end
            6'd58: begin
                extra   = {sdsc ? 8'h80 : 8'hC0, 24'hFF_8000};
                extra_i = 4;
            end
            6'd16: ;                          // block length: accept
            6'd17: begin
                dataflg = 1'b1;
                daddr   = sdsc ? longint'(arg)
                               : longint'(arg) * 512;
            end
            6'd24: begin
                writeflg = 1'b1;
                daddr    = sdsc ? longint'(arg)
                                : longint'(arg) * 512;
            end
            default: r1val = 8'h05;           // illegal command
        endcase
        if (ci != 6'd55)
            acmd = 1'b0;
        rstate = R_NCR;
    endtask

    always @(posedge sck or posedge cs_n) begin
        if (cs_n) begin
            bitc  <= 3'd0;
            col_n  = 0;
        end else begin
            rxsh <= {rxsh[5:0], mosi};
            bitc <= bitc + 3'd1;
            if (bitc == 3'd7) begin
                // 1) collect command frames (bytes 0..4 already stored;
                //    the 6th byte is the CRC, which decode() ignores).
                //    Fully suspended while write payload streams in:
                //    data bytes matching 01xxxxxx are NOT commands.
                if (rstate == R_WTOK || rstate == R_WDAT
                    || rstate == R_WCRC)
                    ;                             // no collection at all
                else if (col_n == 0) begin
                    if (rx_byte[7:6] == 2'b01) begin
                        cmd_buf = {rx_byte, 40'h0};
                        col_n   = 1;
                    end
                end else begin
                    cmd_buf[39 - 8*(col_n-1) -: 8] = rx_byte;
                    if (col_n == 5) begin
                        col_n = 0;
                        decode();
                    end else
                        col_n += 1;
                end
                // 2) produce the next tx byte
                case (rstate)
                    R_IDLE:  tx_next = 8'hFF;
                    R_NCR:   begin tx_next = 8'hFF; rstate = R_R1; end
                    R_R1: begin
                        tx_next = r1val;
                        gap_i   = 0;
                        if (extra_i > 0)      rstate = R_EXTRA;
                        else if (dataflg && r1val == 8'h00)
                                              rstate = R_GAP;
                        else if (writeflg && r1val == 8'h00)
                                              rstate = R_WTOK;
                        else                  rstate = R_IDLE;
                    end
                    R_EXTRA: begin
                        tx_next  = extra[8*extra_i - 1 -: 8];
                        extra_i -= 1;
                        if (extra_i == 0) begin
                            if (dataflg)      rstate = R_GAP;
                            else              rstate = R_IDLE;
                        end
                    end
                    R_GAP: begin
                        tx_next = 8'hFF;
                        gap_i  += 1;
                        if (gap_i == 3)       rstate = R_TOKEN;
                    end
                    R_TOKEN: begin
                        tx_next = 8'hFE;
                        di      = 0;
                        crc_i   = 0;
                        rstate  = R_DATA;
                    end
                    R_DATA: begin
                        longint unsigned a;
                        a = daddr + longint'(di);
                        tx_next = (a < longint'(IMG_BYTES))
                                  ? mem[a[21:0]] : 8'hFF;
                        di += 1;
                        if (di == 512)        rstate = R_CRC;
                    end
                    R_CRC: begin
                        tx_next = 8'hA5;      // dummy CRC, host ignores it
                        crc_i  += 1;
                        if (crc_i == 2)       rstate = R_IDLE;
                    end
                    R_WTOK: begin
                        tx_next = 8'hFF;
                        if (rx_byte == 8'hFE) begin
                            di     = 0;
                            rstate = R_WDAT;
                        end
                    end
                    R_WDAT: begin
                        longint unsigned a;
                        tx_next = 8'hFF;
                        a = daddr + longint'(di);
                        if (a < longint'(IMG_BYTES))
                            mem[a[21:0]] = rx_byte;
                        di += 1;
                        if (di == 512) begin
                            crc_i  = 0;
                            rstate = R_WCRC;
                        end
                    end
                    R_WCRC: begin
                        tx_next = 8'hFF;
                        crc_i  += 1;
                        if (crc_i == 2)       rstate = R_WRESP;
                    end
                    R_WRESP: begin
                        tx_next = 8'h05;      // data accepted
                        busy_i  = 0;
                        rstate  = R_WBUSY;
                    end
                    R_WBUSY: begin
                        busy_i += 1;
                        if (busy_i == 4) begin
                            tx_next = 8'hFF;  // busy released
                            rstate  = R_IDLE;
                        end else
                            tx_next = 8'h00;  // still busy
                    end
                    default: rstate = R_IDLE;
                endcase
            end
        end
    end

endmodule
