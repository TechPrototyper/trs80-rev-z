// TRS-80 Rev Z — CPU and control-signal generation
//
// Hardware modeled (Sheet 1 / RetroStack "CPU.kicad_sch"):
//   Z40:       Z80 CPU — implemented by the vendored tv80 core (ADR-0003),
//              Mode 0 (standard Z80 timing), IOWait 1
//   Z23:       74LS32 "backward drawn" ORs of the active-low Z80 pins:
//              RD* = MREQ*+RD*, WR* = MREQ*+WR*, IN* = IORQ*+RD*,
//              OUT* = IORQ*+WR* (Technical Manual 1978, "CPU Control Group")
//   Z72d:      RAS* is the buffered ~MREQ — "the same signal" (Manual p. 273);
//              low on every memory cycle including RAS-only refresh
//   Z73a:      INTAK* = OR(IORQ*, M1*)
//   Z53b/c:    data-bus direction: DBOUT* = NAND(TEST*, ~RD-pin), DBIN* its
//              complement (Manual pp. 174-179) — exactly one direction open
//   Z74a:      NAND(RD*pin, WR*pin) — high while the CPU actually transfers
//              data; releases the DRAM sequencing chain
//   Z69a/b,Z70: the MUX/CAS* sequence for the 4116s: RAS* first, MUX next
//              dot clock, CAS* one more later (Manual p. 275)
//   Z53a,Z37d: reset button (S2/R65/C57) NANDed with ~HALT -> NMI*: the
//              button warm-starts via NMI (0x0066), and a HALT opcode
//              triggers NMI by itself
//   Z53d,Z52e: power-on RC (R47/C42) -> Z80 RESET* (cold start, 0x0000)
//   Z37a:      SYSRES* = NOR(power-on reset, button/halt) to the card edge
//   TEST*:     drives Z80 BUSRQ* directly and (via Z52b "ENABLE*") disables
//              the Z38/Z39 address buffers and the outbound data buffers —
//              an external master can take the bus
//
// Deliberate deviations from the schematic:
//   - Z56/Z72f (the ÷6 CPU clock) live in m1_cpu_clock (chapter 1); this
//     module takes the 1.77408 MHz `cpu_cen` enable (single clock domain,
//     ADR-0001).
//   - The Z80-pin strobes (~MREQ/~IORQ/~RD/~WR) are reconstructed from tv80
//     core state the same way upstream's tv80s wrapper does, but gated by
//     `cpu_cen`. They switch on T-state boundaries; the real chip switches
//     on falling clock edges, half a T-state (3 dots) earlier/later. See
//     chapter 5 §4 for why the VRAM proof is insensitive to this.
//   - Tri-state buffers become value+enable pairs, as in chapter 3:
//     Z38/Z39 (address) -> addr/addr_en, Z55/Z75/Z76 (data) -> dout plus
//     dbout_n/dbin_n.
//   - The 74LS74 asynchronous clears in the Z69/Z70 chain are modeled
//     synchronously at the dot clock (deassert up to 1 dot late). The chain
//     is carried for fidelity/waveforms; our SRAM-backed memory does not
//     consume MUX/CAS*.
//   - The RC networks become clean inputs: por_rst_n (power-on), and
//     reset_btn_n (front-panel button, low = pressed).

