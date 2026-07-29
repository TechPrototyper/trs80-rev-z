// Testbench: m1_cpu — the CPU sheet joins the verified chain.
//
// First full-system bench: m1_cpu_clock + m1_cpu (tv80 inside, ADR-0003)
// + m1_addr_decode + m1_rom + m1_ram + m1_vram + m1_io + m1_video_timing +
// m1_video_gen, glued by the shared data bus (value+enable idiom).
// Since chapter 6, m1_io drives MODESEL and the program exercises port 0xFF
// (mode switch + IN read-back). Since chapter 7, m1_keyboard is on the bus and
// the program reads the injected SPACE/'A' keys. All still byte-exact vs trs80gp.
//
// The CPU executes this repository's own hand-assembled test image
// (sim/tools/build_test_image.py — no Tandy code): clear screen via LDIR
// through VRAM, banner copy, checksum loop with CALL/RET + PUSH/POP,
// 16-bit arithmetic into RAM, an OUT to the cassette latch port, then
// HALT — which on a Model 1 asserts NMI* (Z53a/Z37d), so the CPU wakes
// at 0x0066 and writes a marker into the last VRAM cell. Proves:
//   - opcode fetch/read/write/I-O strobes fire with the documented shapes
//     (mutual exclusion, DBIN*/DBOUT* complementary, CPU never drives the
//     bus during its own reads, exactly one bus driver at any time),
//   - the decoder+ROM+RAM+VRAM chain returns/absorbs CPU data correctly
//     (banner, checksum, 16-bit results, marker — all land where the
//     program put them),
//   - refresh M1 cycles assert RAS* without data strobes (RAS-only
//     refresh, Manual p. 295),
//   - HALT really does warm-start through the NMI vector,
//   - the whole thing renders: the final screen is dumped as a picture
//     (build/frame_cpu.pgm -> `make frames` -> frame_cpu.png).
//
// The ROM is loaded at runtime through m1_rom's loader port from
// build/testimg.hex — the array powers up blank, per roms/README.md.

