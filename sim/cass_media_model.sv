// Testbench model: cassette deck for the M2 tape path.
//
// Plays a pulse list (+cas=<file>, one decimal microsecond timestamp
// per line — tools/build_cas.py) into cass_in. The tape starts rolling
// on the rising edge of the motor relay and pauses when the motor
// drops, like a real CTR-41 with the remote plug: timestamps count
// MOTOR-ON time, not wall time. Each pulse drives cass_in high for
// PULSE_US — the shape the analog front end (Z4 filter/rectifier/level
// detector) delivers to the digital side; the analog half itself is
// media-layer work by design (it never was on the CPU board).

`timescale 1ns / 1ps

module cass_media_model #(
    parameter int          PULSE_US = 50,
    parameter logic [24:0] ACC_K    = 25'd1576139   // 1 MHz off the dot clock
) (
    input  logic clk,          // dot clock
    input  logic motor,        // cassette relay (port 0xFF D2)
    output logic cass_in
);

    // 1 MHz enable: same phase-accumulator idiom as m1_ei (ADR-0001)
    logic [23:0] acc;
    logic [24:0] acc_n;
    logic        en_1m;
    assign acc_n = {1'b0, acc} + ACC_K;
    assign en_1m = acc_n[24];
    always @(posedge clk)
        acc <= acc_n[23:0];

    int pulses [0:65535];
    int npulses;

    initial begin
        string fn;
        int fd, t, r;
        npulses = 0;
        cass_in = 0;
        acc     = '0;
        if ($value$plusargs("cas=%s", fn)) begin
            fd = $fopen(fn, "r");
            if (fd != 0) begin
                r = $fscanf(fd, "%d", t);
                while (r == 1 && npulses < 65536) begin
                    pulses[npulses] = t;
                    npulses++;
                    r = $fscanf(fd, "%d", t);
                end
                $fclose(fd);
            end
        end
    end

    int pos_us;                // tape position (motor-on microseconds)
    int nxt;                   // next pulse index
    int high_us;               // remaining pulse width
    initial begin pos_us = 0; nxt = 0; high_us = 0; end

    always @(posedge clk) begin
        if (en_1m) begin
            if (motor) begin
                pos_us <= pos_us + 1;
                if (nxt < npulses && pos_us >= pulses[nxt]) begin
                    high_us <= PULSE_US;
                    nxt     <= nxt + 1;
                end else if (high_us > 0)
                    high_us <= high_us - 1;
            end else if (high_us > 0)
                high_us <= high_us - 1;
            cass_in <= (high_us > 0);
        end
    end

endmodule
