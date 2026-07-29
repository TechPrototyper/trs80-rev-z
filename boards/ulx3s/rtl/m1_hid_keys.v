// TRS-80 Rev Z — HID keyboard report -> TRS-80 keyboard matrix
//
// The board half of chapter 7: m1_keyboard consumes a 64-bit pressed-key
// matrix; this module produces it from the vendored usb_hid_host core's
// boot-protocol keyboard reports (ADR-0004). Our code, MIT.
//
// Matrix (chapter 7; keys[8*row + col]):
//   row 0:  @ A B C D E F G        row 4:  0 1 2 3 4 5 6 7
//   row 1:  H I J K L M N O        row 5:  8 9 : ; , - . /
//   row 2:  P Q R S T U V W        row 6:  ENTER CLEAR BREAK UP DN LT RT SPC
//   row 3:  X Y Z                  row 7:  SHIFT-L SHIFT-R
//
// A modern keyboard and the Model 1 disagree about which glyphs share a
// key, so the map is *glyph-faithful*, not position-faithful: each HID
// (shift, keycode) pair is translated to the TRS-80 (key, shift) chord
// that produces the same character — e.g. shift+2 (@) becomes the @ key
// unshifted, shift+8 (*) becomes shift+':', the quote key becomes
// shift+2/shift+7. Backspace maps to LEFT (the Model 1's erase), Esc to
// BREAK, Home to CLEAR. Untranslatable glyphs (^ _ [ ] \ { }) drop out —
// the Model 1 simply has no such keys.
//
// Rollover: the boot protocol reports up to four concurrent keys here —
// better than the original matrix's ghosting-free but unencoded raw
// switches. Honest note: real M1 software polls the matrix directly, so
// N-key chords beyond four are clipped by USB, not by us.
//
// Clocking: reports are decoded in the 12 MHz usbclk domain; the matrix
// crosses into the dot-clock domain through a two-stage synchronizer per
// bit (the bits are quasi-static at human typing speed).

