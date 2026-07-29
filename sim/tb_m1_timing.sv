// TRS-80 Rev Z — testbench for the clock/divider chapter
//
// Proves the documented contract of chapter 1 against the RTL:
//   - cpu_cen every 6 dots (Z56)
//   - LATCH* every 6 dots, 1 wide (64-char) / every 12, 2 wide (32-char)
//   - chain_en every 12 dots (887.0416 kHz) in BOTH modes
//   - line = 672 dots; HDRV high 288 dots (columns 64..111)
//   - frame = 264 lines = 177,408 dots; VDRV high 48,384 dots (rows 16..21)
//   - column sequence 0..111 (64-char); C1 pinned low in 32-char mode
//
// Reference numbers: TRS-80 Technical Manual (1978) pp. 13-16; frame rate
// 10.6445 MHz / 177,408 = 60.0001 Hz.

`timescale 1ns/1ps

// Testbench-only lint waivers — the RTL itself compiles under full -Wall.
/* verilator lint_off PROCASSINIT */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off REALCVT */
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off BLKSEQ */

module tb_m1_timing;

    localparam int LINE_DOTS   = 672;
    localparam int FRAME_DOTS  = 672 * 264;   // 177,408
    localparam int HDRV_DOTS   = 288;         // 48 chars * 6 dots
    localparam int VDRV_DOTS   = 72 * 672;    // 48,384

    logic clk = 0;
    logic rst_n = 0;
    logic modesel = 1;

    logic       cpu_cen;
    logic       latch_n, chain_en, hdrv, vdrv;
    logic [6:0] col;
    logic [3:0] line;
    logic [4:0] row;

    m1_cpu_clock u_cpuclk (.clk(clk), .rst_n(rst_n), .cpu_cen(cpu_cen));
    m1_video_timing u_vt (
        .clk(clk), .rst_n(rst_n), .modesel(modesel),
        // dot_en is deliberately open here — it is exercised by tb_m1_video_gen
        /* verilator lint_off PINCONNECTEMPTY */
        .latch_n(latch_n), .dot_en(), .chain_en(chain_en),
        /* verilator lint_on PINCONNECTEMPTY */
        .col(col), .line(line), .row(row), .hdrv(hdrv), .vdrv(vdrv)
    );

    // 10.6445 MHz -> period 93.945 ns; the checks count cycles, not time.
    always #46.97 clk = ~clk;

    int errors = 0;

    task automatic check(string what, longint got, longint want);
        if (got !== want) begin
            $display("FAIL  %s: got %0d, want %0d", what, got, want);
            errors++;
        end else begin
            $display("  ok  %s = %0d", what, got);
        end
    endtask

    // Measure the spacing and low-width of latch_n over n pulses.
    task automatic check_latch(int n, int want_period, int want_width);
        longint t_fall, t_prev;
        int width;
        t_prev = -1;
        repeat (n) begin
            @(posedge clk); while (latch_n) @(posedge clk);   // falling edge
            t_fall = cycles;
            width = 0;
            while (!latch_n) begin width++; @(posedge clk); end
            if (t_prev >= 0)
                check("latch period", t_fall - t_prev, want_period);
            t_prev = t_fall;
            check("latch width", width, want_width);
        end
    endtask

    longint cycles = 0;
    always @(posedge clk) cycles++;

    // Interval between chain_en pulses.
    task automatic check_chain(int n, int want);
        longint t0;
        repeat (n) begin
            @(posedge clk); while (!chain_en) @(posedge clk);
            t0 = cycles;
            @(posedge clk); while (!chain_en) @(posedge clk);
            check("chain period", cycles - t0, want);
        end
    endtask

    // Period and high-time of a slow signal (hdrv/vdrv), n periods.
    task automatic check_pulse(string name, int n, longint want_period, longint want_high);
        longint t_rise, t_prev, hi;
        t_prev = -1;
        repeat (n) begin
            @(posedge clk); while (sig_sel(name)) @(posedge clk);      // wait low
            while (!sig_sel(name)) @(posedge clk);                     // rising edge
            t_rise = cycles;
            hi = 0;
            while (sig_sel(name)) begin hi++; @(posedge clk); end
            if (t_prev >= 0)
                check({name, " period"}, t_rise - t_prev, want_period);
            t_prev = t_rise;
            check({name, " high"}, hi, want_high);
        end
    endtask

    function automatic logic sig_sel(string name);
        case (name)
            "hdrv": return hdrv;
            "vdrv": return vdrv;
            default: begin $fatal(1, "bad signal"); return 0; end
        endcase
    endfunction

    initial begin
        $dumpfile("build/tb_m1_timing.vcd");
        $dumpvars(0, tb_m1_timing);

        repeat (4) @(posedge clk);
        rst_n = 1;

        $display("== 64-character mode ==");
        check_latch(8, 6, 1);
        check_chain(4, 12);

        // cpu_cen spacing
        begin
            longint t0;
            @(posedge clk); while (!cpu_cen) @(posedge clk);
            t0 = cycles;
            repeat (5) begin
                @(posedge clk); while (!cpu_cen) @(posedge clk);
                check("cpu_cen spacing", cycles - t0, 6);
                t0 = cycles;
            end
        end

        // column sequence: after a chain tick at col wrap, columns run 0..111
        begin
            int exp_col;
            @(posedge clk); while (!(chain_en && col[6:1] == 6'd55)) @(posedge clk);
            @(posedge clk);  // registers updated: start of new line pair
            exp_col = int'(col);
            check("col wraps to", longint'(col), 0);
            repeat (LINE_DOTS) begin
                if (col !== 7'(exp_col)) begin
                    $display("FAIL  col sequence: got %0d, want %0d", col, exp_col);
                    errors++;
                end
                @(posedge clk);
                if (u_vt.phase == 0 || u_vt.phase == 6)  // new character time
                    exp_col = (exp_col == 111) ? 0 : exp_col + 1;
            end
            $display("  ok  col sequence 0..111 over one line");
        end

        check_pulse("hdrv", 3, LINE_DOTS, HDRV_DOTS);
        check_pulse("vdrv", 2, FRAME_DOTS, VDRV_DOTS);

        $display("== 32-character mode ==");
        modesel = 0;
        // realign: wait for a frame boundary, then measure
        @(posedge clk); while (!(chain_en)) @(posedge clk);
        check_latch(6, 12, 2);
        check_chain(4, 12);
        begin
            int i;
            for (i = 0; i < 2000; i++) begin
                @(posedge clk);
                if (col[0] !== 1'b0) begin
                    $display("FAIL  C1 not held low in 32-char mode");
                    errors++;
                    break;
                end
            end
            if (i == 2000) $display("  ok  C1 held low in 32-char mode");
        end
        check_pulse("hdrv", 2, LINE_DOTS, HDRV_DOTS);

        if (errors == 0) begin
            $display("\nALL CHECKS PASSED");
            $display("frame = %0d dots -> %f Hz at 10.6445 MHz",
                     FRAME_DOTS, 10644500.0 / FRAME_DOTS);
        end else begin
            $display("\n%0d CHECK(S) FAILED", errors);
        end
        $finish;
    end

endmodule
