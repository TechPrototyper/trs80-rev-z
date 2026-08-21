// Testbench model: DMK media provider for the FDC track-fetch port.
//
// Loads a DMK image (+dmk=<hex>, one byte per line — build_dmk.py) and
// serves track requests the way the board's SD-backed fetcher will:
// header fields parsed once, then the whole raw track (128-byte IDAM
// table + track bytes) streamed with trk_vld/trk_idx, one byte every
// few clocks, closed by trk_done. trk_len/trk_dbl mirror the header.
// +tferr makes every fetch fail (trk_err) to exercise the refusal path.

`timescale 1ns / 1ps

module dmk_media_model (
    input  logic        clk,
    input  logic        trk_req,
    input  logic [1:0]  trk_drv,     // single image: drive ignored
    input  logic [6:0]  trk_track,
    input  logic        trk_side,    // double-sided DMK: block 2 per cyl
    output logic        trk_vld,
    output logic [7:0]  trk_data,
    output logic [12:0] trk_idx,
    output logic        trk_done,
    output logic        trk_err,
    output logic [12:0] trk_len,
    output logic        trk_dbl,
    output logic        trk_wp,

    // dirty-track write-back: pull the FDC's buffer, store to the image
    input  logic        trk_wb_req,
    output logic        trk_wb_fetch,
    output logic [12:0] trk_wb_idx,
    input  logic [7:0]  trk_wb_data,
    output logic        trk_wb_done,
    output logic        trk_wb_err
);

    logic [7:0] mem [0:262143];      // up to 256 KiB of image
    int         tracklen;
    int         ntracks;
    int         sides;
    bit         fail, wbfail;

    initial begin
        string fn;
        trk_vld = 0; trk_data = 0; trk_idx = 0;
        trk_done = 0; trk_err = 0;
        trk_wb_fetch = 0; trk_wb_idx = 0; trk_wb_done = 0; trk_wb_err = 0;
        fail = $test$plusargs("tferr");
        wbfail = $test$plusargs("wberr");
        if ($value$plusargs("dmk=%s", fn)) begin
            $readmemh(fn, mem);
            ntracks  = int'(mem[1]);
            tracklen = int'({mem[3], mem[2]});
            trk_len  = 13'(tracklen);
            // bits 6/7 set = single-density bytes stored once
            trk_dbl  = (mem[4] & 8'hC0) == 8'h00;
            // bit 4 set = single-sided; clear = two blocks per cylinder
            sides    = ((mem[4] & 8'h10) == 8'h00) ? 2 : 1;
            trk_wp   = (mem[0] == 8'hFF);
        end else begin
            ntracks = 0; tracklen = 0; trk_len = 0; trk_dbl = 0; trk_wp = 0;
            sides = 1;
        end
    end

    always @(posedge clk) begin
        if (trk_req) begin
            if (fail || int'(trk_track) >= ntracks
                || (trk_side && sides == 1)) begin
                trk_err <= 1;
                @(posedge clk);
                trk_err <= 0;
            end else begin
                automatic int base = 16
                    + (int'(trk_track) * sides + int'(trk_side)) * tracklen;
                for (int i = 0; i < tracklen; i++) begin
                    @(posedge clk);
                    trk_vld  <= 1;
                    trk_idx  <= 13'(i);
                    trk_data <= mem[base + i];
                    @(posedge clk);
                    trk_vld <= 0;
                end
                @(posedge clk);
                trk_done <= 1;
                @(posedge clk);
                trk_done <= 0;
            end
        end
    end

    always @(posedge clk) begin
        if (trk_wb_req) begin
            if (wbfail || int'(trk_track) >= ntracks
                || (trk_side && sides == 1)) begin
                trk_wb_err <= 1;
                @(posedge clk);
                trk_wb_err <= 0;
            end else begin
                automatic int base = 16
                    + (int'(trk_track) * sides + int'(trk_side)) * tracklen;
                for (int i = 0; i < tracklen; i++) begin
                    @(posedge clk);
                    trk_wb_fetch <= 1;
                    trk_wb_idx   <= 13'(i);
                    @(posedge clk);
                    trk_wb_fetch <= 0;
                    // the FDC answers two clocks after the fetch edge
                    @(posedge clk);
                    @(posedge clk);
                    mem[base + i] <= trk_wb_data;
                end
                @(posedge clk);
                trk_wb_done <= 1;
                @(posedge clk);
                trk_wb_done <= 0;
            end
        end
    end

    // trk_drv intentionally unused: one image serves all drives here
    wire _unused_ok = &{1'b0, trk_drv};

endmodule
