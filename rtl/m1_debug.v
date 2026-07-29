// TRS-80 Rev Z — debug core, stage A (ADR-0006)
//
// Mechanism only, protocol elsewhere: this module halts and resumes the
// machine at instruction boundaries, single-steps, holds hardware
// breakpoints, and masters the bus for memory access while the CPU is
// frozen. It talks to its host (testbench today; ESP32 debug server per
// ADR-0006 tomorrow) over a byte-oriented command port; the JSON-RPC
// layer of docs/DEBUG-PROTOCOL.md lives on that host, not here.
//
// How the halt works (the cpu_cen seam, ADR-0001): the core's clock
// enable is gated combinationally. The gate closes only while the CPU
// sits at T1 of an opcode fetch that BEGINS an instruction — so a halted
// machine always rests with PC on the address bus and the previous
// instruction architecturally complete. "Begins an instruction" is
// decided by a bus-level prefix tracker (real-ICE style): an M1 fetch is
// a continuation, not a boundary, while a CB/DD/ED/FD prefix chain is in
// flight (DD CB fetches its displacement/opcode without M1 and needs no
// special case). Interrupt-acknowledge M1 cycles are excluded upstream
// (fetch_t1 carries intcycle_n).
//
// Bus mastering: while frozen, the parent muxes address/strobes from
// this module into the decoder/memory fabric, so a debug access behaves
// exactly like a CPU access — including read side effects of device
// registers (an FDC status read clears INTRQ here as it would under the
// CPU; that is a feature of authenticity, and the host knows it).
//
// Host protocol v0 (binary, byte stream, LSB-first 16-bit values):
//   0x01              HALT      -> 01 pc_lo pc_hi   (after the freeze)
//   0x02              RUN       -> 02
//   0x03              STEP      -> 03 pc_lo pc_hi   (one instruction)
//   0x06 a_lo a_hi n_lo n_hi          READ_MEM  -> 06 <n bytes>
//   0x07 a_lo a_hi n_lo n_hi <bytes>  WRITE_MEM -> 07
//   0x08 idx a_lo a_hi en             SET_BP    -> 08     (8 slots)
//   0x09              STATUS    -> 09 flags cause pc_lo pc_hi
//                        (flags bit0 = halted, bit1 = target reset seen
//                        since last STATUS — read clears it)
//   errors            -> EE (memory access while running, bad index)
//   async             -> 80 cause pc_lo pc_hi  (cause: 0 host, 1 break-
//                        point, 2 step, 3 watchpoint, 4 TARGET RESET —
//                        the machine reset out from under the debugger;
//                        the debug subsystem lives in the FPGA power-on
//                        domain and observes the machine reset, ADR-0006
//                        §3a, so it can report it instead of dying with
//                        the machine).

