// Testbench: m1_addr_decode — the address decoder.
//
// Proves, against an independently coded memory map (hex ranges straight
// from SPEC §3 / the manual, not the decoder's own equations):
//   - every select over the full 64K address space, in memory cycles and
//     non-memory cycles, with RD* both ways: ROMA*/ROMB*/RAM*/KYBD*/VID*
//     and MEM* — 256K decoder states checked exhaustively,
//   - at most one select active at a time; none at all for 0x3000-0x37FF
//     (open bus) and the entire upper 32K,
//   - partial decode: the keyboard select covers all of 0x3800-0x3BFF
//     (the matrix mirrors), RAM* covers exactly 16K,
//   - integration with chapter 3: a 16-bit CPU access through the decoder
//     reaches the video RAM if and only if the address is 0x3C00-0x3FFF.

`timescale 1ns / 1ps

module tb_m1_addr_decode;

    logic [15:0] addr;
    logic        ras_n, rd_n, wr_n;

    wire roma_n, romb_n, ram_n, kybd_n, vid_n, mem_n;

    m1_addr_decode u_ad (
        .a(addr[15:10]), .ras_n(ras_n), .rd_n(rd_n),
        .roma_n(roma_n), .romb_n(romb_n), .ram_n(ram_n),
        .kybd_n(kybd_n), .vid_n(vid_n), .mem_n(mem_n)
    );

    // chapter 3's video RAM behind the decoder, video side parked
    logic       clk;
    // cpu_d[6] is deliberately unconsumed: no bit-6 RAM pin (chapter 3)
    /* verilator lint_off UNUSEDSIGNAL */
    logic [7:0] cpu_d;
    /* verilator lint_on UNUSEDSIGNAL */
    wire  [7:0] dout;
    wire        dout_en;
    /* verilator lint_off PINCONNECTEMPTY */
    m1_vram u_vr (
        .clk(clk),
        .col(6'd0), .row(4'd0),
        .vid_n(vid_n), .rd_n(rd_n), .wr_n(wr_n),
        .a(addr[9:0]), .din(cpu_d[5:0]), .din7(cpu_d[7]),
        .dout(dout), .dout_en(dout_en), .vd(), .vd7()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    initial clk = 0;
    always #46.97 clk = ~clk;

    int errors = 0;

    // ------------------------------------------------------------------
    // The independent map: hex ranges, nothing else.
    // ------------------------------------------------------------------
    function automatic void expect_selects(
        input logic [15:0] ad, input logic rn, input logic dn,
        output logic e_roma, output logic e_romb, output logic e_ram,
        output logic e_kybd, output logic e_vid, output logic e_mem);
        logic on;
        on     = ~rn;                                   // memory cycle
        e_roma = on && (ad <= 16'h1FFF);
        e_romb = on && (ad >= 16'h2000) && (ad <= 16'h2FFF);
        e_kybd = on && (ad >= 16'h3800) && (ad <= 16'h3BFF);
        e_vid  = on && (ad >= 16'h3C00) && (ad <= 16'h3FFF);
        e_ram  = on && (ad >= 16'h4000) && (ad <= 16'h7FFF);
        e_mem  = ~dn && (e_roma || e_romb || e_ram);
    endfunction

    task automatic sweep;
        int a_i, r_i, d_i, n_active, checked;
        logic e_roma, e_romb, e_ram, e_kybd, e_vid, e_mem;
        checked = 0;
        for (a_i = 0; a_i < 65536; a_i++) begin
            for (r_i = 0; r_i < 2; r_i++) begin
                for (d_i = 0; d_i < 2; d_i++) begin
                    addr  = 16'(a_i);
                    ras_n = 1'(r_i);
                    rd_n  = 1'(d_i);
                    #1;
                    expect_selects(addr, ras_n, rd_n,
                                   e_roma, e_romb, e_ram, e_kybd, e_vid, e_mem);
                    if ({~roma_n, ~romb_n, ~ram_n, ~kybd_n, ~vid_n, ~mem_n}
                        !== {e_roma, e_romb, e_ram, e_kybd, e_vid, e_mem}) begin
                        if (errors < 10)
                            $display("FAIL  addr %04h ras_n=%b rd_n=%b: got %b%b%b%b%b%b want %b%b%b%b%b%b",
                                     addr, ras_n, rd_n,
                                     ~roma_n, ~romb_n, ~ram_n, ~kybd_n, ~vid_n, ~mem_n,
                                     e_roma, e_romb, e_ram, e_kybd, e_vid, e_mem);
                        errors++;
                    end
                    n_active = int'(!roma_n) + int'(!romb_n) + int'(!ram_n)
                             + int'(!kybd_n) + int'(!vid_n);
                    if (n_active > 1) begin
                        if (errors < 10)
                            $display("FAIL  addr %04h: %0d selects active at once",
                                     addr, n_active);
                        errors++;
                    end
                    checked++;
                end
            end
        end
        $display("  ok  full sweep: %0d decoder states against the map", checked);
    endtask

    // ------------------------------------------------------------------
    // Named anchors from SPEC §3 — redundant with the sweep, but each
    // line is a sentence someone might want to see asserted by name.
    // ------------------------------------------------------------------
    task automatic check_anchor(input logic [15:0] ad, input string what,
                                input logic e_r, input logic e_b, input logic e_m,
                                input logic e_k, input logic e_v);
        addr = ad; ras_n = 0; rd_n = 0;
        #1;
        if ({~roma_n, ~romb_n, ~ram_n, ~kybd_n, ~vid_n}
            !== {e_r, e_b, e_m, e_k, e_v}) begin
            $display("FAIL  anchor %s (%04h)", what, ad);
            errors++;
        end else
            $display("  ok  %04h  %s", ad, what);
    endtask

    // ------------------------------------------------------------------
    // Through to chapter 3: only 0x3C00-0x3FFF reaches the video RAM.
    // ------------------------------------------------------------------
    task automatic bus_write(input logic [15:0] ad, input logic [7:0] d);
        @(negedge clk);
        addr = ad; cpu_d = d; ras_n = 0;
        @(negedge clk);
        wr_n = 0;
        repeat (3) @(negedge clk);
        wr_n = 1;
        @(negedge clk);
        ras_n = 1;
    endtask

    task automatic bus_read(input logic [15:0] ad,
                            output logic [7:0] d, output logic hit);
        @(negedge clk);
        addr = ad; ras_n = 0; rd_n = 0;
        repeat (2) @(negedge clk);
        hit = dout_en;                   // Z60/Z44 answered
        d   = dout;
        rd_n = 1;
        @(negedge clk);
        ras_n = 1;
    endtask

    task automatic check_vram_window;
        logic [7:0] got;
        logic       hit;
        bus_write(16'h3C00, 8'h01);      // lands
        bus_write(16'h3801, 8'h3F);      // keyboard window: must NOT land
        bus_write(16'h4000, 8'h3F);      // RAM window: must NOT land
        bus_write(16'h3FFF, 8'h2A);      // last cell lands
        bus_read(16'h3C00, got, hit);
        if (!hit || got !== 8'h41) begin // 0x01 stored, sneaky NOR -> 'A'
            $display("FAIL  vram[3C00] readback %02h (hit=%b), want 41", got, hit);
            errors++;
        end
        bus_read(16'h3FFF, got, hit);
        if (!hit || got !== 8'h2A) begin // bit5 set, NOR blocked -> unchanged
            $display("FAIL  vram[3FFF] readback %02h (hit=%b), want 2A", got, hit);
            errors++;
        end
        bus_read(16'h3801, got, hit);    // keyboard address: buffers stay shut
        if (hit) begin
            $display("FAIL  video RAM answered a keyboard address");
            errors++;
        end
        $display("  ok  decoder->vram: only 3C00-3FFF reaches the video RAM");
    endtask

    // ------------------------------------------------------------------
    initial begin
        $dumpfile("build/tb_m1_addr_decode.vcd");
        $dumpvars(0, tb_m1_addr_decode);

        addr = '0; ras_n = 1; rd_n = 1; wr_n = 1; cpu_d = '0;

        sweep();

        check_anchor(16'h0000, "ROM A start (Level II 8K)", 1,0,0,0,0);
        check_anchor(16'h1FFF, "ROM A end",                 1,0,0,0,0);
        check_anchor(16'h2000, "ROM B start (Level II 4K)", 0,1,0,0,0);
        check_anchor(16'h2FFF, "ROM B end",                 0,1,0,0,0);
        check_anchor(16'h3000, "open bus",                  0,0,0,0,0);
        check_anchor(16'h37FF, "open bus",                  0,0,0,0,0);
        check_anchor(16'h3800, "keyboard",                  0,0,0,1,0);
        check_anchor(16'h3BFF, "keyboard mirror end",       0,0,0,1,0);
        check_anchor(16'h3C00, "video RAM",                 0,0,0,0,1);
        check_anchor(16'h4000, "RAM start",                 0,0,1,0,0);
        check_anchor(16'h7FFF, "RAM end (16K)",             0,0,1,0,0);
        check_anchor(16'h8000, "upper 32K: not this board", 0,0,0,0,0);

        check_vram_window();

        if (errors == 0) $display("\nALL CHECKS PASSED");
        else             $display("\n%0d CHECKS FAILED", errors);
        if (errors != 0) $fatal(1);
        $finish;
    end

    initial begin
        #50_000_000;
        $display("FAIL  watchdog timeout");
        $fatal(1);
    end

endmodule
