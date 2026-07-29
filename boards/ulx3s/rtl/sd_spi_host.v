// TRS-80 Rev Z — SD card SPI host (board equipment, milestone M1)
//
// Own work (MIT, like the DVI stage): a minimal SPI-mode SD host that
// initializes the card and streams single 512-byte sectors. It exists so
// the machine can fetch its Level II ROM from a plain FAT32 card without
// an ESP32 companion — the core stays self-contained (HANDOFF "Aura" rule)
// and the repository stays free of GPL SD/FAT cores.
//
// Protocol facts (SD Physical Layer Simplified Spec, SPI mode):
//   - power-up: >=74 SCK cycles with CS high, then CMD0 (CRC 0x95) -> idle
//   - CMD8 0x1AA (CRC 0x87) distinguishes V2 cards (R7 echoes the pattern);
//     V1 cards answer "illegal command" and are still fine
//   - ACMD41 (CMD55+CMD41, HCS set for V2) polls until the card leaves idle
//   - CMD58 reads OCR; CCS bit 30 = SDHC/SDXC (block addressing)
//   - SDSC cards get CMD16(512) and byte addresses (LBA << 9)
//   - CMD24 single-block write: R1, 0xFE start token, 512 data + 2 CRC
//     bytes, data-response token (xxx00101 = accepted), then busy low
//   - CMD17 single-block read: R1, then 0xFE start token, 512 data bytes,
//     2 CRC bytes (not checked — SPI mode transfers are CRC-off by default)
//   - init clocking 100-400 kHz; data transfers here run a conservative
//     ~2.66 MHz (spec allows 25 MHz; margin over speed, the ROM is 12 KiB)
//
// Everything runs in the dot-clock domain (ADR-0001: single domain, slower
// rates as enables) — SCK is a divided register, MISO is sampled on the
// rising SCK edge we generate, MOSI only changes on the falling edge.