module m1_debug (
    input  wire        clk,
    input  wire        rst_n,        // debug subsystem reset (FPGA POR)
    input  wire        tgt_rst_n,    // OBSERVED machine reset, active low —
                                     // core_rst_n on the FPGA, SYSRES* on
                                     // the real-hardware adapter (ADR-0006)

    // host command/response byte port
    input  wire        in_valid,
    input  wire [7:0]  in_data,
    output reg         in_ready,
    output reg         out_valid,
    output reg  [7:0]  out_data,
    input  wire        out_ready,

    // CPU observation (m1_cpu taps)
    input  wire        fetch_t1,     // core at M1 T1 of a fetch (not INTA)
    input  wire        fetch_lat,    // 1-clk: M1 opcode byte is on the bus
    input  wire [15:0] cpu_addr,
    input  wire [7:0]  bus,
    input  wire        cpu_cen_raw,  // ungated 1.77 MHz enable
    input  wire        cpu_rd_n,     // CPU-side memory strobes (pre-mask)
    input  wire        cpu_wr_n,
    input  wire        cpu_m1_n,     // fetch qualifier for the watchpoints
    input  wire        cpu_inte,     // IFF straight from the core

    // control
    output wire        freeze,       // 1 = withhold cpu_cen
    output reg         stuff,        // instruction stuffing: isolate the
                                     // bus, feed the CPU, mask INT
    output reg  [7:0]  feed,         // the byte every CPU read receives

    // bus mastering (only while frozen)
    output reg         master,
    output reg  [15:0] mst_addr,
    output reg  [7:0]  mst_wdata,
    output reg         mst_rd_n,
    output reg         mst_wr_n
);

    localparam [7:0] C_HALT = 8'h01, C_RUN  = 8'h02, C_STEP = 8'h03,
                     C_REGS = 8'h04, C_SETR = 8'h05,
                     C_RDM  = 8'h06, C_WRM  = 8'h07, C_SBP  = 8'h08,
                     C_STAT = 8'h09, C_SWP  = 8'h0A,
                     R_ERR  = 8'hEE, R_EVT  = 8'h80;
    localparam [2:0] CAUSE_HOST = 3'd0, CAUSE_BP = 3'd1, CAUSE_STEP = 3'd2,
                     CAUSE_WP = 3'd3, CAUSE_RESET = 3'd4;

    // ------------------------------------------------------------------
    // Instruction-boundary tracker (prefix chains at the M1 fetch level)
    // ------------------------------------------------------------------
    localparam [1:0] B_NORM = 2'd0, B_DDFD = 2'd1, B_ONE = 2'd2;

    reg [1:0] bstate;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            bstate <= B_NORM;
        else if (fetch_lat) begin
            case (bstate)
                B_NORM:  bstate <= (bus == 8'hDD || bus == 8'hFD) ? B_DDFD
                                 : (bus == 8'hED || bus == 8'hCB) ? B_ONE
                                 :                                  B_NORM;
                B_DDFD:  bstate <= (bus == 8'hDD || bus == 8'hFD) ? B_DDFD
                                 : (bus == 8'hED)                 ? B_ONE
                                 :                                  B_NORM;
                                 // DD CB: d/opcode come without M1
                default: bstate <= B_NORM;   // the byte after ED/CB ends it
            endcase
        end
    end

    wire at_boundary = fetch_t1 && (bstate == B_NORM);

    // IM is not architecturally readable: track it by snooping the ED-page
    // opcodes as they fetch (ED 46/4E/66/6E -> 0, 56/76 -> 1, 5E/7E -> 2).
    // prev_ed marks a genuine ED prefix (not an ED-VALUED operand byte).
    reg [1:0] im_mode;
    reg       prev_ed;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            im_mode <= 2'd0;
            prev_ed <= 1'b0;
        end else if (fetch_lat) begin
            prev_ed <= (bus == 8'hED) && (bstate != B_ONE);
            if (prev_ed) begin
                if (bus == 8'h46 || bus == 8'h4E
                    || bus == 8'h66 || bus == 8'h6E) im_mode <= 2'd0;
                else if (bus == 8'h56 || bus == 8'h76) im_mode <= 2'd1;
                else if (bus == 8'h5E || bus == 8'h7E) im_mode <= 2'd2;
            end
        end
    end

    // ------------------------------------------------------------------
    // Run/halt/step state and the breakpoint comparators
    // ------------------------------------------------------------------
    reg        run_mode;             // 1 = free-running
    reg        skip_one;             // step: pass exactly one boundary
    reg [2:0]  cause;
    reg        ev_pend;              // unsolicited halt event to report
    reg        reset_seen;           // sticky: machine reset since STATUS

    // observe the machine reset: a 2-FF sync (it is asynchronous to the
    // debug clock) and a falling-edge detect. Because this module lives
    // in the FPGA power-on domain, tgt_rst_n going low means the machine
    // reset out from under us — not our own reset.
    reg [1:0]  trs_sync;
    reg        trs_d;
    reg        trs_armed;                          // machine has run once
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            trs_sync  <= 2'b00;
            trs_d     <= 1'b0;
            trs_armed <= 1'b0;
        end else begin
            trs_sync <= {trs_sync[0], tgt_rst_n};
            trs_d    <= trs_sync[1];
            if (trs_sync[1]) trs_armed <= 1'b1;     // seen it out of reset
        end
    end
    // only a genuine high->low counts — and only after the machine has
    // first come out of reset, so the boot-time reset (the machine is held
    // in reset while the ROM/SD loader runs, long after the debug core is
    // alive) is not mistaken for a target reset
    wire tgt_reset_edge = trs_armed && trs_d && !trs_sync[1];

    reg [15:0] bp_addr [0:7];
    reg [7:0]  bp_en;

    wire bp_hit = (bp_en[0] && bp_addr[0] == cpu_addr)
                | (bp_en[1] && bp_addr[1] == cpu_addr)
                | (bp_en[2] && bp_addr[2] == cpu_addr)
                | (bp_en[3] && bp_addr[3] == cpu_addr)
                | (bp_en[4] && bp_addr[4] == cpu_addr)
                | (bp_en[5] && bp_addr[5] == cpu_addr)
                | (bp_en[6] && bp_addr[6] == cpu_addr)
                | (bp_en[7] && bp_addr[7] == cpu_addr);

    assign freeze = !stuff && at_boundary && !skip_one
                    && (!run_mode || bp_hit);

    // watchpoints: address comparators on the CPU's data strobes (M1
    // fetches excluded); a hit requests a halt at the next instruction
    // boundary — this is the feature a memory-mapped machine deserves
    // and the emulator never delivered
    reg [15:0] wp_addr [0:3];
    reg [3:0]  wp_rd, wp_wr;
    reg        rdw_d, wrw_d;

    wire wp_rd_hit = !stuff && cpu_m1_n && rdw_d && !cpu_rd_n
                   && ((wp_rd[0] && wp_addr[0] == cpu_addr)
                     | (wp_rd[1] && wp_addr[1] == cpu_addr)
                     | (wp_rd[2] && wp_addr[2] == cpu_addr)
                     | (wp_rd[3] && wp_addr[3] == cpu_addr));
    wire wp_wr_hit = !stuff && wrw_d && !cpu_wr_n
                   && ((wp_wr[0] && wp_addr[0] == cpu_addr)
                     | (wp_wr[1] && wp_addr[1] == cpu_addr)
                     | (wp_wr[2] && wp_addr[2] == cpu_addr)
                     | (wp_wr[3] && wp_addr[3] == cpu_addr));

    // ------------------------------------------------------------------
    // Register capture by instruction stuffing (ADR-0006 §3). Under halt
    // the parent isolates the bus: every CPU read receives `feed`, every
    // CPU write is captured here and reaches no memory. The fed script —
    //   PUSH AF/BC/DE/HL/IX/IY · LD A,I + PUSH AF · LD A,R + PUSH AF ·
    //   EXX + EX AF,AF' + 4 pushes + EX/EXX back ·
    //   POP AF (fed the captured A/F) · LD SP,orig · JP orig_PC
    // — leaves every register as it was (R advances, as it would in any
    // real-Z80 ICE; IM is not architecturally readable and is tracked by
    // opcode snooping one day). SP falls out of the first push's write
    // address; PC is the halt address. 24 captured bytes:
    //   A F B C D E H L IXh IXl IYh IYl I f(I) R f(R) A' F' B' C' D' E' H' L'
    // ------------------------------------------------------------------
    reg [7:0]  cap [0:23];
    reg [4:0]  cap_i;
    reg [4:0]  feed_i;
    reg [4:0]  feed_last;            // index of the script's final byte
    reg [15:0] sp_base, halt_pc;
    reg        rd_d, wr_d2;

    // SET_REG (0x05): a short per-register script fed the same way —
    //   AF        PUSH AF (SP-2, writes void) + POP AF fed the new F/A
    //   BC/DE/HL  LD rr,nn      IX/IY  DD/FD 21 nn      SP  LD SP,nn
    //   PC        just the closing JP, aimed at the new address
    // every script ends JP back (PC: JP target). I/R and the shadow set
    // are later scripts; index map: 0 AF, 1 BC, 2 DE, 3 HL, 4 IX, 5 IY,
    // 6 SP, 7 PC.
    reg [7:0]  sc [0:11];
    localparam [1:0] K_GET = 2'd0, K_SC = 2'd1, K_SETI = 2'd2, K_SETR = 2'd3;
    reg [1:0]  kind;
    reg [7:0]  set_val;

    wire [15:0] sp_orig = sp_base + 16'd1;

    always @(*) begin
        if (kind == K_SC)
            feed = sc[feed_i[3:0]];
        else if (kind == K_SETI || kind == K_SETR)
            // PUSH AF · LD A,val · LD I,A / LD R,A · POP AF (fed the
            // captured A/F back) · JP orig_PC
            case (feed_i)
                5'd0:  feed = 8'hF5;
                5'd1:  feed = 8'h3E;
                5'd2:  feed = set_val;
                5'd3:  feed = 8'hED;
                5'd4:  feed = (kind == K_SETI) ? 8'h47 : 8'h4F;
                5'd5:  feed = 8'hF1;
                5'd6:  feed = cap[1];
                5'd7:  feed = cap[0];
                5'd8:  feed = 8'hC3;
                5'd9:  feed = halt_pc[7:0];
                default: feed = halt_pc[15:8];
            endcase
        else
        case (feed_i)
            5'd0:  feed = 8'hF5;             // PUSH AF
            5'd1:  feed = 8'hC5;             // PUSH BC
            5'd2:  feed = 8'hD5;             // PUSH DE
            5'd3:  feed = 8'hE5;             // PUSH HL
            5'd4:  feed = 8'hDD;             // PUSH IX
            5'd5:  feed = 8'hE5;
            5'd6:  feed = 8'hFD;             // PUSH IY
            5'd7:  feed = 8'hE5;
            5'd8:  feed = 8'hED;             // LD A,I
            5'd9:  feed = 8'h57;
            5'd10: feed = 8'hF5;             // PUSH AF (A = I)
            5'd11: feed = 8'hED;             // LD A,R
            5'd12: feed = 8'h5F;
            5'd13: feed = 8'hF5;             // PUSH AF (A = R)
            5'd14: feed = 8'hD9;             // EXX
            5'd15: feed = 8'h08;             // EX AF,AF'
            5'd16: feed = 8'hF5;             // PUSH AF'
            5'd17: feed = 8'hC5;             // PUSH BC'
            5'd18: feed = 8'hD5;             // PUSH DE'
            5'd19: feed = 8'hE5;             // PUSH HL'
            5'd20: feed = 8'h08;             // EX AF,AF' back
            5'd21: feed = 8'hD9;             // EXX back
            5'd22: feed = 8'hF1;             // POP AF: restore A/F ...
            5'd23: feed = cap[1];            //   F (stack pops low first)
            5'd24: feed = cap[0];            //   A
            5'd25: feed = 8'h31;             // LD SP,orig
            5'd26: feed = sp_orig[7:0];
            5'd27: feed = sp_orig[15:8];
            5'd28: feed = 8'hC3;             // JP orig_PC
            5'd29: feed = halt_pc[7:0];
            default: feed = halt_pc[15:8];
        endcase
    end

    // ------------------------------------------------------------------
    // Host command engine
    // ------------------------------------------------------------------
    localparam [3:0]
        D_IDLE  = 4'd0,
        D_ARGS  = 4'd1,             // collect fixed argument bytes
        D_WHALT = 4'd2,             // wait for the freeze, then answer
        D_SEND  = 4'd3,             // emit resp[0..resp_n-1]
        D_MR_A  = 4'd4,             // read: drive address + RD
        D_MR_B  = 4'd5,             //       settle (registered reads)
        D_MR_C  = 4'd6,             //       capture, release RD
        D_MR_D  = 4'd7,             //       hand the byte to the host
        D_MW_RX = 4'd8,             // write: take a byte from the host
        D_MW_A  = 4'd9,             //        strobe WR
        D_MW_B  = 4'd10,
        D_MW_C  = 4'd11,
        D_WSTUF = 4'd12,            // registers: stuffing in flight
        D_RSEND = 4'd13;            // registers: stream the 29 bytes

    reg [3:0]  dstate;
    reg [7:0]  cmd;
    reg [7:0]  arg [0:3];
    reg [1:0]  arg_i;
    reg [2:0]  arg_need;
    reg [7:0]  resp [0:4];
    reg [2:0]  resp_n, send_i;
    reg [3:0]  after_send;
    reg [15:0] ptr, cnt;
    reg [4:0]  rs_i;

    integer k;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            run_mode  <= 1'b1;
            skip_one  <= 1'b0;
            cause     <= CAUSE_HOST;
            ev_pend   <= 1'b0;
            reset_seen <= 1'b0;
            bp_en     <= 8'h00;
            for (k = 0; k < 8; k = k + 1)
                bp_addr[k] <= 16'h0000;
            dstate    <= D_IDLE;
            cmd       <= 8'h00;
            arg[0] <= 8'h00; arg[1] <= 8'h00; arg[2] <= 8'h00; arg[3] <= 8'h00;
            arg_i     <= 2'd0;
            arg_need  <= 3'd0;
            resp[0] <= 8'h00; resp[1] <= 8'h00; resp[2] <= 8'h00;
            resp[3] <= 8'h00; resp[4] <= 8'h00;
            resp_n    <= 3'd0;
            send_i    <= 3'd0;
            after_send <= D_IDLE;
            ptr       <= 16'h0000;
            cnt       <= 16'h0000;
            in_ready  <= 1'b0;
            out_valid <= 1'b0;
            out_data  <= 8'h00;
            master    <= 1'b0;
            mst_addr  <= 16'h0000;
            mst_wdata <= 8'h00;
            mst_rd_n  <= 1'b1;
            mst_wr_n  <= 1'b1;
            stuff     <= 1'b0;
            feed_i    <= 5'd0;
            cap_i     <= 5'd0;
            sp_base   <= 16'h0000;
            halt_pc   <= 16'h0000;
            rd_d      <= 1'b1;
            wr_d2     <= 1'b1;
            rs_i      <= 5'd0;
            feed_last <= 5'd30;
            kind      <= K_GET;
            set_val   <= 8'h00;
            rdw_d     <= 1'b1;
            wrw_d     <= 1'b1;
            wp_rd     <= 4'h0;
            wp_wr     <= 4'h0;
            for (k = 0; k < 4; k = k + 1)
                wp_addr[k] <= 16'h0000;
            for (k = 0; k < 12; k = k + 1)
                sc[k] <= 8'h00;
            for (k = 0; k < 24; k = k + 1)
                cap[k] <= 8'h00;
        end else if (tgt_reset_edge) begin
            // the machine reset out from under us (front-panel button,
            // cold-start reload, or SYSRES* on the real adapter). Abandon
            // any in-flight command, let the target run free, wipe the now-
            // meaningless breakpoint/watchpoint state, and queue a
            // target-reset event so the host resyncs instead of hanging.
            stuff      <= 1'b0;
            master     <= 1'b0;
            mst_rd_n   <= 1'b1;
            mst_wr_n   <= 1'b1;
            run_mode   <= 1'b1;
            skip_one   <= 1'b0;
            bp_en      <= 8'h00;
            wp_rd      <= 4'h0;
            wp_wr      <= 4'h0;
            cause      <= CAUSE_RESET;
            ev_pend    <= 1'b1;
            reset_seen <= 1'b1;
            in_ready   <= 1'b0;
            out_valid  <= 1'b0;
            dstate     <= D_IDLE;
        end else begin
            // stuffing sequencer: captures every CPU write, advances the
            // feed on every completed CPU read
            rd_d  <= cpu_rd_n;
            wr_d2 <= cpu_wr_n;
            if (stuff) begin
                if (wr_d2 && !cpu_wr_n) begin        // write strobe begins
                    if (cap_i == 5'd0)
                        sp_base <= cpu_addr;
                    if (cap_i < 5'd24) begin
                        cap[cap_i[4:0]] <= bus;
                        cap_i <= cap_i + 5'd1;
                    end
                end
                if (!rd_d && cpu_rd_n) begin         // read done: consumed
                    if (feed_i == feed_last)
                        stuff <= 1'b0;               // JP operand was last
                    else
                        feed_i <= feed_i + 5'd1;
                end
            end
            // step bookkeeping: the boundary passes on the delivered enable
            if (skip_one && cpu_cen_raw && !freeze)
                skip_one <= 1'b0;

            // watchpoint edges + hit: request a halt at the next boundary
            rdw_d <= cpu_rd_n;
            wrw_d <= cpu_wr_n;
            if (run_mode && (wp_rd_hit || wp_wr_hit)) begin
                run_mode <= 1'b0;
                cause    <= CAUSE_WP;
                ev_pend  <= 1'b1;
            end

            // a breakpoint freeze while free-running becomes a halt + event
            if (run_mode && freeze) begin
                run_mode <= 1'b0;
                cause    <= CAUSE_BP;
                ev_pend  <= 1'b1;
            end

            in_ready  <= 1'b0;

            case (dstate)
                D_IDLE: begin
                    // a halt event waits for the freeze (so PC is the halt
                    // PC); a target-reset event ships immediately — the
                    // machine is running free, there is no boundary to wait
                    if (ev_pend && !out_valid
                        && (freeze || cause == CAUSE_RESET)) begin
                        ev_pend <= 1'b0;
                        resp[0] <= R_EVT;
                        resp[1] <= {5'd0, cause};
                        resp[2] <= cpu_addr[7:0];
                        resp[3] <= cpu_addr[15:8];
                        resp_n  <= 3'd4;
                        send_i  <= 3'd0;
                        after_send <= D_IDLE;
                        dstate  <= D_SEND;
                    end else begin
                        in_ready <= 1'b1;
                        if (in_valid && in_ready) begin
                            in_ready <= 1'b0;
                            cmd      <= in_data;
                            arg_i    <= 2'd0;
                            case (in_data)
                                C_RDM, C_WRM: begin
                                    arg_need <= 3'd4;
                                    dstate   <= D_ARGS;
                                end
                                C_SBP: begin
                                    arg_need <= 3'd4;
                                    dstate   <= D_ARGS;
                                end
                                C_SETR: begin
                                    arg_need <= 3'd3;
                                    dstate   <= D_ARGS;
                                end
                                C_SWP: begin
                                    arg_need <= 3'd4;
                                    dstate   <= D_ARGS;
                                end
                                C_HALT: begin
                                    run_mode <= 1'b0;
                                    cause    <= CAUSE_HOST;
                                    dstate   <= D_WHALT;
                                end
                                C_STEP: begin
                                    if (!run_mode && freeze) begin
                                        skip_one <= 1'b1;
                                        cause    <= CAUSE_STEP;
                                        dstate   <= D_WHALT;
                                    end else begin
                                        resp[0] <= R_ERR;
                                        resp_n  <= 3'd1;
                                        send_i  <= 3'd0;
                                        after_send <= D_IDLE;
                                        dstate  <= D_SEND;
                                    end
                                end
                                C_REGS: begin
                                    if (freeze) begin
                                        halt_pc <= cpu_addr;
                                        cap_i   <= 5'd0;
                                        feed_i  <= 5'd0;
                                        feed_last <= 5'd30;
                                        kind    <= K_GET;
                                        rd_d    <= 1'b1;
                                        wr_d2   <= 1'b1;
                                        rs_i    <= 5'd0;
                                        stuff   <= 1'b1;
                                        dstate  <= D_WSTUF;
                                    end else begin
                                        resp[0] <= R_ERR;
                                        resp_n  <= 3'd1;
                                        send_i  <= 3'd0;
                                        after_send <= D_IDLE;
                                        dstate  <= D_SEND;
                                    end
                                end
                                C_RUN: begin
                                    run_mode <= 1'b1;
                                    if (freeze)
                                        skip_one <= 1'b1;  // clear the bp
                                                           // under the PC
                                    resp[0]  <= C_RUN;
                                    resp_n   <= 3'd1;
                                    send_i   <= 3'd0;
                                    after_send <= D_IDLE;
                                    dstate   <= D_SEND;
                                end
                                C_STAT: begin
                                    resp[0] <= C_STAT;
                                    resp[1] <= {6'd0, reset_seen, ~run_mode};
                                    resp[2] <= {5'd0, cause};
                                    resp[3] <= cpu_addr[7:0];
                                    resp[4] <= cpu_addr[15:8];
                                    resp_n  <= 3'd5;
                                    send_i  <= 3'd0;
                                    after_send <= D_IDLE;
                                    dstate  <= D_SEND;
                                    reset_seen <= 1'b0;   // read-to-clear
                                end
                                default: begin
                                    resp[0] <= R_ERR;
                                    resp_n  <= 3'd1;
                                    send_i  <= 3'd0;
                                    after_send <= D_IDLE;
                                    dstate  <= D_SEND;
                                end
                            endcase
                        end
                    end
                end

                D_ARGS: begin
                    in_ready <= 1'b1;
                    if (in_valid && in_ready) begin
                        arg[arg_i] <= in_data;
                        arg_i      <= arg_i + 2'd1;
                        if ({1'b0, arg_i} + 3'd1 == arg_need) begin
                            in_ready <= 1'b0;
                            case (cmd)
                                C_SETR: begin
                                    if (!freeze || arg[0] > 8'd13) begin
                                        resp[0] <= R_ERR;
                                        resp_n  <= 3'd1;
                                        send_i  <= 3'd0;
                                        after_send <= D_IDLE;
                                        dstate  <= D_SEND;
                                    end else begin
                                        halt_pc <= cpu_addr;
                                        kind <= K_SC;
                                        case (arg[0][3:0])
                                            4'd0: begin        // AF
                                                sc[0] <= 8'hF5;
                                                sc[1] <= 8'hF1;
                                                sc[2] <= arg[1];      // F
                                                sc[3] <= in_data;     // A
                                                sc[4] <= 8'hC3;
                                                sc[5] <= cpu_addr[7:0];
                                                sc[6] <= cpu_addr[15:8];
                                                feed_last <= 5'd6;
                                            end
                                            4'd4, 4'd5: begin  // IX/IY
                                                sc[0] <= (arg[0][0])
                                                       ? 8'hFD : 8'hDD;
                                                sc[1] <= 8'h21;
                                                sc[2] <= arg[1];
                                                sc[3] <= in_data;
                                                sc[4] <= 8'hC3;
                                                sc[5] <= cpu_addr[7:0];
                                                sc[6] <= cpu_addr[15:8];
                                                feed_last <= 5'd6;
                                            end
                                            4'd7: begin        // PC
                                                sc[0] <= 8'hC3;
                                                sc[1] <= arg[1];
                                                sc[2] <= in_data;
                                                halt_pc <= {in_data, arg[1]};
                                                feed_last <= 5'd2;
                                            end
                                            4'd8, 4'd9: begin  // I / R
                                                kind    <= (arg[0][0])
                                                         ? K_SETR : K_SETI;
                                                set_val <= arg[1];
                                                feed_last <= 5'd10;
                                            end
                                            4'd10: begin       // AF'
                                                sc[0] <= 8'h08;
                                                sc[1] <= 8'hF5;
                                                sc[2] <= 8'hF1;
                                                sc[3] <= arg[1];      // F'
                                                sc[4] <= in_data;     // A'
                                                sc[5] <= 8'h08;
                                                sc[6] <= 8'hC3;
                                                sc[7] <= cpu_addr[7:0];
                                                sc[8] <= cpu_addr[15:8];
                                                feed_last <= 5'd8;
                                            end
                                            4'd11, 4'd12, 4'd13: begin
                                                sc[0] <= 8'hD9;    // EXX
                                                sc[1] <= (arg[0][1:0]==2'd3)
                                                       ? 8'h01            // BC'
                                                       : (arg[0][2])
                                                       ? 8'h11            // DE'
                                                       : 8'h21;           // HL'
                                                sc[2] <= arg[1];
                                                sc[3] <= in_data;
                                                sc[4] <= 8'hD9;
                                                sc[5] <= 8'hC3;
                                                sc[6] <= cpu_addr[7:0];
                                                sc[7] <= cpu_addr[15:8];
                                                feed_last <= 5'd7;
                                            end
                                            default: begin     // BC/DE/HL/SP
                                                sc[0] <= (arg[0][2])
                                                       ? 8'h31            // SP
                                                       : (arg[0][1:0]==2'd1)
                                                       ? 8'h01            // BC
                                                       : (arg[0][1:0]==2'd2)
                                                       ? 8'h11            // DE
                                                       : 8'h21;           // HL
                                                sc[1] <= arg[1];
                                                sc[2] <= in_data;
                                                sc[3] <= 8'hC3;
                                                sc[4] <= cpu_addr[7:0];
                                                sc[5] <= cpu_addr[15:8];
                                                feed_last <= 5'd5;
                                            end
                                        endcase
                                        cap_i  <= 5'd0;
                                        feed_i <= 5'd0;
                                        rd_d   <= 1'b1;
                                        wr_d2  <= 1'b1;
                                        stuff  <= 1'b1;
                                        dstate <= D_WHALT;
                                    end
                                end
                                C_SWP: begin
                                    if (arg[0] < 8'd4) begin
                                        wp_addr[arg[0][1:0]] <= {arg[2], arg[1]};
                                        wp_rd[arg[0][1:0]]   <= in_data[0];
                                        wp_wr[arg[0][1:0]]   <= in_data[1];
                                        resp[0] <= C_SWP;
                                    end else
                                        resp[0] <= R_ERR;
                                    resp_n  <= 3'd1;
                                    send_i  <= 3'd0;
                                    after_send <= D_IDLE;
                                    dstate  <= D_SEND;
                                end
                                C_SBP: begin
                                    if (arg[0] < 8'd8) begin
                                        bp_addr[arg[0][2:0]] <= {arg[2], arg[1]};
                                        bp_en[arg[0][2:0]]   <= in_data[0];
                                        resp[0] <= C_SBP;
                                    end else
                                        resp[0] <= R_ERR;
                                    resp_n  <= 3'd1;
                                    send_i  <= 3'd0;
                                    after_send <= D_IDLE;
                                    dstate  <= D_SEND;
                                end
                                default: begin   // C_RDM / C_WRM
                                    ptr <= {arg[1], arg[0]};
                                    cnt <= {in_data, arg[2]};
                                    if (run_mode || !freeze) begin
                                        resp[0] <= R_ERR;
                                        resp_n  <= 3'd1;
                                        send_i  <= 3'd0;
                                        after_send <= D_IDLE;
                                        dstate  <= D_SEND;
                                    end else if (cmd == C_RDM) begin
                                        resp[0] <= C_RDM;
                                        resp_n  <= 3'd1;
                                        send_i  <= 3'd0;
                                        after_send <= D_MR_A;
                                        dstate  <= D_SEND;
                                        master  <= 1'b1;
                                    end else begin
                                        master  <= 1'b1;
                                        dstate  <= D_MW_RX;
                                    end
                                end
                            endcase
                        end
                    end
                end

                D_WHALT:
                    if (freeze) begin
                        resp[0] <= cmd;
                        resp[1] <= cpu_addr[7:0];
                        resp[2] <= cpu_addr[15:8];
                        resp_n  <= 3'd3;
                        send_i  <= 3'd0;
                        after_send <= D_IDLE;
                        dstate  <= D_SEND;
                    end

                D_SEND: begin
                    if (!out_valid) begin
                        out_valid <= 1'b1;
                        out_data  <= resp[send_i];
                    end else if (out_ready) begin
                        out_valid <= 1'b0;
                        send_i    <= send_i + 3'd1;
                        if ({1'b0, send_i} + 3'd1 == {1'b0, resp_n})
                            dstate <= after_send;
                    end
                end

                // ---- memory read: one byte per pass ----
                D_MR_A: begin
                    if (cnt == 16'd0) begin
                        master <= 1'b0;
                        dstate <= D_IDLE;
                    end else begin
                        mst_addr <= ptr;
                        mst_rd_n <= 1'b0;
                        dstate   <= D_MR_B;
                    end
                end
                D_MR_B: dstate <= D_MR_C;
                D_MR_C: begin
                    out_data  <= bus;      // registered reads have settled
                    mst_rd_n  <= 1'b1;     // trailing edge: authentic side
                    dstate    <= D_MR_D;   // effects on device registers
                end
                D_MR_D: begin
                    if (!out_valid) begin
                        out_valid <= 1'b1;
                    end else if (out_ready) begin
                        out_valid <= 1'b0;
                        ptr       <= ptr + 16'd1;
                        cnt       <= cnt - 16'd1;
                        dstate    <= D_MR_A;
                    end
                end

                // ---- memory write: one byte per pass ----
                D_MW_RX: begin
                    if (cnt == 16'd0) begin
                        master  <= 1'b0;
                        resp[0] <= C_WRM;
                        resp_n  <= 3'd1;
                        send_i  <= 3'd0;
                        after_send <= D_IDLE;
                        dstate  <= D_SEND;
                    end else begin
                        in_ready <= 1'b1;
                        if (in_valid && in_ready) begin
                            in_ready  <= 1'b0;
                            mst_addr  <= ptr;
                            mst_wdata <= in_data;
                            mst_wr_n  <= 1'b0;
                            dstate    <= D_MW_A;
                        end
                    end
                end
                D_MW_A: dstate <= D_MW_B;
                D_MW_B: begin
                    mst_wr_n <= 1'b1;      // trailing edge: registers latch
                    dstate   <= D_MW_C;
                end
                D_MW_C: begin
                    ptr    <= ptr + 16'd1;
                    cnt    <= cnt - 16'd1;
                    dstate <= D_MW_RX;
                end

                // ---- register capture: wait out the stuffing, then
                //      stream echo + 24 captured bytes + SP + PC ----
                D_WSTUF:
                    if (!stuff && freeze)
                        dstate <= D_RSEND;

                D_RSEND: begin
                    if (!out_valid) begin
                        out_valid <= 1'b1;
                        out_data  <= (rs_i == 5'd0)  ? C_REGS
                                   : (rs_i <= 5'd24) ? cap[rs_i - 5'd1]
                                   : (rs_i == 5'd25) ? sp_orig[7:0]
                                   : (rs_i == 5'd26) ? sp_orig[15:8]
                                   : (rs_i == 5'd27) ? halt_pc[7:0]
                                   : (rs_i == 5'd28) ? halt_pc[15:8]
                                   : (rs_i == 5'd29) ? {6'd0, im_mode}
                                   :                   {7'd0, cpu_inte};
                    end else if (out_ready) begin
                        out_valid <= 1'b0;
                        rs_i      <= rs_i + 5'd1;
                        if (rs_i == 5'd30)
                            dstate <= D_IDLE;
                    end
                end

                default: dstate <= D_IDLE;
            endcase
        end
    end

    wire _unused_ok = &{1'b0, arg[3]};

endmodule