module m1_cpu (
    input  wire        clk,          // dot clock, 10.6445 MHz
    input  wire        cpu_cen,      // 1.77408 MHz enable (m1_cpu_clock)
    input  wire        por_rst_n,    // power-on reset (R47/C42), async low
    input  wire        reset_btn_n,  // reset pushbutton S2, low = pressed
    input  wire        test_n,       // TEST* from card edge
    input  wire        int_n,        // INT* from card edge (EI heartbeat)
    input  wire        wait_n,       // WAIT* from card edge
    input  wire [7:0]  din,          // data bus, inbound (Z55/Z76 path)

    output wire [15:0] addr,         // ZA0..ZA15
    output wire        addr_en,      // Z38/Z39 enabled (high = driving)
    output wire [7:0]  dout,         // data bus, outbound (Z75/Z76 path)
    output wire        dbout_n,      // Z53b: low = CPU drives the data bus
    output wire        dbin_n,       // Z53c: low = CPU listens

    output wire        ras_n,        // RAS* (= buffered ~MREQ)
    output wire        rd_n,         // RD*  memory read strobe
    output wire        wr_n,         // WR*  memory write strobe
    output wire        in_n,         // IN*  port read strobe
    output wire        out_n,        // OUT* port write strobe
    output wire        intak_n,      // INTAK* (interrupt acknowledge)
    output wire        sysres_n,     // SYSRES* to the card edge
    output wire        mux,          // DRAM row/column switch (Z69b)
    output wire        cas_n,        // CAS* (Z70)

    output wire        m1_n,         // observability for testbenches
    output wire        halt_n,
    output wire        busak_n,

    // debug-core taps (ADR-0006): the core sits at T1 of an opcode fetch
    // (the freeze point), the 1-clk instant the M1 byte is on the bus,
    // and the interrupt-enable flip-flop (IFF) straight from the core
    output wire        fetch_t1,
    output wire        fetch_lat,
    output wire        inte
);

    // ------------------------------------------------------------------
    // Reset / NMI network (Z53a/d, Z52e, Z37a/d)
    // ------------------------------------------------------------------
    wire nmi_pre  = ~(reset_btn_n & halt_n); // Z53a (Schmitt NAND on the RC)
    wire nmi_n    = ~nmi_pre;                // Z37d (NOR wired as inverter)
    wire por_inv  = ~por_rst_n;              // Z53d (NAND, both inputs tied)
    wire cpu_rst_n = ~por_inv;               // Z52e -> Z80 RESET*
    assign sysres_n = ~(por_inv | nmi_pre);  // Z37a

    // ------------------------------------------------------------------
    // Z40: tv80 core (vendored, ADR-0003).  BUSRQ* is the TEST* line.
    // ------------------------------------------------------------------
    wire        core_iorq;       // positive-logic cycle qualifiers
    wire        core_no_read;
    wire        core_write;
    wire        core_rfsh_n;
    wire        core_intcyc_n;
    wire [6:0]  core_mc;         // one-hot M-cycle
    wire [6:0]  core_ts;         // one-hot T-state
    wire        core_inte;
    wire        core_stop;
    reg  [7:0]  di_reg;          // registered read data (tv80s idiom)

    tv80_core #(.Mode(0), .IOWait(1)) z40 (
        .cen        (cpu_cen),
        .m1_n       (m1_n),
        .iorq       (core_iorq),
        .no_read    (core_no_read),
        .write      (core_write),
        .rfsh_n     (core_rfsh_n),
        .halt_n     (halt_n),
        .wait_n     (wait_n),
        .int_n      (int_n),
        .nmi_n      (nmi_n),
        .reset_n    (cpu_rst_n),
        .busrq_n    (test_n),
        .busak_n    (busak_n),
        .clk        (clk),
        .IntE       (core_inte),
        .stop       (core_stop),
        .A          (addr),
        .dinst      (din),
        .di         (di_reg),
        .dout       (dout),
        .mc         (core_mc),
        .ts         (core_ts),
        .intcycle_n (core_intcyc_n)
    );

    // ------------------------------------------------------------------
    // Z80 pin strobes, reconstructed as in upstream tv80s (same equations,
    // same T2Write=1 write placement) but advanced only on cpu_cen so each
    // level holds for a whole T-state of the 1.77408 MHz clock.
    // ------------------------------------------------------------------
    reg z80_mreq_n, z80_iorq_n, z80_rd_n, z80_wr_n;

    always @(posedge clk or negedge cpu_rst_n) begin
        if (!cpu_rst_n) begin
            z80_mreq_n <= 1'b1;
            z80_iorq_n <= 1'b1;
            z80_rd_n   <= 1'b1;
            z80_wr_n   <= 1'b1;
            di_reg     <= 8'h00;
        end else if (cpu_cen) begin
            z80_mreq_n <= 1'b1;
            z80_iorq_n <= 1'b1;
            z80_rd_n   <= 1'b1;
            z80_wr_n   <= 1'b1;
            if (core_mc[0]) begin
                // M1: opcode fetch (or INTA), refresh in T3/T4
                if (core_ts[1] || (core_ts[2] && !wait_n)) begin
                    z80_rd_n   <= ~core_intcyc_n;
                    z80_mreq_n <= ~core_intcyc_n;
                    z80_iorq_n <=  core_intcyc_n;
                end