module sd_spi_host #(
    parameter [7:0]  HALF_INIT = 8'd20,  // SCK half-period, init (~266 kHz)
    parameter [7:0]  HALF_FAST = 8'd2,   // SCK half-period, data (~2.66 MHz)
    // real cards are moody at power-up (found on first hardware contact,
    // 2026-07-25): a failed init is retried from scratch after a pause
    parameter [2:0]  INIT_TRIES = 3'd5,
    parameter [23:0] RETRY_DLY  = 24'd2128900   // ~200 ms of dot clocks
) (
    input  wire        clk,        // dot clock
    input  wire        rst_n,

    // SPI pads
    output wire        sck,
    output wire        mosi,
    input  wire        miso,
    output reg         cs_n,

    // card state
    output reg         ready,      // init complete, card accepts reads
    output reg         init_err,   // no/unusable card (latched)
    output reg         sdhc,       // block addressing (CCS)

    // single-sector read
    input  wire        rd_req,     // pulse while ready: read rd_lba
    input  wire [31:0] rd_lba,
    output reg         byte_vld,   // one clk pulse per payload byte
    output reg  [7:0]  byte_data,
    output reg  [8:0]  byte_idx,   // 0..511
    output reg         rd_done,    // pulse: sector complete
    output reg         rd_err,     // read failed (latched)

    // single-sector write (CMD24). The host PULLS the payload: wr_fetch
    // pulses with wr_idx, the consumer presents wr_byte two clocks later
    // (a registered BRAM read fits; serialization takes >=16 clocks).
    input  wire        wr_req,     // pulse while ready: write wr_lba
    input  wire [31:0] wr_lba,
    output reg         wr_fetch,
    output reg  [8:0]  wr_idx,
    input  wire [7:0]  wr_byte,
    output reg         wr_done,    // pulse: sector written (busy cleared)
    output reg         wr_err      // write failed (latched)
);

    // ------------------------------------------------------------------
    // Byte-level SPI engine (mode 0). MOSI changes on the falling SCK
    // edge, MISO is sampled on the rising edge; idle bus is SCK=0,
    // MOSI=1 (card expects 0xFF filler). Two requesters share it —
    // the command engine (c_*) and the top sequence (r_*) — which are
    // never active in the same state; a combinational arbiter merges them.
    // ------------------------------------------------------------------
    reg        c_go, r_go;
    reg  [7:0] c_tx, r_tx;
    wire       xf_go = c_go | r_go;
    wire [7:0] xf_tx = c_go ? c_tx : r_tx;

    reg        sck_r;
    reg        xf_busy;
    reg        xf_done;      // 1-clk pulse, xf_rx valid
    reg  [7:0] xf_sh;
    reg  [2:0] xf_bit;
    reg  [7:0] xf_div;
    reg  [7:0] half;         // current half-period
    reg        rxb;

    assign sck  = sck_r;
    assign mosi = xf_busy ? xf_sh[7] : 1'b1;

    wire [7:0] xf_rx = xf_sh;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            xf_busy <= 1'b0;
            xf_done <= 1'b0;
            xf_sh   <= 8'hFF;
            xf_bit  <= 3'd0;
            xf_div  <= 8'd0;
            sck_r   <= 1'b0;
            rxb     <= 1'b0;
        end else begin
            xf_done <= 1'b0;
            if (xf_go && !xf_busy) begin
                xf_busy <= 1'b1;
                xf_sh   <= xf_tx;
                xf_bit  <= 3'd7;
                xf_div  <= 8'd0;
                sck_r   <= 1'b0;
            end else if (xf_busy) begin
                if (xf_div == half - 8'd1) begin
                    xf_div <= 8'd0;
                    if (!sck_r) begin
                        sck_r <= 1'b1;
                        rxb   <= miso;                   // sample on rising
                    end else begin
                        sck_r <= 1'b0;                   // shift on falling
                        xf_sh <= {xf_sh[6:0], rxb};
                        if (xf_bit == 3'd0) begin
                            xf_busy <= 1'b0;
                            xf_done <= 1'b1;
                        end else
                            xf_bit <= xf_bit - 3'd1;
                    end
                end else
                    xf_div <= xf_div + 8'd1;
            end
        end
    end

    // ------------------------------------------------------------------
    // Command engine: gap byte, 6 command bytes, then poll up to 8 bytes
    // for the R1 response (first byte with bit 7 clear).
    // ------------------------------------------------------------------
    localparam [1:0] C_IDLE = 2'd0, C_GAP = 2'd1, C_TX = 2'd2, C_POLL = 2'd3;

    reg  [1:0]  cstate;
    reg         cmd_go;      // 1-clk request from the top sequence
    reg  [5:0]  cmd_idx;
    reg  [31:0] cmd_arg;
    reg  [7:0]  cmd_crc;
    reg         cmd_done;    // 1-clk pulse
    reg         cmd_to;      // no R1 within 8 poll bytes
    reg  [7:0]  r1;
    reg  [2:0]  tx_n;
    reg  [3:0]  poll_n;
    reg  [47:0] frame;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cstate   <= C_IDLE;
            cmd_done <= 1'b0;
            cmd_to   <= 1'b0;
            r1       <= 8'hFF;
            tx_n     <= 3'd0;
            poll_n   <= 4'd0;
            frame    <= 48'd0;
            c_go     <= 1'b0;
            c_tx     <= 8'hFF;
        end else begin
            cmd_done <= 1'b0;
            c_go     <= 1'b0;
            case (cstate)
                C_IDLE: if (cmd_go) begin
                    frame  <= {2'b01, cmd_idx, cmd_arg, cmd_crc};
                    c_tx   <= 8'hFF;                 // leading gap byte
                    c_go   <= 1'b1;
                    cstate <= C_GAP;
                end
                C_GAP: if (xf_done) begin
                    tx_n   <= 3'd0;
                    c_tx   <= frame[47:40];
                    c_go   <= 1'b1;
                    cstate <= C_TX;
                end
                C_TX: if (xf_done) begin
                    if (tx_n == 3'd5) begin
                        poll_n <= 4'd0;
                        c_tx   <= 8'hFF;
                        c_go   <= 1'b1;
                        cstate <= C_POLL;
                    end else begin
                        tx_n  <= tx_n + 3'd1;
                        frame <= {frame[39:0], 8'hFF};
                        c_tx  <= frame[39:32];
                        c_go  <= 1'b1;
                    end
                end
                C_POLL: if (xf_done) begin
                    if (!xf_rx[7]) begin
                        r1       <= xf_rx;
                        cmd_done <= 1'b1;
                        cmd_to   <= 1'b0;
                        cstate   <= C_IDLE;
                    end else if (poll_n == 4'd8) begin
                        r1       <= xf_rx;
                        cmd_done <= 1'b1;
                        cmd_to   <= 1'b1;
                        cstate   <= C_IDLE;
                    end else begin
                        poll_n <= poll_n + 4'd1;
                        c_tx   <= 8'hFF;
                        c_go   <= 1'b1;
                    end
                end
                default: cstate <= C_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Top-level sequence: power-up filler, CMD0, CMD8, ACMD41 loop,
    // CMD58 (CCS), CMD16 for SDSC — then serve CMD17 sector reads.
    // ------------------------------------------------------------------
    localparam [4:0]
        S_POWER   = 5'd0,   // 10x 0xFF with CS high
        S_CMD0    = 5'd1,
        S_CMD0_R  = 5'd2,
        S_CMD8    = 5'd3,
        S_CMD8_R  = 5'd4,
        S_CMD8_E  = 5'd5,   // R7: 4 echo bytes
        S_CMD55   = 5'd6,
        S_CMD55_R = 5'd7,
        S_CMD41   = 5'd8,
        S_CMD41_R = 5'd9,
        S_CMD58   = 5'd10,
        S_CMD58_R = 5'd11,
        S_CMD58_E = 5'd12,  // OCR: 4 bytes
        S_CMD16   = 5'd13,
        S_CMD16_R = 5'd14,
        S_READY   = 5'd15,
        S_CMD17_R = 5'd16,
        S_TOKEN   = 5'd17,
        S_DATA    = 5'd18,
        S_CRC     = 5'd19,
        S_ERROR   = 5'd20,
        S_W_R     = 5'd21,   // CMD24 R1
        S_W_TOK   = 5'd22,   // start token 0xFE
        S_W_FETCH = 5'd23,   // pull one payload byte (2-clk settle)
        S_W_DATA  = 5'd24,   // shift it out
        S_W_CRC   = 5'd25,   // two dummy CRC bytes
        S_W_RESP  = 5'd26,   // data response token
        S_W_BUSY  = 5'd27,   // card busy poll
        S_IFAIL   = 5'd28;   // init attempt failed: pause, then retry

    reg [4:0]  state;
    reg [2:0]  try_n;       // init attempts so far
    reg [3:0]  fill_n;      // power-up filler bytes
    reg [4:0]  cmd0_try;
    reg [1:0]  extra_n;     // R7/OCR/CRC byte counter
    reg [23:0] acmd_to;     // ACMD41 timeout (~1.6 s of dot clocks)
    reg [16:0] tok_to;      // start-token timeout (bytes, ~65k = ~197 ms)
    reg        sdv2;
    reg [3:0]  r7_volt;     // R7 byte 3, low nibble (voltage accepted)
    reg [8:0]  dcnt;        // payload byte counter (byte_idx lags it by one
                            // transfer so vld/data/idx are one coherent set)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_POWER;
            cs_n      <= 1'b1;
            half      <= HALF_INIT;
            ready     <= 1'b0;
            init_err  <= 1'b0;
            sdhc      <= 1'b0;
            sdv2      <= 1'b0;
            cmd_go    <= 1'b0;
            cmd_idx   <= 6'd0;
            cmd_arg   <= 32'd0;
            cmd_crc   <= 8'hFF;
            try_n     <= 3'd0;
            fill_n    <= 4'd0;
            cmd0_try  <= 5'd0;
            extra_n   <= 2'd0;
            acmd_to   <= 24'd0;
            tok_to    <= 17'd0;
            r7_volt   <= 4'h0;
            dcnt      <= 9'd0;
            r_go      <= 1'b0;
            r_tx      <= 8'hFF;
            byte_vld  <= 1'b0;
            byte_data <= 8'h00;
            byte_idx  <= 9'd0;
            rd_done   <= 1'b0;
            rd_err    <= 1'b0;
            wr_fetch  <= 1'b0;
            wr_idx    <= 9'd0;
            wr_done   <= 1'b0;
            wr_err    <= 1'b0;
        end else begin
            cmd_go   <= 1'b0;
            r_go     <= 1'b0;
            byte_vld <= 1'b0;
            rd_done  <= 1'b0;
            wr_fetch <= 1'b0;
            wr_done  <= 1'b0;

            case (state)
                // ---- init --------------------------------------------
                S_POWER: begin
                    cs_n <= 1'b1;
                    if (!xf_busy && !xf_go) begin
                        if (fill_n == 4'd10) begin
                            cs_n  <= 1'b0;
                            state <= S_CMD0;
                        end else begin
                            r_tx   <= 8'hFF;
                            r_go   <= 1'b1;
                            fill_n <= fill_n + 4'd1;
                        end
                    end
                end
                S_CMD0: begin
                    acmd_to <= 24'd0;
                    cmd_idx <= 6'd0;  cmd_arg <= 32'h0000_0000;
                    cmd_crc <= 8'h95; cmd_go  <= 1'b1;
                    state   <= S_CMD0_R;
                end
                S_CMD0_R: if (cmd_done) begin
                    if (!cmd_to && r1 == 8'h01)
                        state <= S_CMD8;
                    else if (cmd0_try == 5'd16) begin
                        state <= S_IFAIL;
                    end else begin
                        cmd0_try <= cmd0_try + 5'd1;
                        state    <= S_CMD0;
                    end
                end
                S_CMD8: begin
                    cmd_idx <= 6'd8;  cmd_arg <= 32'h0000_01AA;
                    cmd_crc <= 8'h87; cmd_go  <= 1'b1;
                    state   <= S_CMD8_R;
                end
                S_CMD8_R: if (cmd_done) begin
                    if (cmd_to) begin
                        state <= S_IFAIL;
                    end else if (r1 == 8'h01) begin
                        sdv2    <= 1'b1;
                        extra_n <= 2'd0;
                        r_tx    <= 8'hFF; r_go <= 1'b1;
                        state   <= S_CMD8_E;
                    end else begin
                        sdv2  <= 1'b0;      // illegal command: V1 card
                        state <= S_CMD55;
                    end
                end
                S_CMD8_E: if (xf_done) begin
                    if (extra_n == 2'd2)
                        r7_volt <= xf_rx[3:0];   // byte 3: voltage accepted
                    if (extra_n == 2'd3) begin
                        // R7 echo: 2.7-3.6 V accepted + our 0xAA pattern
                        if (r7_volt != 4'h1 || xf_rx != 8'hAA) begin
state <= S_IFAIL;
                        end else
                            state <= S_CMD55;
                    end else begin
                        extra_n <= extra_n + 2'd1;
                        r_tx    <= 8'hFF; r_go <= 1'b1;
                    end
                end
                S_CMD55: begin
                    cmd_idx <= 6'd55; cmd_arg <= 32'h0000_0000;
                    cmd_crc <= 8'hFF; cmd_go  <= 1'b1;
                    state   <= S_CMD55_R;
                end
                S_CMD55_R: if (cmd_done) begin
                    if (cmd_to || r1[6:1] != 6'd0) begin
                        state <= S_IFAIL;
                    end else
                        state <= S_CMD41;
                end
                S_CMD41: begin
                    cmd_idx <= 6'd41;
                    cmd_arg <= sdv2 ? 32'h4000_0000 : 32'h0000_0000;
                    cmd_crc <= 8'hFF; cmd_go <= 1'b1;
                    state   <= S_CMD41_R;
                end
                S_CMD41_R: begin
                    if (cmd_done) begin
                        if (!cmd_to && r1 == 8'h00)
                            state <= sdv2 ? S_CMD58 : S_CMD16;
                        else if (!cmd_to && r1 == 8'h01)
                            state <= S_CMD55;   // still idle: poll again
                        else begin
state <= S_IFAIL;
                        end
                    end else if (&acmd_to) begin
state <= S_IFAIL;   // card never left idle
                    end else
                        acmd_to <= acmd_to + 24'd1;
                end
                S_CMD58: begin
                    cmd_idx <= 6'd58; cmd_arg <= 32'h0000_0000;
                    cmd_crc <= 8'hFF; cmd_go  <= 1'b1;
                    state   <= S_CMD58_R;
                end
                S_CMD58_R: if (cmd_done) begin
                    if (cmd_to || r1 != 8'h00) begin
                        state <= S_IFAIL;
                    end else begin
                        extra_n <= 2'd0;
                        r_tx    <= 8'hFF; r_go <= 1'b1;
                        state   <= S_CMD58_E;
                    end
                end
                S_CMD58_E: if (xf_done) begin
                    if (extra_n == 2'd0)
                        sdhc <= xf_rx[6];   // OCR[30] = CCS
                    if (extra_n == 2'd3)
                        state <= sdhc ? S_READY : S_CMD16;
                    else begin
                        extra_n <= extra_n + 2'd1;
                        r_tx    <= 8'hFF; r_go <= 1'b1;
                    end
                end
                S_CMD16: begin
                    cmd_idx <= 6'd16; cmd_arg <= 32'd512;
                    cmd_crc <= 8'hFF; cmd_go  <= 1'b1;
                    state   <= S_CMD16_R;
                end
                S_CMD16_R: if (cmd_done) begin
                    if (cmd_to || r1 != 8'h00) begin
                        state <= S_IFAIL;
                    end else
                        state <= S_READY;
                end

                // ---- ready / sector read -----------------------------
                S_READY: begin
                    half  <= HALF_FAST;
                    ready <= 1'b1;
                    if (rd_req && !rd_err) begin
                        cmd_idx <= 6'd17;
                        cmd_arg <= sdhc ? rd_lba : {rd_lba[22:0], 9'd0};
                        cmd_crc <= 8'hFF;
                        cmd_go  <= 1'b1;
                        state   <= S_CMD17_R;
                    end else if (wr_req && !wr_err) begin
                        cmd_idx <= 6'd24;
                        cmd_arg <= sdhc ? wr_lba : {wr_lba[22:0], 9'd0};
                        cmd_crc <= 8'hFF;
                        cmd_go  <= 1'b1;
                        state   <= S_W_R;
                    end
                end
                S_CMD17_R: if (cmd_done) begin
                    if (cmd_to || r1 != 8'h00) begin
                        rd_err <= 1'b1;
                        state  <= S_ERROR;
                    end else begin
                        tok_to <= 17'd0;
                        r_tx   <= 8'hFF; r_go <= 1'b1;
                        state  <= S_TOKEN;
                    end
                end
                S_TOKEN: if (xf_done) begin
                    if (xf_rx == 8'hFE) begin
                        dcnt  <= 9'd0;
                        r_tx  <= 8'hFF; r_go <= 1'b1;
                        state <= S_DATA;
                    end else if (xf_rx != 8'hFF || tok_to[16]) begin
                        rd_err <= 1'b1;   // error token or timeout
                        state  <= S_ERROR;
                    end else begin
                        tok_to <= tok_to + 17'd1;
                        r_tx   <= 8'hFF; r_go <= 1'b1;
                    end
                end
                S_DATA: if (xf_done) begin
                    byte_data <= xf_rx;
                    byte_idx  <= dcnt;
                    byte_vld  <= 1'b1;
                    if (dcnt == 9'd511) begin
                        extra_n <= 2'd0;
                        r_tx    <= 8'hFF; r_go <= 1'b1;
                        state   <= S_CRC;
                    end else begin
                        dcnt <= dcnt + 9'd1;
                        r_tx <= 8'hFF; r_go <= 1'b1;
                    end
                end
                S_CRC: if (xf_done) begin
                    if (extra_n == 2'd1) begin
                        rd_done <= 1'b1;
                        state   <= S_READY;
                    end else begin
                        extra_n <= 2'd1;
                        r_tx    <= 8'hFF; r_go <= 1'b1;
                    end
                end

                // ---- sector write (CMD24) ----------------------------
                S_W_R: if (cmd_done) begin
                    if (cmd_to || r1 != 8'h00) begin
                        wr_err <= 1'b1;
                        state  <= S_ERROR;
                    end else begin
                        r_tx  <= 8'hFE;   r_go <= 1'b1;   // start token
                        state <= S_W_TOK;
                    end
                end
                S_W_TOK: if (xf_done) begin
                    dcnt     <= 9'd0;
                    wr_idx   <= 9'd0;
                    wr_fetch <= 1'b1;
                    extra_n  <= 2'd0;                    // settle counter
                    state    <= S_W_FETCH;
                end
                S_W_FETCH: begin
                    // two clocks for the consumer's registered read
                    extra_n <= extra_n + 2'd1;
                    if (extra_n == 2'd2) begin
                        r_tx  <= wr_byte; r_go <= 1'b1;
                        state <= S_W_DATA;
                    end
                end
                S_W_DATA: if (xf_done) begin
                    if (dcnt == 9'd511) begin
                        extra_n <= 2'd0;
                        r_tx    <= 8'hFF; r_go <= 1'b1;  // CRC byte 1
                        state   <= S_W_CRC;
                    end else begin
                        dcnt     <= dcnt + 9'd1;
                        wr_idx   <= dcnt + 9'd1;
                        wr_fetch <= 1'b1;
                        extra_n  <= 2'd0;
                        state    <= S_W_FETCH;
                    end
                end
                S_W_CRC: if (xf_done) begin
                    if (extra_n == 2'd1) begin
                        fill_n <= 4'd0;                  // response poll
                        r_tx   <= 8'hFF; r_go <= 1'b1;
                        state  <= S_W_RESP;
                    end else begin
                        extra_n <= 2'd1;
                        r_tx    <= 8'hFF; r_go <= 1'b1;  // CRC byte 2
                    end
                end
                S_W_RESP: if (xf_done) begin
                    // the data response follows within a few byte times
                    if (xf_rx == 8'hFF) begin
                        if (fill_n == 4'd8) begin
                            wr_err <= 1'b1;              // never answered
                            state  <= S_ERROR;
                        end else begin
                            fill_n <= fill_n + 4'd1;
                            r_tx   <= 8'hFF; r_go <= 1'b1;
                        end
                    end else if (xf_rx[4:0] != 5'h05) begin
                        wr_err <= 1'b1;                  // rejected
                        state  <= S_ERROR;
                    end else begin
                        tok_to <= 17'd0;
                        r_tx   <= 8'hFF; r_go <= 1'b1;
                        state  <= S_W_BUSY;
                    end
                end
                S_W_BUSY: if (xf_done) begin
                    if (xf_rx == 8'hFF) begin
                        wr_done <= 1'b1;
                        state   <= S_READY;
                    end else if (tok_to[16]) begin
                        wr_err <= 1'b1;                  // stuck busy
                        state  <= S_ERROR;
                    end else begin
                        tok_to <= tok_to + 17'd1;
                        r_tx   <= 8'hFF; r_go <= 1'b1;
                    end
                end

                S_IFAIL: begin
                    // deselect, wait, then re-run the whole init; only
                    // the last attempt latches init_err
                    cs_n <= 1'b1;
                    if (try_n == INIT_TRIES - 3'd1) begin
                        init_err <= 1'b1;
                        state    <= S_ERROR;
                    end else if (acmd_to == RETRY_DLY) begin
                        try_n    <= try_n + 3'd1;
                        half     <= HALF_INIT;
                        fill_n   <= 4'd0;
                        cmd0_try <= 5'd0;
                        acmd_to  <= 24'd0;
                        sdv2     <= 1'b0;
                        sdhc     <= 1'b0;
                        state    <= S_POWER;
                    end else
                        acmd_to <= acmd_to + 24'd1;
                end

                S_ERROR: begin
                    cs_n  <= 1'b0;    // release nothing mid-stream; just stop
                    ready <= 1'b0;
                end
                default: state <= S_ERROR;
            endcase
        end
    end

endmodule
