// Testbench: m1_video_gen — character/graphics generation and shift path.
//
// Proves, against an independently computed expectation for every visible dot:
//   - the two-character pipeline (RAM -> Z28/Z27 -> shift registers): pixels of
//     character N appear while the column counter shows cell N+2,
//   - text cells: blank column first, then font bits left to right, glyph on
//     scan lines 1..7, lines 0 and 8..11 dark (chip row 0 / CHARGAP),
//   - graphics cells: 2x3 blocks, 3 dots x 4 lines, all 12 lines lit-capable,
//   - the sneaky bit: VRAM 0x00..0x3F renders as ASCII 0x40..0x5F,
//   - blanking: everything outside columns 0..63 / rows 0..15 is dark,
//   - 32-char mode: every dot doubled, characters from even addresses only,
//   - VCLR*: pixels go dark while ~VID is low; the pipeline refills cleanly.
//
// Writes build/frame64.pgm and build/frame32.pgm (one visible frame each,
// 384x192) — `make frames` turns them into PNGs.

`timescale 1ns / 1ps

module tb_m1_video_gen;

    logic clk;
    logic rst_n;
    logic modesel;
    logic vid_n;

    logic       latch_n, dot_en, hdrv, vdrv;
    logic [6:0] col;
    logic [3:0] line;
    logic [4:0] row;
    logic [5:0] vd;
    logic       vd7;
    logic       pixel;

    m1_video_timing u_vt (
        .clk(clk), .rst_n(rst_n), .modesel(modesel),
        // chain_en is covered by tb_m1_timing
        /* verilator lint_off PINCONNECTEMPTY */
        .latch_n(latch_n), .dot_en(dot_en), .chain_en(),
        /* verilator lint_on PINCONNECTEMPTY */
        .col(col), .line(line), .row(row), .hdrv(hdrv), .vdrv(vdrv)
    );

    m1_video_gen u_vg (
        .clk(clk), .rst_n(rst_n),
        .latch_n(latch_n), .dot_en(dot_en), .line(line),
        .hdrv(hdrv), .vdrv(vdrv),
        .vd(vd), .vd7(vd7), .vid_n(vid_n), .pixel(pixel)
    );

    initial begin
        clk = 0; rst_n = 0; modesel = 1; vid_n = 1;
    end
    always #46.97 clk = ~clk;

    // ------------------------------------------------------------------
    // Fake video RAM (the real thing arrives with chapter 3).
    // Rows 0..11: text, all 64 codes per row, shifted by one per row
    //             (exercises code and row addressing independently).
    // Rows 12..15: graphics, all 64 cell patterns.
    // ------------------------------------------------------------------
    // returns {graphic bit, code[5:0]} — bit 6 has no RAM behind it
    function automatic [6:0] vram(input [4:0] r, input [6:0] c);
        if (r < 12) vram = {1'b0, 6'((int'(c) + int'(r)) % 64)};
        else        vram = {1'b1, 6'((int'(c) + int'(r) * 4) % 64)};
    endfunction

    assign {vd7, vd} = vram(row, col);

    // ------------------------------------------------------------------
    // Independent expectation. Same font data, independent addressing
    // and pipeline arithmetic.
    // ------------------------------------------------------------------
    logic [4:0] font [0:1023];
    initial $readmemh("../rtl/mcm6670_cg1.hex", font);

    // Pixel under the beam at (counter cell col=c_col, master dot d within
    // the cell, scan line l, row r). Pipeline: two cells of latency; a cell
    // is 6 master dots (64-char) or 12 (32-char, dots doubled).
    function automatic bit expected(input [6:0] c_col, input int d,
                                    input [3:0] l, input [4:0] r);
        int          addr;    // VRAM address of the character shown here
        int          pd;      // dot within the 6-dot pixel cell
        logic [6:0]  b;       // {graphic bit, code[5:0]}
        addr = int'(c_col) - (modesel ? 2 : 4);
        pd   = modesel ? d : d >> 1;
        if (addr < 0 || addr > (modesel ? 63 : 62) || r > 15)
            return 1'b0;
        b = vram(r, 7'(addr));
        if (b[6]) begin
            // graphics: {L8,L4} selects the cell pair, left 3 dots then right
            case ({l[3], l[2]})
                2'b00:   return (pd < 3) ? b[0] : b[1];
                2'b01:   return (pd < 3) ? b[2] : b[3];
                default: return (pd < 3) ? b[4] : b[5];
            endcase
        end else begin
            if (l[3] || pd == 0) return 1'b0;          // CHARGAP / blank column
            // sneaky bit replicated: stored 0x00..0x3F shows as 0x40..0x5F
            return font[{~(b[5] | b[6]), b[5:0], l[2:0]}][pd-1];  // bit 0 = left
        end
    endfunction

    // ------------------------------------------------------------------
    // Beam bookkeeping: advance one master dot and track the dot index
    // within the current cell. Single caller (the stimulus process), so
    // plain blocking assignments keep this deterministic.
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

    // ------------------------------------------------------------------
    // Frame checker: compares every dot of one full frame, dumps the
    // visible 384x192 raster as PGM.
    // ------------------------------------------------------------------
    int errors = 0;

    task automatic sync_to_frame_start;
        // first dot of cell 0, line 0, row 0
        do step(); while (!(col == 0 && line == 0 && row == 0
                            && dot_in_cell == 0));
    endtask

    task automatic check_frame(input string pgm_path);
        int fd, x, y, addr, checked;
        bit exp;
        byte fb [0:191][0:383];
        checked = 0;
        for (y = 0; y < 192; y++)
            for (x = 0; x < 384; x++) fb[y][x] = 8'h00;
        sync_to_frame_start();
        repeat (672 * 264) begin
            exp = expected(col, dot_in_cell, line, row);
            if (pixel !== exp) begin
                if (errors < 10)
                    $display("FAIL  pixel at col=%0d dot=%0d line=%0d row=%0d: got %b, want %b",
                             col, dot_in_cell, line, row, pixel, exp);
                errors++;
            end
            checked++;
            // visible raster: character addresses 0..63 (0..62 even in
            // 32-char mode), rows 0..15 — 384 master dots per line
            addr = int'(col) - (modesel ? 2 : 4);
            if (addr >= 0 && addr <= (modesel ? 63 : 62) && row < 16) begin
                x = modesel ? addr * 6 + dot_in_cell
                            : (addr >> 1) * 12 + dot_in_cell;
                fb[row*12 + line][x] = pixel ? 8'hff : 8'h00;
            end
            step();
        end
        if (checked != 672 * 264) begin
            $display("FAIL  frame checker ran %0d dots, want %0d", checked, 672*264);
            errors++;
        end
        fd = $fopen(pgm_path, "wb");
        $fwrite(fd, "P5\n384 192\n255\n");
        for (y = 0; y < 192; y++)
            for (x = 0; x < 384; x++) $fwrite(fd, "%c", fb[y][x]);
        $fclose(fd);
        $display("  ok  frame checked (%0d dots), dump: %s",
                 checked, pgm_path);
    endtask

    // ------------------------------------------------------------------
    // VCLR*: CPU steals video RAM mid-frame. VCLR* clears the DATA LATCHES,
    // not the shift registers (their Clr* sits on pull-up R40) — so the cell
    // in flight plays out, up to ~7 dots of residue (the manual's "black
    // streaks"), and only then does the screen go dark. After release the
    // pipeline refills within two character times.
    // ------------------------------------------------------------------
    task automatic check_vclr;
        int i, lit;
        // park the beam at the start of a visible glyph line
        do step(); while (!(col == 10 && line == 3 && row == 2
                            && dot_in_cell == 0));
        vid_n = 0;
        repeat (8) step();                // residue: in-flight cell + sync clear
        for (i = 0; i < 30; i++) begin
            if (pixel !== 1'b0) begin
                $display("FAIL  pixel lit during ~VID low (i=%0d)", i);
                errors++;
            end
            step();
        end
        vid_n = 1;
        // refill: first capture at the next LATCH*, visible two cells later;
        // resume exact comparison from the start of the fourth cell
        repeat (4) begin
            do step(); while (dot_in_cell != 0);
        end
        lit = 0;
        while (col != 0) begin
            if (pixel !== expected(col, dot_in_cell, line, row)) begin
                $display("FAIL  post-VCLR pixel at col=%0d dot=%0d", col, dot_in_cell);
                errors++;
            end
            lit += int'(pixel);
            step();
        end
        if (lit == 0) begin
            $display("FAIL  post-VCLR line stayed dark — refill did not happen");
            errors++;
        end
        $display("  ok  VCLR*: streaks fade, dark while ~VID low, clean refill");
    endtask

    // ------------------------------------------------------------------
    initial begin
        $dumpfile("build/tb_m1_video_gen.vcd");
        $dumpvars(0, tb_m1_video_gen);

        repeat (4) @(negedge clk);
        rst_n = 1;

        // one warm-up frame, then check a full frame in 64-char mode
        sync_to_frame_start();
        check_frame("build/frame64.pgm");

        check_vclr();

        // 32-char mode: give the conditioning a frame to settle, then check
        modesel = 0;
        sync_to_frame_start();
        check_frame("build/frame32.pgm");

        if (errors == 0) $display("\nALL CHECKS PASSED");
        else             $display("\n%0d CHECKS FAILED", errors);
        if (errors != 0) $fatal(1);
        $finish;
    end

    // watchdog: the run needs about five frames' worth of simulated time
    initial begin
        #150_000_000;
        $display("FAIL  watchdog timeout");
        $fatal(1);
    end

endmodule