`timescale 1ns / 1ps

module tb_m1_cpu;

    logic clk;
    logic rst_n;

    initial begin clk = 0; rst_n = 0; end
    always #46.97 clk = ~clk;

    int errors;
    initial errors = 0;

    // ------------------------------------------------------------------
    // The whole machine, as one synthesizable module (chapter 8, m1_core).
    // The interconnect that used to live here is now RTL; this bench drives
    // the core's external surface and observes its internals hierarchically.
    // ------------------------------------------------------------------
    logic        m1_n, halt_n, modesel, cass_motor;
    logic [15:0] addr;
    logic [6:0]  col;
    logic [3:0]  line;
    logic [4:0]  row;
    logic        pixel;

    // ROM loader and keyboard: the core inputs this bench drives.
    logic        ld_en;
    logic [13:0] ld_addr;
    logic [7:0]  ld_data;
    // Inject SPACE (row 6, col 7) and 'A' (row 0, col 1) — the same keys the
    // golden run presses with trs80gp's -ik 6 80 / -ik 0 02.
    logic [63:0] kb_keys;
    initial begin
        kb_keys = '0;
        kb_keys[8*6 + 7] = 1'b1;   // SPACE
        kb_keys[8*0 + 1] = 1'b1;   // 'A'
    end

    m1_core u_core (
        .clk(clk), .por_rst_n(rst_n), .dbg_rst_n(rst_n), .reset_btn_n(1'b1),
        .test_n(1'b1), .int_n(1'b1), .wait_n(1'b1),
        .ld_en(ld_en), .ld_addr(ld_addr), .ld_data(ld_data),
        .ei_ram_cfg(2'b00),   // no EI RAM: 16K system, goldens unchanged
        .fdc_disk(4'b0000),
        /* verilator lint_off PINCONNECTEMPTY */
        .trk_req(), .trk_drv(), .trk_track(),
        /* verilator lint_on PINCONNECTEMPTY */
        .trk_vld(1'b0), .trk_data(8'd0), .trk_idx(13'd0),
        .trk_done(1'b0), .trk_err(1'b1), .trk_len(13'd0), .trk_dbl(1'b0),
        .fdc_wp(4'b0000),
        .percom_en(1'b1),
        /* verilator lint_off PINCONNECTEMPTY */
        .trk_wb_req(), .trk_wb_data(),
        /* verilator lint_on PINCONNECTEMPTY */
        .trk_wb_fetch(1'b0), .trk_wb_idx(13'd0),
        .trk_wb_done(1'b0), .trk_wb_err(1'b1),
        .dbg_in_valid(1'b0), .dbg_in_data(8'h00), .dbg_out_ready(1'b1),
        /* verilator lint_off PINCONNECTEMPTY */
        .dbg_in_ready(), .dbg_out_valid(), .dbg_out_data(),
        /* verilator lint_on PINCONNECTEMPTY */
        .keys(kb_keys),
        .cass_in(1'b0),
        /* verilator lint_off PINCONNECTEMPTY */
        .cass_out(), .cass_motor(cass_motor),
        .hdrv(), .vdrv(), .dot_en(), .cpu_cen(),
        /* verilator lint_on PINCONNECTEMPTY */
        .pixel(pixel),
        .modesel(modesel), .col(col), .line(line), .row(row),
        .addr(addr), .m1_n(m1_n), .halt_n(halt_n)
    );

    // Internal signals the continuous checks watch, pulled up by name.
    wire [7:0] bus     = u_core.bus;
    wire       rd_n    = u_core.rd_n;
    wire       wr_n    = u_core.wr_n;
    wire       in_n    = u_core.in_n;
    wire       out_n   = u_core.out_n;
    wire       dbin_n  = u_core.dbin_n;
    wire       dbout_n = u_core.dbout_n;
    wire       ras_n   = u_core.ras_n;
    wire       cas_n   = u_core.cas_n;
    wire       mux     = u_core.mux;
    wire       intak_n = u_core.intak_n;
    wire       sysres_n= u_core.sysres_n;
    wire       busak_n = u_core.busak_n;
    wire       addr_en = u_core.addr_en;
    wire       vid_n   = u_core.vid_n;
    wire       rom_en  = u_core.rom_en;
    wire       ram_en  = u_core.ram_en;
    wire       vram_en = u_core.vram_en;
    wire       kb_en   = u_core.kb_en;
    wire       io_en   = u_core.io_en;
    wire       outsig_n= u_core.outsig_n;

    // ------------------------------------------------------------------
    // Continuous invariants (checked every dot clock once execution runs;
    // checks_on decouples the checkers from the async rst_n net).
    // Blocking bookkeeping on purpose: single checker process, counters
    // read only after the run — justified TB waiver, as in chapter 3.
    // ------------------------------------------------------------------
    bit checks_on;
    int refresh_ras;       // RAS* pulses with no data strobe = refresh
    initial begin checks_on = 0; refresh_ras = 0; end

    /* verilator lint_off BLKSEQ */
    always @(negedge clk) if (checks_on) begin
        if (!$onehot0(~{rd_n, wr_n, in_n, out_n})) begin
            $display("FAIL  two strobes active at once"); errors++;
        end
        if (dbin_n !== ~dbout_n) begin
            $display("FAIL  DBIN* not the complement of DBOUT*"); errors++;
        end
        if ((!rd_n || !in_n) && !dbout_n) begin
            $display("FAIL  CPU drives the bus during its own read"); errors++;
        end
        if (!$onehot0({~dbout_n, rom_en, ram_en, vram_en, kb_en, io_en})) begin
            $display("FAIL  bus driver conflict"); errors++;
        end
        if (!rd_n && !(rom_en || ram_en || vram_en || kb_en)) begin
            $display("FAIL  read strobe on unmapped space (addr=%04h)", addr);
            errors++;
        end
        // IN 0xFF must drive the port; io_en only ever on for port 0xFF reads
        if (io_en && (in_n || addr[7:0] !== 8'hFF)) begin
            $display("FAIL  io_en asserted off an IN 0xFF (in_n=%b a=%02h)",
                     in_n, addr[7:0]); errors++;
        end
        if (intak_n !== 1'b1) begin
            $display("FAIL  INTAK* fired with interrupts disabled"); errors++;
        end
        // CAS* stays inside RAS* on memory cycles; on I/O cycles the chain
        // fires with RAS* high by construction (Z74a watches the raw pins).
        if (!cas_n && ras_n && in_n && out_n) begin
            $display("FAIL  CAS* active outside RAS* on a memory cycle");
            errors++;
        end
        // With the button up and TEST* high: SYSRES* mirrors ~HALT
        // (Z53a/Z37a — a halted CPU asserts system reset), the address
        // buffers stay on, and nobody acknowledges a bus grant. (KYBD* now
        // does pulse low — the program reads the keyboard, chapter 7.)
        if (addr_en !== 1'b1 || sysres_n !== halt_n || busak_n !== 1'b1) begin
            $display("FAIL  addr_en=%b sysres_n=%b busak_n=%b halt_n=%b",
                     addr_en, sysres_n, busak_n, halt_n);
            errors++;
        end
        if (!ras_n && rd_n && wr_n)
            refresh_ras++;
    end
    /* verilator lint_on BLKSEQ */

    // ------------------------------------------------------------------
    // Event bookkeeping: HALT -> NMI -> fetch at 0x0066, OUT (FF)h,
    // marker write to 0x3FFF.
    // ------------------------------------------------------------------
    bit saw_halt, saw_fetch_66, saw_out_ff, done;
    initial begin saw_halt = 0; saw_fetch_66 = 0; saw_out_ff = 0; done = 0; end

    /* verilator lint_off BLKSEQ */
    always @(negedge clk) if (checks_on) begin
        if (!halt_n) saw_halt <= 1;
        if (!rd_n && !m1_n && addr == 16'h0066) begin
            if (!saw_halt) begin
                $display("FAIL  NMI vector fetched before any HALT"); errors++;
            end
            saw_fetch_66 <= 1;
        end
        // the program writes 0x08 (-> 32-char) then 0x06 (-> 64-char) to 0xFF
        if (!out_n && addr[7:0] == 8'hFF) begin
            saw_out_ff <= 1;
            if (outsig_n !== 1'b0) begin
                $display("FAIL  OUT 0xFF did not assert OUTSIG*"); errors++;
            end
            if (bus !== 8'h08 && bus !== 8'h06) begin
                $display("FAIL  OUT 0xFF carried %02h, want 08 or 06", bus);
                errors++;
            end
        end
        if (!wr_n && !vid_n && addr[9:0] == 10'h3FF && bus == 8'hBF)
            done <= 1;
        if (!cas_n && !mux) begin
            $display("FAIL  CAS* active before MUX switched to columns");
            errors++;
        end
    end
    /* verilator lint_on BLKSEQ */

    // ------------------------------------------------------------------
    // ROM image: read the hex, replay it through the loader port.
    // ------------------------------------------------------------------
    logic [7:0] image [0:4095];

    task automatic load_rom;
        int i;
        $readmemh("build/testimg.hex", image);
        @(negedge clk);
        for (i = 0; i < 4096; i++) begin
            ld_en = 1; ld_addr = 14'(i); ld_data = image[i];
            @(negedge clk);
        end
        ld_en = 0;
        @(negedge clk);
    endtask

    // Expected VRAM cell (7-bit, as stored): {D7, D5:0}. Bit 6 of the
    // argument is deliberately discarded — the write path has no bit-6
    // RAM pin, exactly the chapter-3 quirk.
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic [6:0] vcell(input [7:0] b);
        vcell = {b[7], b[5:0]};
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // ------------------------------------------------------------------
    // Frame dump (screen only, as in chapter 3's bench)
    // ------------------------------------------------------------------
    int dot_in_cell;
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

    task automatic dump_frame(input string pgm_path);
        int fd, x, y, a2;
        byte fb [0:191][0:383];
        for (y = 0; y < 192; y++)
            for (x = 0; x < 384; x++) fb[y][x] = 8'h00;
        do step(); while (!(col == 0 && line == 0 && row == 0
                            && dot_in_cell == 0));
        repeat (672 * 264) begin
            a2 = int'(col) - 2;
            if (a2 >= 0 && a2 <= 63 && row < 16)
                fb[row*12 + line][a2*6 + dot_in_cell] = pixel ? 8'hff : 8'h00;
            step();
        end
        fd = $fopen(pgm_path, "wb");
        $fwrite(fd, "P5\n384 192\n255\n");
        for (y = 0; y < 192; y++)
            for (x = 0; x < 384; x++) $fwrite(fd, "%c", fb[y][x]);
        $fclose(fd);
        $display("  ok  screen dumped: %s", pgm_path);
    endtask

    // ------------------------------------------------------------------
    initial begin
        int i;
        logic [7:0] csum;

        $dumpfile("build/tb_m1_cpu.vcd");
        $dumpvars(0, tb_m1_cpu);

        ld_en = 0; ld_addr = '0; ld_data = '0;

        repeat (4) @(negedge clk);
        rst_n = 1;
        load_rom();
        $display("  ok  ROM image loaded at runtime (4096 bytes)");

        // pulse the power-on reset AFTER loading so execution starts clean
        rst_n = 0;
        repeat (8) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);
        checks_on = 1;

        // --- run to completion: the NMI handler's marker write ---
        wait (done);
        repeat (64) @(negedge clk);

        if (!saw_halt) begin
            $display("FAIL  CPU never halted"); errors++; end
        if (!saw_fetch_66) begin
            $display("FAIL  no opcode fetch at 0x0066 after HALT"); errors++; end
        if (!saw_out_ff) begin
            $display("FAIL  OUT (FF)h never seen"); errors++; end
        if (refresh_ras == 0) begin
            $display("FAIL  no RAS-only refresh cycles observed"); errors++; end
        $display("  ok  HALT -> NMI -> 0x0066 (refresh RAS* pulses: %0d)",
                 refresh_ras);

        // --- RAM: checksum and 16-bit results, straight from the array ---
        csum = 8'h00;
        for (i = 0; i < 16; i++)
            csum += image[32'h0140 + i];
        if (u_core.u_ram.mem[0] !== csum) begin
            $display("FAIL  checksum at 0x4000: got %02h, want %02h",
                     u_core.u_ram.mem[0], csum); errors++;
        end
        if (u_core.u_ram.mem[1] !== 8'h48 || u_core.u_ram.mem[2] !== 8'hD0) begin
            $display("FAIL  16-bit result at 0x4001/2: got %02h %02h, want 48 D0",
                     u_core.u_ram.mem[1], u_core.u_ram.mem[2]); errors++;
        end
        $display("  ok  RAM: checksum %02h and 48D0h landed", csum);

        // --- VRAM: banner, blanks, pseudo-hex digits, marker ---
        for (i = 0; i < 16; i++)
            if (u_core.u_vr.ram[i] !== vcell(image[32'h0140 + i])) begin
                if (errors < 10)
                    $display("FAIL  banner cell %0d: got %02h, want %02h",
                             i, u_core.u_vr.ram[i], vcell(image[32'h0140 + i]));
                errors++;
            end
        for (i = 16; i < 64; i++)
            if (u_core.u_vr.ram[i] !== vcell(8'h20)) begin
                if (errors < 10)
                    $display("FAIL  cell %0d not blank", i);
                errors++;
            end
        if (u_core.u_vr.ram[64] !== vcell(8'h30 + {4'b0, csum[7:4]}) ||
            u_core.u_vr.ram[65] !== vcell(8'h30 + {4'b0, csum[3:0]})) begin
            $display("FAIL  pseudo-hex digits at 0x3C40/41 wrong"); errors++;
        end
        if (u_core.u_vr.ram[1023] !== vcell(8'hBF)) begin
            $display("FAIL  done marker missing from last cell"); errors++;
        end
        $display("  ok  VRAM: banner, blanks, digits, marker all in place");

        // --- port 0xFF read-back tags (cells 66/67/68): the program branched
        //     on IN 0xFF, so these prove the port read path end to end ---
        if (u_core.u_vr.ram[66] !== vcell(8'h36)) begin
            $display("FAIL  cell 66: MODESEL read as 32-char before switch (got %02h)",
                     u_core.u_vr.ram[66]); errors++; end
        if (u_core.u_vr.ram[67] !== vcell(8'h33)) begin
            $display("FAIL  cell 67: MODESEL did not read 32-char after OUT 08h (got %02h)",
                     u_core.u_vr.ram[67]); errors++; end
        if (u_core.u_vr.ram[68] !== vcell(8'h30)) begin
            $display("FAIL  cell 68: cassette bit not 0 with no tape (got %02h)",
                     u_core.u_vr.ram[68]); errors++; end
        // and the port really drove the video timing: final OUT 06h -> 64-char
        if (modesel !== 1'b1) begin
            $display("FAIL  MODESEL not back to 64-char after final OUT 06h"); errors++; end
        if (cass_motor !== 1'b1) begin
            $display("FAIL  cassette motor not on after OUT 06h (D2=1)"); errors++; end
        $display("  ok  port 0xFF: MODESEL read-back 64->32, cassette=0, motor on, mode drives video");

        // --- keyboard read-back tags (cells 69/70): the program read the
        //     matrix and tagged the injected SPACE (row 6 D7) and 'A' (row 0 D1) ---
        if (u_core.u_vr.ram[69] !== vcell(8'h53)) begin
            $display("FAIL  cell 69: SPACE not sensed on row 6 (got %02h, want 'S')",
                     u_core.u_vr.ram[69]); errors++; end
        if (u_core.u_vr.ram[70] !== vcell(8'h41)) begin
            $display("FAIL  cell 70: 'A' not sensed on row 0 (got %02h, want 'A')",
                     u_core.u_vr.ram[70]); errors++; end
        $display("  ok  keyboard: SPACE (row6/D7) and 'A' (row0/D1) read through the matrix");

        // --- VRAM as the CPU would read it (chapter 3's Z30 transform),
        //     for the byte-exact golden-model comparison (SPEC §6) ---
        begin
            int fd;
            fd = $fopen("build/vram_cpu.bin", "wb");
            for (i = 0; i < 1024; i++)
                $fwrite(fd, "%c", {u_core.u_vr.ram[i][6],
                                   ~(u_core.u_vr.ram[i][5] | u_core.u_vr.ram[i][6]),
                                   u_core.u_vr.ram[i][5:0]});
            $fclose(fd);
            $display("  ok  VRAM dumped for golden compare: build/vram_cpu.bin");
        end

        // --- and the picture the machine now shows ---
        dump_frame("build/frame_cpu.pgm");

        if (errors == 0) $display("\nALL CHECKS PASSED");
        else             $display("\n%0d CHECKS FAILED", errors);
        if (errors != 0) $fatal(1);
        $finish;
    end

    // watchdog: program (~23k T-states) + a frame, generously
    initial begin
        #100_000_000;
        $display("FAIL  watchdog timeout");
        $fatal(1);
    end

endmodule
