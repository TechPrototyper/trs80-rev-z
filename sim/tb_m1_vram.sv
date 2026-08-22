// Testbench: m1_vram — video RAM, address multiplexers, CPU arbitration.
//
// First bench to wire the full chain: m1_video_timing -> m1_vram ->
// m1_video_gen. A small Z80-shaped bus model (3 T-states of ~VID per
// access, strobes in the middle) plays the CPU. Proves:
//   - CPU write/readback through the muxes for all 1024 cells; the bit-6
//     quirks (written bit 6 dropped, read bit 6 = NOR(bit5,bit7)),
//   - R49 isolation: strobes without ~VID neither write nor drive the bus,
//   - the video address map VA = {R,C} (row*64+col), by checking every dot
//     of a full frame against an independent model fed from a shadow RAM,
//   - the beam-hack property (SPEC §6b): CPU traffic placed in the blanking
//     intervals leaves a frame byte-identical to an undisturbed one,
//   - emergent black streaks (SPEC §6a): traffic aimed at the visible
//     region only ever *darkens* pixels (never lights a wrong one), only
//     near an access, and a mid-frame write lands on screen in the same
//     frame — with the streak frame dumped as a picture,
//   - 32-character mode: C1 pinned low, only even addresses displayed.
//
// Writes build/frame_streaks.pgm; `make frames` turns it into a PNG.

