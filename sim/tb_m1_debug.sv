// Testbench: the debug core, stage A (ADR-0006).
//
// Drives m1_debug through m1_core's host byte port like the future ESP32
// debug server will, against the prefix-heavy image from
// tools/build_dbg_test.py, and proves the mechanism:
//   - HALT freezes the machine at an instruction boundary (cpu_cen stays
//     silent while halted) and reports PC
//   - a hardware breakpoint stops the free-running machine exactly at its
//     address and pushes the async event
//   - STEP walks the loop one INSTRUCTION at a time — the DD/FD, ED, CB
//     and DD CB prefix chains each count as one step (the exact PC
//     sequence is asserted)
//   - READ_MEM under halt returns ROM bytes identical to the image and
//     the RAM byte the program wrote; WRITE_MEM plants a byte the
//     running program can see; both refuse while running (0xEE)
//   - RUN resumes across the breakpoint under the PC and re-arms it (the
//     next loop iteration hits again)

`timescale 1ns / 1ps

module tb_m1_debug;

    logic clk, rst_n;
    /* verilator lint_off SYNCASYNCNET */
    logic mach_rst_n;   // async reset into m1_core, pulsed from the TB body
    /* verilator lint_on SYNCASYNCNET */
    initial begin clk = 0; rst_n = 0; mach_rst_n = 0; end
    always #46.97 clk = ~clk;
    // rst_n = the debug subsystem reset (FPGA POR domain); mach_rst_n =
    // the machine reset, pulsed separately so a target reset can happen
    // with the debugger standing (ADR-0006 §3a).

    int errors = 0;

    logic        ld_en;
    logic [13:0] ld_addr;
    logic [7:0]  ld_data;

    logic       h_in_valid;
    logic [7:0] h_in_data;
    wire        h_in_ready;
    wire        h_out_valid;
    wire  [7:0] h_out_data;
    logic       h_out_ready;

    m1_core u_core (
        .clk(clk), .por_rst_n(mach_rst_n), .dbg_rst_n(rst_n),
        .reset_btn_n(1'b1),
        .test_n(1'b1), .int_n(1'b1), .wait_n(1'b1),
        .ld_en(ld_en), .ld_addr(ld_addr), .ld_data(ld_data),
        .ei_ram_cfg(2'b00),
        .fdc_disk(4'b0000), .fdc_wp(4'b0000), .percom_en(1'b0),
        .trk_vld(1'b0), .trk_data(8'h00), .trk_idx(13'd0),
        .trk_done(1'b0), .trk_err(1'b0), .trk_len(13'd0), .trk_dbl(1'b0),
        .trk_wb_fetch(1'b0), .trk_wb_idx(13'd0),
        .trk_wb_done(1'b0), .trk_wb_err(1'b0),
        .dbg_in_valid(h_in_valid), .dbg_in_data(h_in_data),
        .dbg_in_ready(h_in_ready),
        .dbg_out_valid(h_out_valid), .dbg_out_data(h_out_data),
        .dbg_out_ready(h_out_ready),
        .keys('0),
        .cass_in(1'b0),
        /* verilator lint_off PINCONNECTEMPTY */
        .trk_req(), .trk_drv(), .trk_track(), .trk_side(), .trk_wb_req(),
        .trk_wb_data(),
        .cass_out(), .cass_motor(), .hdrv(), .vdrv(), .dot_en(),
        .cpu_cen(), .modesel(), .addr(), .m1_n(), .halt_n(),
        .pixel(), .col(), .line(), .row(), .snd()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    logic [7:0] image [0:4095];
    initial $readmemh("build/dbgtest.hex", image);

    // ---- host driver (one posedge per handshake, race-free) ----
    task automatic send(input logic [7:0] b);
        @(negedge clk);
        h_in_valid = 1;
        h_in_data  = b;
        while (!h_in_ready) @(negedge clk);
        @(posedge clk);          // the consuming edge
        #1 h_in_valid = 0;
    endtask

    task automatic recv(output logic [7:0] b);
        @(negedge clk);
        while (!h_out_valid) @(negedge clk);
        b = h_out_data;
        h_out_ready = 1;
        @(posedge clk);          // the consuming edge
        #1 h_out_ready = 0;
    endtask

    task automatic expect_byte(input logic [7:0] want, input string what);
        logic [7:0] got;
        recv(got);
        if (got !== want) begin
            $display("FAIL  %s: got %02h, expected %02h", what, got, want);
            errors++;
        end
    endtask

    task automatic recv_pc(output logic [15:0] pc);
        logic [7:0] lo, hi;
        recv(lo); recv(hi);
        pc = {hi, lo};
    endtask

    // HALT/STEP: echo + PC
    task automatic do_halt(output logic [15:0] pc);
        send(8'h01); expect_byte(8'h01, "HALT echo"); recv_pc(pc);
    endtask

    task automatic do_step(output logic [15:0] pc);
        send(8'h03); expect_byte(8'h03, "STEP echo"); recv_pc(pc);
    endtask

    task automatic step_expect(input logic [15:0] want, input string what);
        logic [15:0] pc;
        do_step(pc);
        if (pc !== want) begin
            $display("FAIL  %s: PC %04h, expected %04h", what, pc, want);
            errors++;
        end
    endtask

    task automatic set_bp(input logic [2:0] idx, input logic [15:0] a,
                          input logic en);
        send(8'h08); send({5'd0, idx});
        send(a[7:0]); send(a[15:8]); send({7'd0, en});
        expect_byte(8'h08, "SET_BP echo");
    endtask

    task automatic rd_mem(input logic [15:0] a, input logic [15:0] n);
        send(8'h06); send(a[7:0]); send(a[15:8]);
        send(n[7:0]); send(n[15:8]);
        expect_byte(8'h06, "READ_MEM echo");
    endtask

`ifdef STUFFDBG
    reg frz_d;
    initial frz_d = 0;
    always @(posedge clk) begin
        frz_d <= u_core.u_dbg.freeze;
        if (!frz_d && u_core.u_dbg.freeze)
            $display("FRZ up   pc=%04h t=%0t", u_core.addr, $time);
        if (frz_d && !u_core.u_dbg.freeze)
            $display("FRZ down pc=%04h stuff=%b skip=%b t=%0t", u_core.addr,
                     u_core.u_dbg.stuff, u_core.u_dbg.skip_one, $time);
    end
    reg wrp_d, rdp_d;
    initial begin wrp_d = 1; rdp_d = 1; end
    always @(posedge clk) begin
        wrp_d <= u_core.u_cpu.wr_n;
        rdp_d <= u_core.u_cpu.rd_n;
        if (u_core.u_dbg.stuff && u_core.u_dbg.kind == 2'd2) begin
            if (wrp_d && !u_core.u_cpu.wr_n)
                $display("SETI WR cap_i=%0d addr=%04h bus=%02h",
                         u_core.u_dbg.cap_i, u_core.addr, u_core.bus);
            if (!rdp_d && u_core.u_cpu.rd_n)
                $display("SETI RD done feed_i=%0d fed=%02h addr=%04h",
                         u_core.u_dbg.feed_i, u_core.u_dbg.feed,
                         u_core.addr);
        end
    end
`endif

    int cen_pulses;
    always @(posedge clk)
        if (u_core.cpu_cen) cen_pulses <= cen_pulses + 1;

    initial begin
        int i;
        logic [7:0]  b;
        logic [15:0] pc;
        int snap;

        ld_en = 0; ld_addr = 0; ld_data = 0;
        h_in_valid = 0; h_in_data = 0; h_out_ready = 0;
        cen_pulses = 0;

        repeat (4) @(negedge clk);
        for (i = 0; i < 4096; i++) begin   // machine held in reset to load
            @(negedge clk);
            ld_en   = 1;
            ld_addr = 14'(i);
            ld_data = image[i];
        end
        @(negedge clk);
        ld_en = 0;
        rst_n = 1;                         // debug subsystem alive FIRST,
        repeat (30) @(negedge clk);        // while the machine is still
        mach_rst_n = 1;                    // held in reset (the real boot
                                           // order) — must NOT look like a
                                           // target reset

        // let the program run into its loop and prove RAM sees the write
        #300_000;

        // the boot sequence above must not have produced a reset event:
        // STATUS must show the sticky clear
        send(8'h09); expect_byte(8'h09, "STATUS echo at boot");
        recv(b);
        if (b[1] !== 1'b0) begin
            $display("FAIL  phantom reset-seen at boot (%02h)", b);
            errors++;
        end
        recv(b); recv(b); recv(b);

        // ---- READ_MEM while running: served NON-INTRUSIVELY from the
        //      memories' second BRAM ports (DEBUG-PROTOCOL.md) — correct
        //      data from every region, and the CPU keeps running ----
        snap = cen_pulses;
        rd_mem(16'h0010, 16'd24);              // ROM == the loaded image
        for (i = 0; i < 24; i++) begin
            recv(b);
            if (b !== image[32'h0010 + i]) begin
                $display("FAIL  ni ROM[%04h] read %02h, image %02h",
                         32'h0010 + i, b, image[32'h0010 + i]);
                errors++;
            end
        end
        rd_mem(16'h4100, 16'd1);               // the program's own write
        expect_byte(8'h55, "ni RAM[4100] while running");
        rd_mem(16'h3C00, 16'd1);               // unwritten VRAM: bit-6 fold
        expect_byte(8'h40, "ni VRAM[3C00] while running");
        rd_mem(16'h3801, 16'd1);               // keyboard row, no keys down
        expect_byte(8'h00, "ni keyboard row while running");
        rd_mem(16'h8000, 16'd1);               // EI bank unpopulated (cfg 00)
        expect_byte(8'hFF, "ni EI RAM (unpopulated) while running");
        rd_mem(16'h3700, 16'd1);               // device window: never touched
        expect_byte(8'hFF, "ni device window while running");
        if (cen_pulses == snap) begin
            $display("FAIL  CPU stalled during non-intrusive reads");
            errors++;
        end

        // ---- WRITE_MEM while running still refuses ----
        send(8'h07); send(8'h00); send(8'h41); send(8'h01); send(8'h00);
        expect_byte(8'hEE, "WRITE_MEM refused while running");

        // ---- HALT: freeze at a boundary, cen goes silent ----
        do_halt(pc);
        if (pc < 16'h0010 || pc > 16'h0027) begin
            $display("FAIL  HALT PC %04h outside the loop", pc);
            errors++;
        end
        snap = cen_pulses;
        #100_000;
        if (cen_pulses != snap) begin
            $display("FAIL  cpu_cen pulsed %0d times while halted",
                     cen_pulses - snap);
            errors++;
        end

        // ---- READ_MEM: ROM must equal the image ----
        rd_mem(16'h0010, 16'd24);
        for (i = 0; i < 24; i++) begin
            recv(b);
            if (b !== image[32'h0010 + i]) begin
                $display("FAIL  ROM[%04h] read %02h, image %02h",
                         32'h0010 + i, b, image[32'h0010 + i]);
                errors++;
            end
        end

        // ---- the program's own write must be visible ----
        rd_mem(16'h4100, 16'd1);
        recv(b);
        if (b !== 8'h55) begin
            $display("FAIL  RAM[4100] = %02h, expected 55", b);
            errors++;
        end

        // ---- WRITE_MEM plants a byte; read it back ----
        send(8'h07); send(8'h02); send(8'h41); send(8'h01); send(8'h00);
        send(8'hA7);
        expect_byte(8'h07, "WRITE_MEM echo");
        rd_mem(16'h4102, 16'd1);
        expect_byte(8'hA7, "RAM[4102] readback");

        // ---- breakpoint at the loop head, then RUN ----
        set_bp(3'd0, 16'h0010, 1'b1);
        send(8'h02); expect_byte(8'h02, "RUN echo");
        expect_byte(8'h80, "BP event marker");
        expect_byte(8'h01, "BP event cause");
        recv_pc(pc);
        if (pc !== 16'h0010) begin
            $display("FAIL  BP stop at %04h, expected 0010", pc);
            errors++;
        end

        // ---- single-step the whole loop: prefixes are one step each ----
        step_expect(16'h0014, "step over DD 21 (LD IX,nn)");
        step_expect(16'h0018, "step over FD 21 (LD IY,nn)");
        step_expect(16'h001A, "step over ED 44 (NEG)");
        step_expect(16'h001C, "step over CB 07 (RLC A)");
        step_expect(16'h0020, "step over DD CB (RLC (IX+d))");
        step_expect(16'h0022, "step over LD A,n");
        step_expect(16'h0025, "step over LD (nn),A");
        step_expect(16'h0010, "step over JP back to the loop head");

        // ---- STATUS while halted ----
        send(8'h09);
        expect_byte(8'h09, "STATUS echo");
        expect_byte(8'h01, "STATUS halted flag");
        expect_byte(8'h02, "STATUS cause (step)");
        recv_pc(pc);
        if (pc !== 16'h0010) begin
            $display("FAIL  STATUS PC %04h, expected 0010", pc);
            errors++;
        end

        // ---- RUN off the breakpoint under the PC: next lap hits again --
        send(8'h02); expect_byte(8'h02, "RUN echo (off the bp)");
        expect_byte(8'h80, "BP re-hit marker");
        expect_byte(8'h01, "BP re-hit cause");
        recv_pc(pc);
        if (pc !== 16'h0010) begin
            $display("FAIL  BP re-hit at %04h, expected 0010", pc);
            errors++;
        end

        // ---- clear the bp, run free, halt again on request ----
        set_bp(3'd0, 16'h0010, 1'b0);
        send(8'h02); expect_byte(8'h02, "RUN echo (bp cleared)");
        #300_000;
        do_halt(pc);
        if (pc < 16'h0010 || pc > 16'h0027) begin
            $display("FAIL  re-HALT PC %04h outside the loop", pc);
            errors++;
        end

        // ---- GET_REGS via instruction stuffing (stage B) ----
        // walk to a PC with fully determined registers: 0x0018 is after
        // LD IX,1234 / LD IY,5678, and A holds the 0x55 of the last lap
        for (i = 0; i < 10 && pc != 16'h0018; i++) do_step(pc);
        if (pc !== 16'h0018) begin
            $display("FAIL  could not step to 0018 (at %04h)", pc);
            errors++;
        end

        begin
            logic [7:0] r1 [0:29];
            logic [7:0] r2 [0:29];
            send(8'h04); expect_byte(8'h04, "GET_REGS echo");
            for (i = 0; i < 30; i++) recv(r1[i]);
            // A F B C D E H L IXh IXl IYh IYl I f R f A' F' B' C' D' E'
            // H' L'  sp_lo sp_hi pc_lo pc_hi
            if (r1[0]  !== 8'h55) begin $display("FAIL  A  = %02h, expected 55", r1[0]);  errors++; end
            if (r1[8]  !== 8'h12) begin $display("FAIL  IXh= %02h, expected 12", r1[8]);  errors++; end
            if (r1[9]  !== 8'h34) begin $display("FAIL  IXl= %02h, expected 34", r1[9]);  errors++; end
            if (r1[10] !== 8'h56) begin $display("FAIL  IYh= %02h, expected 56", r1[10]); errors++; end
            if (r1[11] !== 8'h78) begin $display("FAIL  IYl= %02h, expected 78", r1[11]); errors++; end
            if (r1[12] !== 8'h00) begin $display("FAIL  I  = %02h, expected 00", r1[12]); errors++; end
            if (r1[28] !== 8'h01) begin
                $display("FAIL  IM = %02h, expected 01 (tracked ED 56)", r1[28]);
                errors++;
            end
            if (r1[29] !== 8'h00) begin
                $display("FAIL  IFF = %02h, expected 00 (DI)", r1[29]);
                errors++;
            end
            if ({r1[25], r1[24]} !== 16'h7FFF) begin
                $display("FAIL  SP = %02h%02h, expected 7FFF", r1[25], r1[24]);
                errors++;
            end
            if ({r1[27], r1[26]} !== 16'h0018) begin
                $display("FAIL  regs PC = %02h%02h, expected 0018", r1[27], r1[26]);
                errors++;
            end

            // the capture must be repeatable: nothing was perturbed
            // (except R, which advances on a real Z80 ICE the same way)
            send(8'h04); expect_byte(8'h04, "GET_REGS echo (2nd)");
            for (i = 0; i < 30; i++) recv(r2[i]);
            for (i = 0; i < 30; i++)
                if (i != 14 && r2[i] !== r1[i]) begin
                    $display("FAIL  regs[%0d] changed %02h -> %02h",
                             i, r1[i], r2[i]);
                    errors++;
                end
        end

        // and the machine still steps correctly from the restored state
        step_expect(16'h001A, "step after register capture (ED 44)");
        step_expect(16'h001C, "step after register capture (CB 07)");

        // ---- SET_REG: plant HL, verify via GET_REGS, then move PC ----
        send(8'h05); send(8'h03); send(8'hFE); send(8'hCA);   // HL = CAFE
        expect_byte(8'h05, "SET_REG HL echo");
        recv_pc(pc);
        if (pc !== 16'h001C) begin
            $display("FAIL  SET_REG HL returned PC %04h, expected 001C", pc);
            errors++;
        end
        begin
            logic [7:0] r3 [0:29];
            send(8'h04); expect_byte(8'h04, "GET_REGS echo (after set)");
            for (i = 0; i < 30; i++) recv(r3[i]);
            if (r3[6] !== 8'hCA || r3[7] !== 8'hFE) begin
                $display("FAIL  HL = %02h%02h, expected CAFE", r3[6], r3[7]);
                errors++;
            end
            if (r3[8] !== 8'h12 || r3[9] !== 8'h34) begin
                $display("FAIL  IX disturbed by SET_REG HL");
                errors++;
            end
        end
        send(8'h05); send(8'h07); send(8'h10); send(8'h00);   // PC = 0010
        expect_byte(8'h05, "SET_REG PC echo");
        recv_pc(pc);
        if (pc !== 16'h0010) begin
            $display("FAIL  SET_REG PC returned %04h, expected 0010", pc);
            errors++;
        end
        step_expect(16'h0014, "step after PC set (LD IX,nn again)");

        // ---- shadow + I setters through the same machinery ----
        send(8'h05); send(8'h0B); send(8'h22); send(8'h11);  // BC' = 1122
        expect_byte(8'h05, "SET_REG BC' echo"); recv_pc(pc);
        send(8'h05); send(8'h08); send(8'h30); send(8'h00);  // I = 30
        expect_byte(8'h05, "SET_REG I echo"); recv_pc(pc);
        begin
            logic [7:0] r4 [0:29];
            send(8'h04); expect_byte(8'h04, "GET_REGS echo (shadow/I)");
            for (i = 0; i < 30; i++) recv(r4[i]);
            if (r4[18] !== 8'h11 || r4[19] !== 8'h22) begin
                $display("FAIL  BC' = %02h%02h, expected 1122",
                         r4[18], r4[19]);
                errors++;
            end
            if (r4[12] !== 8'h30) begin
                $display("FAIL  I = %02h, expected 30", r4[12]);
                errors++;
            end
            // A here is 0x57: the earlier steps executed NEG (55->AB)
            // and RLC A (AB->57); the setters must have PRESERVED that
            if (r4[0] !== 8'h57) begin
                $display("FAIL  A disturbed by the setters: %02h", r4[0]);
                errors++;
            end
        end

        // ---- watchpoint: the program's own write to 4100 trips it ----
        send(8'h0A); send(8'h00); send(8'h00); send(8'h41); send(8'h02);
        expect_byte(8'h0A, "SET_WP echo");
        send(8'h02); expect_byte(8'h02, "RUN echo (wp armed)");
        expect_byte(8'h80, "WP event marker");
        expect_byte(8'h03, "WP event cause");
        recv_pc(pc);
        if (pc !== 16'h0025) begin
            $display("FAIL  WP stop at %04h, expected 0025", pc);
            errors++;
        end
        send(8'h0A); send(8'h00); send(8'h00); send(8'h41); send(8'h00);
        expect_byte(8'h0A, "SET_WP clear echo");
        send(8'h02); expect_byte(8'h02, "RUN echo (wp cleared)");
        #200_000;

        // ---- the target resets out from under the debugger (ADR-0006) ----
        // halt first, arm a breakpoint, then pulse the MACHINE reset while
        // the debug subsystem stands: it must emit a target-reset event and
        // the sticky STATUS bit, and afterwards still work.
        do_halt(pc);
        set_bp(3'd0, 16'h0018, 1'b1);
        mach_rst_n = 0;                    // front-panel/cold-start reset
        repeat (20) @(negedge clk);
        mach_rst_n = 1;
        expect_byte(8'h80, "target-reset event marker");
        expect_byte(8'h04, "target-reset cause");
        recv_pc(pc);
        // the debug core survived: STATUS answers, sticky set then clears,
        // and the breakpoint state was wiped by the reset
        send(8'h09); expect_byte(8'h09, "STATUS echo after reset");
        recv(b);
        if (b[1] !== 1'b1) begin
            $display("FAIL  reset-seen sticky not set (%02h)", b);
            errors++;
        end
        recv(b); recv(b); recv(b);          // cause + pc
        send(8'h09); expect_byte(8'h09, "STATUS echo (sticky cleared)");
        recv(b);
        if (b[1] !== 1'b0) begin
            $display("FAIL  reset-seen sticky did not clear (%02h)", b);
            errors++;
        end
        recv(b); recv(b); recv(b);
        // and the debugger still commands the machine after the reset: the
        // target restarted at its reset vector, so pin PC to a known spot
        // and prove a step still advances on the instruction map
        do_halt(pc);
        send(8'h05); send(8'h07); send(8'h10); send(8'h00);   // PC = 0010
        expect_byte(8'h05, "SET_REG PC after reset"); recv_pc(pc);
        step_expect(16'h0014, "step still works after a target reset");

        if (errors == 0) $display("ALL CHECKS PASSED (debug core stage A)");
        else             $display("%0d CHECKS FAILED", errors);
        if (errors != 0) $fatal(1);
        $finish;
    end

    initial begin
        #40_000_000;
        $display("WDG dbg: dstate=%0d stuff=%b feed_i=%0d cap_i=%0d rs_i=%0d freeze=%b run=%b pc=%04h rd_n=%b wr_n=%b",
                 u_core.u_dbg.dstate, u_core.u_dbg.stuff,
                 u_core.u_dbg.feed_i, u_core.u_dbg.cap_i,
                 u_core.u_dbg.rs_i, u_core.u_dbg.freeze,
                 u_core.u_dbg.run_mode, u_core.addr,
                 u_core.rd_n, u_core.wr_n);
        $fatal(1, "watchdog: debug bench did not finish");
    end

endmodule