`ifdef TV80_REFRESH
                if (core_ts[3])
                    z80_mreq_n <= 1'b0;   // RAS-only refresh window
`endif
            end else begin
                if ((core_ts[1] || (core_ts[2] && !wait_n))
                        && !core_no_read && !core_write) begin
                    z80_rd_n   <= 1'b0;
                    z80_iorq_n <= ~core_iorq;
                    z80_mreq_n <=  core_iorq;
                end
                if ((core_ts[1] || (core_ts[2] && !wait_n)) && core_write) begin
                    z80_wr_n   <= 1'b0;
                    z80_iorq_n <= ~core_iorq;
                    z80_mreq_n <=  core_iorq;
                end
            end
            if (core_ts[2] && wait_n && !core_write && !core_no_read)
                di_reg <= din;
        end
    end

    // ------------------------------------------------------------------
    // Control-signal generation (Z23, Z72d, Z73a) — plain gates
    // ------------------------------------------------------------------
    assign ras_n   = z80_mreq_n;              // Z72d buffer
    assign rd_n    = z80_mreq_n | z80_rd_n;   // Z23b
    assign wr_n    = z80_mreq_n | z80_wr_n;   // Z23d
    assign in_n    = z80_iorq_n | z80_rd_n;   // Z23c
    assign out_n   = z80_iorq_n | z80_wr_n;   // Z23a
    assign intak_n = z80_iorq_n | m1_n;       // Z73a

    // ------------------------------------------------------------------
    // Data-bus access control (Z53b/c) and address buffers (Z38/Z39)
    // ------------------------------------------------------------------
    assign dbout_n = ~(test_n & z80_rd_n);    // Z53b
    assign dbin_n  = ~dbout_n;                // Z53c
    assign addr_en = test_n;                  // Z52b "ENABLE*", inverted twice

    // ------------------------------------------------------------------
    // DRAM signals (Z74a, Z69, Z70): RAS* -> MUX -> CAS*, one dot apart,
    // chain held clear while no data strobe is active.
    // ------------------------------------------------------------------
    // Note: Z74a watches the raw ~RD/~WR pins, so the chain also runs
    // during I/O cycles (with RAS* high) — the 4116s ignore CAS* without
    // a preceding RAS*, and so does our RAM model.
    wire memacc = ~(z80_rd_n & z80_wr_n);     // Z74a
    reg  q69a, q69b, q70;
    always @(posedge clk or negedge cpu_rst_n) begin
        if (!cpu_rst_n) begin
            q69a <= 1'b0; q69b <= 1'b0; q70 <= 1'b0;
        end else if (!memacc) begin
            q69a <= 1'b0; q69b <= 1'b0; q70 <= 1'b0;
        end else begin
            q69a <= 1'b1;                     // Z69a: D = memacc
            q69b <= q69a;                     // Z69b: Q = MUX
            q70  <= q69b;                     // Z70
        end
    end
    // The 74LS74 ~R clears are asynchronous: MUX/CAS* must drop the
    // moment the strobe ends, not a dot later — modeled by gating the
    // outputs with memacc (assert path stays register-timed).
    assign mux   = q69b & memacc;
    assign cas_n = ~(q70 & memacc);

    // ------------------------------------------------------------------
    // Debug-core taps (ADR-0006). fetch_t1: the core rests in T1 of an
    // opcode fetch — gating cpu_cen here freezes the machine with PC on
    // the address bus and the previous instruction complete. fetch_lat
    // pulses (with cpu_cen) at the edge the M1 byte latches into di_reg,
    // i.e. while the opcode is valid on `din` — the prefix tracker in
    // m1_debug samples the bus on it. Both exclude INTA cycles.
    // ------------------------------------------------------------------
    assign fetch_t1  = core_mc[0] & core_ts[1] & core_intcyc_n;
    assign inte      = core_inte;
    assign fetch_lat = cpu_cen & core_mc[0] & core_ts[2] & wait_n
                     & ~core_no_read & ~core_write & core_intcyc_n;

    // Core status outputs we observe but the board does not wire anywhere.
    wire _unused_ok = &{1'b0, core_rfsh_n, core_stop, core_mc[6:1],
                        core_ts[0], core_ts[6:4]};

endmodule
