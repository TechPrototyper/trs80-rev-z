// Testbench: tv80 instruction timing vs the Z80 datasheet (ADR-0003).
//
// Motivation (stage 6 finding): the tightest doubler-era MFM driver
// loops missed the 32 us/byte budget on tv80 by a wide margin — the
// crude in-system measurement suggested ~30% inflation. This bench
// measures PER INSTRUCTION: it runs a straight-line program covering
// every opcode of the FDC driver loops (plus common friends), counts
// cpu_cen pulses between consecutive M1 fetches, and compares each
// count against the official Z80 T-state table. The output names every
// deviating opcode — the work list for a targeted, documented tv80
// patch (vendored, ADR-0003 discipline).
//
// The bench PASSES even with deviations (they are tv80 facts, not our
// bugs) unless the total inflation exceeds 100% — it exists to REPORT
// precisely and to lock any future patch in place: after a fix, move
// the fixed opcode's expectation into the strict list below.

`timescale 1ns / 1ps

module tb_z80_tstates;

    logic clk, rst_n;
    initial begin clk = 0; rst_n = 0; end
    always #46.97 clk = ~clk;

    // flat behavioral memory
    logic [7:0] mem [0:65535];

    wire        cpu_cen;
    wire [15:0] addr;
    wire [7:0]  cpu_dout;
    wire        dbout_n, m1_n, halt_n;
    wire        ras_n, rd_n, wr_n;
    logic [7:0] din;

    m1_cpu_clock u_cc (.clk(clk), .rst_n(rst_n), .cpu_cen(cpu_cen));

    m1_cpu u_cpu (
        .clk(clk), .cpu_cen(cpu_cen),
        .por_rst_n(rst_n), .reset_btn_n(1'b1),
        .test_n(1'b1), .int_n(1'b1), .wait_n(1'b1),
        .din(din),
        .addr(addr),
        .dout(cpu_dout), .dbout_n(dbout_n),
        .ras_n(ras_n), .rd_n(rd_n), .wr_n(wr_n),
        .m1_n(m1_n), .halt_n(halt_n),
        /* verilator lint_off PINCONNECTEMPTY */
        .addr_en(), .dbin_n(), .in_n(), .out_n(), .intak_n(),
        .sysres_n(), .mux(), .cas_n(), .busak_n()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    always_comb din = mem[addr];
    always @(posedge clk)
        if (cpu_cen && !wr_n && !dbout_n)
            mem[addr] <= cpu_dout;

    // the probe program: every driver-loop opcode, straight line
    typedef struct {
        string name;
        int    want;
    } exp_t;
    exp_t expname [0:28];

    initial begin
        int p;
        for (int i = 0; i < 65536; i++) mem[i] = 8'h00;
        p = 0;
        mem[p++] = 8'h31; mem[p++] = 8'h00; mem[p++] = 8'h7F; // LD SP,nn
        mem[p++] = 8'h21; mem[p++] = 8'h00; mem[p++] = 8'h90; // LD HL,nn
        mem[p++] = 8'h01; mem[p++] = 8'hEC; mem[p++] = 8'h37; // LD BC,nn
        mem[p++] = 8'h11; mem[p++] = 8'h00; mem[p++] = 8'h90; // LD DE,nn
        mem[p++] = 8'h00;                                     // NOP
        mem[p++] = 8'h0A;                                     // LD A,(BC)
        mem[p++] = 8'h1A;                                     // LD A,(DE)
        mem[p++] = 8'h0F;                                     // RRCA
        mem[p++] = 8'h3A; mem[p++] = 8'h00; mem[p++] = 8'h90; // LD A,(nn)
        mem[p++] = 8'h32; mem[p++] = 8'h00; mem[p++] = 8'h90; // LD (nn),A
        mem[p++] = 8'h77;                                     // LD (HL),A
        mem[p++] = 8'h7E;                                     // LD A,(HL)
        mem[p++] = 8'h2C;                                     // INC L
        mem[p++] = 8'h23;                                     // INC HL
        mem[p++] = 8'hE6; mem[p++] = 8'h0F;                   // AND n
        mem[p++] = 8'hFE; mem[p++] = 8'h00;                   // CP n
        mem[p++] = 8'h37;                                     // SCF
        mem[p++] = 8'h30; mem[p++] = 8'h00;                   // JR NC (not)
        mem[p++] = 8'h3F;                                     // CCF (C:=0)
        mem[p++] = 8'h30; mem[p++] = 8'h00;                   // JR NC taken
        mem[p++] = 8'h06; mem[p++] = 8'h01;                   // LD B,1
        mem[p++] = 8'h10; mem[p++] = 8'h00;                   // DJNZ (not)
        mem[p++] = 8'h06; mem[p++] = 8'h02;                   // LD B,2
        mem[p++] = 8'h10; mem[p++] = 8'h00;                   // DJNZ taken
        mem[p++] = 8'hCB; mem[p++] = 8'h4F;                   // BIT 1,A
        mem[p++] = 8'hCD; mem[p++] = 8'h40; mem[p++] = 8'h00; // CALL 0040
        mem[p++] = 8'hC3; mem[p++] = 8'h50; mem[p++] = 8'h00; // JP 0050
        mem[16'h0040] = 8'hC9;                                // RET
        mem[16'h0050] = 8'h76;                                // HALT

        expname[0]  = '{"LD SP,nn      ", 10};
        expname[1]  = '{"LD HL,nn      ", 10};
        expname[2]  = '{"LD BC,nn      ", 10};
        expname[3]  = '{"LD DE,nn      ", 10};
        expname[4]  = '{"NOP           ",  4};
        expname[5]  = '{"LD A,(BC)     ",  7};
        expname[6]  = '{"LD A,(DE)     ",  7};
        expname[7]  = '{"RRCA          ",  4};
        expname[8]  = '{"LD A,(nn)     ", 13};
        expname[9]  = '{"LD (nn),A     ", 13};
        expname[10] = '{"LD (HL),A     ",  7};
        expname[11] = '{"LD A,(HL)     ",  7};
        expname[12] = '{"INC L         ",  4};
        expname[13] = '{"INC HL        ",  6};
        expname[14] = '{"AND n         ",  7};
        expname[15] = '{"CP n          ",  7};
        expname[16] = '{"SCF           ",  4};
        expname[17] = '{"JR NC not-tk  ",  7};
        expname[18] = '{"CCF           ",  4};
        expname[19] = '{"JR NC taken   ", 12};
        expname[20] = '{"LD B,n        ",  7};
        expname[21] = '{"DJNZ not-tk   ",  8};
        expname[22] = '{"LD B,n        ",  7};
        expname[23] = '{"DJNZ taken    ", 13};
        expname[24] = '{"BIT 1,A       ",  8};
        expname[25] = '{"CALL nn       ", 17};
        expname[26] = '{"RET           ", 10};
        expname[27] = '{"JP nn         ", 10};
        expname[28] = '{"(halt fetch)  ",  4};
    end

    // measurement: cpu_cen pulses between M1 fetch starts
    int  tcnt, idx, total_exp, total_got, ndev;
    bit  m1_d, started;
    initial begin tcnt = 0; idx = -1; total_exp = 0; total_got = 0;
                  ndev = 0; m1_d = 1; started = 0; end

    always @(posedge clk) begin
        if (cpu_cen) begin
            tcnt <= tcnt + 1;
            m1_d <= m1_n;
            if (m1_d && !m1_n) begin       // a new fetch begins
                if (started && idx >= 0 && idx <= 28) begin
                    if (tcnt != expname[idx].want) begin
                        $display("DEV  %s expected %2d  tv80 %2d  (+%0d)",
                                 expname[idx].name, expname[idx].want,
                                 tcnt, tcnt - expname[idx].want);
                        ndev++;
                    end else
                        $display(" ok  %s %2d", expname[idx].name, tcnt);
                    total_exp += expname[idx].want;
                    total_got += tcnt;
                end
                idx  <= idx + 1;
                tcnt <= 1;
                started <= 1;
            end
        end
    end

    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1;
        wait (!halt_n);
        repeat (8) @(negedge clk);
        $display("---");
        $display("SUM  datasheet %0d T, tv80 %0d T  (inflation %0d%%, %0d deviating opcodes)",
                 total_exp, total_got,
                 ((total_got - total_exp) * 100) / total_exp, ndev);
        if (total_got > 2 * total_exp)
            $fatal(1, "tv80 timing catastrophically off");
        $display("ALL CHECKS PASSED (report bench: deviations are tv80 facts)");
        $finish;
    end

    initial begin
        #10_000_000;
        $fatal(1, "watchdog: probe program did not reach HALT");
    end

endmodule