module m1_hid_keys (
    // usbclk domain (12 MHz), straight off usb_hid_host
    input  wire        usbclk,
    input  wire        usbrst_n,
    input  wire [1:0]  typ,           // 1 = keyboard
    input  wire        report,        // pulse: key1..4/modifiers valid
    // Only the two shift bits are consumed: the Model 1 has no Ctrl/Alt/GUI.
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [7:0]  key_modifiers, // bit1 = LShift, bit5 = RShift
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire [7:0]  key1,
    input  wire [7:0]  key2,
    input  wire [7:0]  key3,
    input  wire [7:0]  key4,

    // dot-clock domain, to m1_core.keys
    input  wire        clk_dot,
    output wire [63:0] keys
);

    // ------------------------------------------------------------------
    // (shift, HID keycode) -> {valid, force_on, force_off, row, col}
    // ------------------------------------------------------------------
    function automatic [8:0] map_key(input shifted, input [7:0] c);
        reg       v, fon, foff;
        reg [2:0] r, co;
        begin
            v = 1'b1; fon = 1'b0; foff = 1'b0; r = 3'd0; co = 3'd0;
            casez ({shifted, c})
                // letters: A=0x04 -> row 0 col 1, ... contiguous through Z
                {1'b?, 8'h04}: begin r=3'd0; co=3'd1; end  // A
                {1'b?, 8'h05}: begin r=3'd0; co=3'd2; end  // B
                {1'b?, 8'h06}: begin r=3'd0; co=3'd3; end  // C
                {1'b?, 8'h07}: begin r=3'd0; co=3'd4; end  // D
                {1'b?, 8'h08}: begin r=3'd0; co=3'd5; end  // E
                {1'b?, 8'h09}: begin r=3'd0; co=3'd6; end  // F
                {1'b?, 8'h0A}: begin r=3'd0; co=3'd7; end  // G
                {1'b?, 8'h0B}: begin r=3'd1; co=3'd0; end  // H
                {1'b?, 8'h0C}: begin r=3'd1; co=3'd1; end  // I
                {1'b?, 8'h0D}: begin r=3'd1; co=3'd2; end  // J
                {1'b?, 8'h0E}: begin r=3'd1; co=3'd3; end  // K
                {1'b?, 8'h0F}: begin r=3'd1; co=3'd4; end  // L
                {1'b?, 8'h10}: begin r=3'd1; co=3'd5; end  // M
                {1'b?, 8'h11}: begin r=3'd1; co=3'd6; end  // N
                {1'b?, 8'h12}: begin r=3'd1; co=3'd7; end  // O
                {1'b?, 8'h13}: begin r=3'd2; co=3'd0; end  // P
                {1'b?, 8'h14}: begin r=3'd2; co=3'd1; end  // Q
                {1'b?, 8'h15}: begin r=3'd2; co=3'd2; end  // R
                {1'b?, 8'h16}: begin r=3'd2; co=3'd3; end  // S
                {1'b?, 8'h17}: begin r=3'd2; co=3'd4; end  // T
                {1'b?, 8'h18}: begin r=3'd2; co=3'd5; end  // U
                {1'b?, 8'h19}: begin r=3'd2; co=3'd6; end  // V
                {1'b?, 8'h1A}: begin r=3'd2; co=3'd7; end  // W
                {1'b?, 8'h1B}: begin r=3'd3; co=3'd0; end  // X
                {1'b?, 8'h1C}: begin r=3'd3; co=3'd1; end  // Y
                {1'b?, 8'h1D}: begin r=3'd3; co=3'd2; end  // Z

                // digit row, unshifted: plain digits
                {1'b0, 8'h1E}: begin r=3'd4; co=3'd1; end  // 1
                {1'b0, 8'h1F}: begin r=3'd4; co=3'd2; end  // 2
                {1'b0, 8'h20}: begin r=3'd4; co=3'd3; end  // 3
                {1'b0, 8'h21}: begin r=3'd4; co=3'd4; end  // 4
                {1'b0, 8'h22}: begin r=3'd4; co=3'd5; end  // 5
                {1'b0, 8'h23}: begin r=3'd4; co=3'd6; end  // 6
                {1'b0, 8'h24}: begin r=3'd4; co=3'd7; end  // 7
                {1'b0, 8'h25}: begin r=3'd5; co=3'd0; end  // 8
                {1'b0, 8'h26}: begin r=3'd5; co=3'd1; end  // 9
                {1'b0, 8'h27}: begin r=3'd4; co=3'd0; end  // 0

                // digit row, shifted: translate modern glyphs to M1 chords
                {1'b1, 8'h1E}: begin r=3'd4; co=3'd1; end            // ! = shift+1
                {1'b1, 8'h1F}: begin r=3'd0; co=3'd0; foff=1'b1; end // @ key, unshifted
                {1'b1, 8'h20}: begin r=3'd4; co=3'd3; end            // # = shift+3
                {1'b1, 8'h21}: begin r=3'd4; co=3'd4; end            // $ = shift+4
                {1'b1, 8'h22}: begin r=3'd4; co=3'd5; end            // % = shift+5
                {1'b1, 8'h23}: v = 1'b0;                             // ^ has no M1 key
                {1'b1, 8'h24}: begin r=3'd4; co=3'd6; end            // & = M1 shift+6
                {1'b1, 8'h25}: begin r=3'd5; co=3'd2; end            // * = M1 shift+:
                {1'b1, 8'h26}: begin r=3'd5; co=3'd0; end            // ( = M1 shift+8
                {1'b1, 8'h27}: begin r=3'd5; co=3'd1; end            // ) = M1 shift+9

                // punctuation
                {1'b0, 8'h2D}: begin r=3'd5; co=3'd5; end            // -
                {1'b1, 8'h2D}: v = 1'b0;                             // _ has no M1 key
                {1'b0, 8'h2E}: begin r=3'd5; co=3'd5; fon=1'b1; end  // = -> shift+-
                {1'b1, 8'h2E}: begin r=3'd5; co=3'd3; fon=1'b1; end  // + -> shift+;
                {1'b0, 8'h33}: begin r=3'd5; co=3'd3; foff=1'b1; end // ; unshifted
                {1'b1, 8'h33}: begin r=3'd5; co=3'd2; foff=1'b1; end // : unshifted
                {1'b0, 8'h34}: begin r=3'd4; co=3'd7; fon=1'b1; end  // ' -> shift+7
                {1'b1, 8'h34}: begin r=3'd4; co=3'd2; fon=1'b1; end  // " -> shift+2
                {1'b?, 8'h36}: begin r=3'd5; co=3'd4; end            // , (< shifted, matches)
                {1'b?, 8'h37}: begin r=3'd5; co=3'd6; end            // . (> shifted, matches)
                {1'b?, 8'h38}: begin r=3'd5; co=3'd7; end            // / (? shifted, matches)

                // controls and arrows
                {1'b?, 8'h28}: begin r=3'd6; co=3'd0; end  // Enter
                {1'b?, 8'h29}: begin r=3'd6; co=3'd2; end  // Esc       -> BREAK
                {1'b?, 8'h2A}: begin r=3'd6; co=3'd5; end  // Backspace -> LEFT
                {1'b?, 8'h2C}: begin r=3'd6; co=3'd7; end  // Space
                {1'b?, 8'h4A}: begin r=3'd6; co=3'd1; end  // Home      -> CLEAR
                {1'b?, 8'h4F}: begin r=3'd6; co=3'd6; end  // Right
                {1'b?, 8'h50}: begin r=3'd6; co=3'd5; end  // Left
                {1'b?, 8'h51}: begin r=3'd6; co=3'd4; end  // Down
                {1'b?, 8'h52}: begin r=3'd6; co=3'd3; end  // Up

                default: v = 1'b0;
            endcase
            map_key = {v, fon, foff, r, co};
        end
    endfunction

    // ------------------------------------------------------------------
    // Decode a full report combinationally, register it on `report`.
    // ------------------------------------------------------------------
    wire phys_shift = key_modifiers[1] | key_modifiers[5];

    reg  [63:0] mask;
    reg         any_on, any_off;
    reg  [8:0]  m;
    integer     i;
    reg  [7:0]  kc [0:3];

    always @* begin
        kc[0] = key1; kc[1] = key2; kc[2] = key3; kc[3] = key4;
        mask   = 64'd0;
        any_on  = 1'b0;
        any_off = 1'b0;
        for (i = 0; i < 4; i = i + 1) begin
            m = map_key(phys_shift, kc[i]);
            if (m[8]) begin
                mask[{m[5:3], m[2:0]}] = 1'b1;   // keys[8*row + col]
                any_on  = any_on  | m[7];
                any_off = any_off | m[6];
            end
        end
        // shift chord: forced-on wins, then forced-off, then the physical state
        if (any_on)        mask[8*7 + 0] = 1'b1;
        else if (!any_off && phys_shift) begin
            mask[8*7 + 0] = key_modifiers[1];
            mask[8*7 + 1] = key_modifiers[5];
        end
    end

    reg [63:0] keys_usb;
    always @(posedge usbclk or negedge usbrst_n) begin
        if (!usbrst_n)          keys_usb <= 64'd0;
        else if (typ == 2'd0)   keys_usb <= 64'd0;   // no device: all released
        else if (report && typ == 2'd1)
                                keys_usb <= mask;
    end

    // ------------------------------------------------------------------
    // CDC into the dot domain: 2-FF per bit, quasi-static data.
    // ------------------------------------------------------------------
    reg [63:0] sync1, sync2;
    always @(posedge clk_dot) begin
        sync1 <= keys_usb;
        sync2 <= sync1;
    end
    assign keys = sync2;

endmodule