`timescale 1ns / 1ps

module tb_m1_vram;

    logic clk;
    logic rst_n;
    logic modesel;

    logic       latch_n, dot_en, hdrv, vdrv;
    logic [6:0] col;
    logic [3:0] line;
    logic [4:0] row;
    logic [5:0] vd;
    logic       vd7;
    logic       pixel;

    // CPU-side bus
    logic       vid_n, rd_n, wr_n;
    logic [9:0] cpu_a;
    // cpu_d[6] is deliberately unconsumed: the write path has no bit-6 RAM
    // pin — exactly the quirk under test
    /* verilator lint_off UNUSEDSIGNAL */
    logic [7:0] cpu_d;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [7:0] dout;
    logic       dout_en;

    m1_video_timing u_vt (
        .clk(clk), .rst_n(rst_n), .modesel(modesel),
        /* verilator lint_off PINCONNECTEMPTY */
        .latch_n(latch_n), .dot_en(dot_en), .chain_en(),
        /* verilator lint_on PINCONNECTEMPTY */
        .col(col), .line(line), .row(row), .hdrv(hdrv), .vdrv(vdrv)
    );

    m1_vram u_vr (
        .clk(clk),
        .col(col[5:0]), .row(row[3:0]),
        .vid_n(vid_n), .rd_n(rd_n), .wr_n(wr_n),
        .a(cpu_a), .din(cpu_d[5:0]), .din7(cpu_d[7]),
        .dout(dout), .dout_en(dout_en),
        .vd(vd), .vd7(vd7),
        // debug read port: unused in this bench
        .a2(10'd0),
        /* verilator lint_off PINCONNECTEMPTY */
        .dout2()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    m1_video_gen u_vg (
        .clk(clk), .rst_n(rst_n),
        .latch_n(latch_n), .dot_en(dot_en), .line(line),
        .hdrv(hdrv), .vdrv(vdrv),
        .vd(vd), .vd7(vd7), .vid_n(vid_n), .pixel(pixel)
    );

    initial begin
        clk = 0; rst_n = 0; modesel = 1;
        vid_n = 1; rd_n = 1; wr_n = 1; cpu_a = '0; cpu_d = '0;
    end
    always #46.97 clk = ~clk;

    int errors = 0;

    // ------------------------------------------------------------------
    // Shadow RAM and the test pattern (same picture as chapter 2:
    // rows 0..11 text, rows 12..15 all 64 graphics patterns).
    // ------------------------------------------------------------------
    logic [6:0] shadow [0:1023];   // {graphic flag, code[5:0]}

    function automatic [6:0] pattern(input [4:0] r, input [6:0] c);
        if (r < 12) pattern = {1'b0, 6'((int'(c) + int'(r)) % 64)};
        else        pattern = {1'b1, 6'((int'(c) + int'(r) * 4) % 64)};
    endfunction

    // the byte a CPU would write / expect to read back for a shadow cell
    function automatic [7:0] wr_byte(input [6:0] s);
        wr_byte = {s[6], 1'b0, s[5:0]};
    endfunction
    function automatic [7:0] rd_byte(input [6:0] s);
        rd_byte = {s[6], ~(s[5] | s[6]), s[5:0]};   // Z30 on the read path
    endfunction

    // ------------------------------------------------------------------
    // Z80-shaped bus model. One memory cycle = 3 T-states = 18 dots of
    // ~VID low; the strobe sits inside. Blocking assigns — one caller at
    // a time (main thread or the traffic driver, never both).
    // ------------------------------------------------------------------
    task automatic cpu_write(input [9:0] addr, input [7:0] data);
        @(negedge clk);
        cpu_a = addr; cpu_d = data; vid_n = 0;
        repeat (5) @(negedge clk);
        wr_n = 0;
        repeat (10) @(negedge clk);
        wr_n = 1;
        repeat (2) @(negedge clk);
        vid_n = 1;
        shadow[addr] = {data[7], data[5:0]};
    endtask

    task automatic cpu_read(input [9:0] addr, output [7:0] data);
        @(negedge clk);
        cpu_a = addr; vid_n = 0;
        repeat (5) @(negedge clk);
        rd_n = 0;
        repeat (5) @(negedge clk);
        if (dout_en !== 1'b1) begin
            $display("FAIL  dout_en not asserted during CPU read");
            errors++;
        end
        data = dout;
        repeat (5) @(negedge clk);
        rd_n = 1;
        repeat (2) @(negedge clk);
        vid_n = 1;
    endtask

    task automatic check_read(input [9:0] addr);
        logic [7:0] got;
        cpu_read(addr, got);
        if (got !== rd_byte(shadow[addr])) begin
            if (errors < 10)
                $display("FAIL  readback addr %0h: got %02h, want %02h",
                         addr, got, rd_byte(shadow[addr]));
            errors++;
        end
    endtask

    // ------------------------------------------------------------------
    // Independent per-dot expectation (chapter 2's model, fed from the
    // shadow RAM instead of a fixed pattern function).
    // ------------------------------------------------------------------
    logic [4:0] font [0:1023];
    initial $readmemh("../rtl/mcm6670_cg1.hex", font);

    function automatic bit expected(input [6:0] c_col, input int d,
                                    input [3:0] l, input [4:0] r);
        int          addr;
        int          pd;
        logic [6:0]  b;
        addr = int'(c_col) - (modesel ? 2 : 4);
        pd   = modesel ? d : d >> 1;
        if (addr < 0 || addr > (modesel ? 63 : 62) || r > 15)
            return 1'b0;
        b = shadow[int'(r) * 64 + addr];
        if (b[6]) begin
            case ({l[3], l[2]})
                2'b00:   return (pd < 3) ? b[0] : b[1];
                2'b01:   return (pd < 3) ? b[2] : b[3];
                default: return (pd < 3) ? b[4] : b[5];
            endcase
        end else begin
            if (l[3] || pd == 0) return 1'b0;
            return font[{~(b[5] | b[6]), b[5:0], l[2:0]}][pd-1];
        end
    endfunction

    // ------------------------------------------------------------------
    // Beam bookkeeping (as in chapter 2's bench).
    // ------------------------------------------------------------------
    int         dot_in_cell;
    logic [6:0] prev_col;
    initial begin dot_in_cell = 0; prev_col = '1; end

    task automatic step;
        @(negedge clk);
        if (col != prev_col) begin
            dot_in_cell = 0;
            prev_col    = col;
        end else begin
            dot_in_cell++;
        end
    endtask

    task automatic sync_to_frame_start;
        do step(); while (!(col == 0 && line == 0 && row == 0
                            && dot_in_cell == 0));
    endtask

    // ------------------------------------------------------------------
    // Streak locality: a dark-where-lit-expected pixel is legal only if
    // ~VID was low within the last 48 dots (assert + clear + refill,
    // generously bounded). Separate process, nonblocking — one dot of
    // staleness is far inside the margin.
    // ------------------------------------------------------------------
    int steal_timer;
    initial steal_timer = 0;
    always @(negedge clk) begin
        if (!vid_n)               steal_timer <= 48;
        else if (steal_timer > 0) steal_timer <= steal_timer - 1;
    end

    // ------------------------------------------------------------------
    // Frame checkers. Exact: every dot must match. Streaks: pixels may
    // only be darkened, only near an access, and some must actually be.
    // ------------------------------------------------------------------
    task automatic check_frame_exact(input string what);
        int checked;
        bit exp;
        checked = 0;
        sync_to_frame_start();
        repeat (672 * 264) begin
            exp = expected(col, dot_in_cell, line, row);
            if (pixel !== exp) begin
                if (errors < 10)
                    $display("FAIL  %s: pixel at col=%0d dot=%0d line=%0d row=%0d: got %b, want %b",
                             what, col, dot_in_cell, line, row, pixel, exp);
                errors++;
            end
            checked++;
            step();
        end
        $display("  ok  %s: frame exact (%0d dots)", what, checked);
    endtask

    task automatic check_frame_streaks(input string pgm_path);
        int fd, x, y, addr, darkened;
        bit exp;
        byte fb [0:191][0:383];
        darkened = 0;
        for (y = 0; y < 192; y++)
            for (x = 0; x < 384; x++) fb[y][x] = 8'h00;
        sync_to_frame_start();
        repeat (672 * 264) begin
            exp = expected(col, dot_in_cell, line, row);
            if (pixel !== exp) begin
                if (pixel === 1'b1) begin
                    // a streak may never LIGHT a pixel
                    if (errors < 10)
                        $display("FAIL  streak frame lit a wrong pixel at col=%0d line=%0d row=%0d",
                                 col, line, row);
                    errors++;
                end else if (steal_timer == 0) begin
                    // ... and may only darken near a CPU access
                    if (errors < 10)
                        $display("FAIL  darkened pixel far from any access at col=%0d line=%0d row=%0d",
                                 col, line, row);
                    errors++;
                end else begin
                    darkened++;
                end
            end
            addr = int'(col) - 2;
            if (addr >= 0 && addr <= 63 && row < 16)
                fb[row*12 + line][addr*6 + dot_in_cell] = pixel ? 8'hff : 8'h00;
            step();
        end
        if (darkened == 0) begin
            $display("FAIL  streak frame shows no streaks at all");
            errors++;
        end
        fd = $fopen(pgm_path, "wb");
        $fwrite(fd, "P5\n384 192\n255\n");
        for (y = 0; y < 192; y++)
            for (x = 0; x < 384; x++) $fwrite(fd, "%c", fb[y][x]);
        $fclose(fd);
        $display("  ok  streak frame: %0d dots darkened, none lit, all local, dump: %s",
                 darkened, pgm_path);
    endtask

    // ------------------------------------------------------------------
    // Background CPU traffic. Mode 1: accesses only deep inside blanking
    // (ending >= 2 cells before the visible region — the pipeline needs
    // one latch to clear VCLR*). Mode 2: accesses anywhere, rewriting
    // cells with their own values (so streaks stay provably subtractive),
    // plus one real write to row 15 early in the frame (it lands before
    // the beam gets there — same-frame update, checked by the frame
    // comparison against the updated shadow).
    // ------------------------------------------------------------------
    int          drv_mode = 0;    // 0 idle, 1 blanking only, 2 anywhere
    int          drv_count;
    logic [15:0] lfsr = 16'hACE1;

    function automatic [15:0] lfsr_next(input [15:0] s);
        lfsr_next = {s[14:0], s[15] ^ s[13] ^ s[12] ^ s[10]};
    endfunction

    localparam [9:0]  LANDS_ADDR = 10'(15 * 64 + 21);
    localparam [7:0]  LANDS_DATA = 8'hAA;   // graphics: checkerboard bands

    task automatic one_access;
        logic [9:0] addr;
        lfsr = lfsr_next(lfsr);
        addr = lfsr[9:0];
        if (drv_mode == 2 && drv_count == 50)
            cpu_write(LANDS_ADDR, LANDS_DATA);
        else if (lfsr[15])
            check_read(addr);
        else
            cpu_write(addr, wr_byte(shadow[addr]));
        drv_count++;
    endtask

    // Safe launch window. Note the asymmetry, found the hard way: the
    // shifter load for the LAST visible column happens at the latch edge
    // one cell INTO the horizontal blank (end of cell 64), so the window
    // opens only at cell 65 — an access at hblank start still streaks
    // column 63. It closes early enough that the access (~20 dots) ends
    // before the latch edge at the end of cell 111 releases VCLR* for
    // the first visible capture.
    wire blank_safe = (hdrv && col >= 65 && col <= 104)
                   || (vdrv && row <= 20);

    bit drv_busy;   // the bus tasks have a single caller at any time: the
                    // main thread hands the bus over via drv_mode and takes
                    // it back only after drv_busy has fallen

    initial begin
        drv_count = 0;
        drv_busy  = 0;
        forever begin
            @(negedge clk);
            if (drv_mode == 1) begin
                if (blank_safe) begin
                    drv_busy = 1;
                    one_access();
                    drv_busy = 0;
                end
            end else if (drv_mode == 2) begin
                repeat (20 + int'(lfsr[6:0])) @(negedge clk);
                if (drv_mode == 2) begin
                    drv_busy = 1;
                    one_access();
                    drv_busy = 0;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    initial begin
        int i;

        $dumpfile("build/tb_m1_vram.vcd");
        $dumpvars(0, tb_m1_vram);

        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (24) @(negedge clk);

        // --- fill all 1024 cells through the CPU port, then read back ---
        for (i = 0; i < 1024; i++)
            cpu_write(10'(i), wr_byte(pattern(5'(i / 64), 7'(i % 64))));
        for (i = 0; i < 1024; i++)
            check_read(10'(i));
        $display("  ok  1024 cells written and read back through the muxes");

        // --- the bit-6 quirks, straight from the structure ---
        cpu_write(10'd0, 8'h40);  check_read(10'd0);   // '@' survives via NOR
        if (rd_byte(shadow[0]) !== 8'h40) begin
            $display("FAIL  0x40 did not read back as 0x40"); errors++; end
        cpu_write(10'd0, 8'h7F);  check_read(10'd0);   // bit 6 dropped -> 0x3F
        if (rd_byte(shadow[0]) !== 8'h3F) begin
            $display("FAIL  0x7F did not read back as 0x3F"); errors++; end
        cpu_write(10'd0, 8'h1F);  check_read(10'd0);   // control -> letter
        if (rd_byte(shadow[0]) !== 8'h5F) begin
            $display("FAIL  0x1F did not read back as 0x5F"); errors++; end
        cpu_write(10'd0, 8'hFF);  check_read(10'd0);   // graphics keep bit 7
        if (rd_byte(shadow[0]) !== 8'hBF) begin
            $display("FAIL  0xFF did not read back as 0xBF"); errors++; end
        $display("  ok  bit-6 quirks: 40->40, 7F->3F, 1F->5F, FF->BF");
        cpu_write(10'd0, wr_byte(pattern(5'd0, 7'd0)));   // restore

        // --- R49 isolation: strobes without ~VID do nothing ---
        @(negedge clk);
        cpu_a = 10'd1; cpu_d = 8'h2A; wr_n = 0;
        repeat (12) @(negedge clk);
        wr_n = 1; rd_n = 0;
        repeat (6) @(negedge clk);
        if (dout_en !== 1'b0) begin
            $display("FAIL  dout_en asserted without ~VID"); errors++; end
        rd_n = 1;
        repeat (2) @(negedge clk);
        check_read(10'd1);                 // still the pattern value
        $display("  ok  R49: ~RD/~WR without ~VID neither read nor write");

        // --- a full frame from the real RAM, no CPU traffic ---
        check_frame_exact("undisturbed frame");

        // --- the beam-hack property: blanking-only traffic, zero trace ---
        drv_mode = 1;
        check_frame_exact("frame with blanking-only CPU traffic");
        drv_mode = 0;
        wait (!drv_busy);

        // --- streaks: traffic into the visible region ---
        drv_count = 0;               // access #50 is the write that lands
        drv_mode = 2;
        check_frame_streaks("build/frame_streaks.pgm");
        drv_mode = 0;
        wait (!drv_busy);
        repeat (4) @(negedge clk);
        if (drv_count < 100) begin
            $display("FAIL  traffic driver ran only %0d accesses", drv_count);
            errors++;
        end
        // the one real write actually happened, and it persisted: the
        // frame above was already checked against the updated shadow
        if (shadow[LANDS_ADDR] !== {LANDS_DATA[7], LANDS_DATA[5:0]}) begin
            $display("FAIL  the mid-frame write never happened");
            errors++;
        end
        check_read(LANDS_ADDR);

        // --- 32-character mode: C1 low, even addresses only ---
        modesel = 0;
        sync_to_frame_start();
        check_frame_exact("32-char frame");

        if (errors == 0) $display("\nALL CHECKS PASSED");
        else             $display("\n%0d CHECKS FAILED", errors);
        if (errors != 0) $fatal(1);
        $finish;
    end

    // watchdog: fill + readback + five frames, generously
    initial begin
        #300_000_000;
        $display("FAIL  watchdog timeout");
        $fatal(1);
    end

endmodule
