// TRS-80 Rev Z — emulator keyboard model
//
// Produces the 64-bit TRS-80 keyboard matrix that m1_core expects on its
// `keys[63:0]` input. The mapping mirrors boards/ulx3s/rtl/m1_hid_keys.v
// (glyph-faithful, not position-faithful) — including its architecture:
// the matrix is rebuilt from the complete current keyboard state on every
// update ("current report wins"), never patched incrementally per event.
// SDL scancodes are USB HID usage codes, so the translation table is a
// 1:1 transcription of m1_hid_keys.v's map_key function.
//
// Matrix layout (keys[8*row + col]):
//   row 0:  @ A B C D E F G
//   row 1:  H I J K L M N O
//   row 2:  P Q R S T U V W
//   row 3:  X Y Z
//   row 4:  0 1 2 3 4 5 6 7
//   row 5:  8 9 : ; , - . /
//   row 6:  ENTER CLEAR BREAK UP DN LT RT SPC
//   row 7:  SHIFT-L SHIFT-R

#pragma once
#include <cstdint>
#include <SDL.h>

class EmuKeyboard {
public:
    enum class Layout { US, DE };

    EmuKeyboard() : keys_(0) {}

    // Host keyboard layout: scancodes are physical (HID), so producing
    // the glyph printed on the key needs the host layout. US is the
    // m1_hid_keys.v transcription; DE maps the German legends (Y/Z
    // swapped, ':' on shift+'.', '+'/'*' key, '#'/'\'' key, ...).
    void set_layout(Layout l) { layout_ = l; }

    // Rebuild the matrix from SDL_GetKeyboardState. Call once per frame,
    // after the SDL event queue has been pumped (SDL_PollEvent does that).
    void rebuild();

    // Returns the current 64-bit key matrix for m1_core.keys.
    uint64_t keys() const { return keys_; }

private:
    uint64_t keys_;
    Layout   layout_ = Layout::US;

    // (shift, HID scancode) -> matrix cell with optional shift override;
    // transcribed from m1_hid_keys.v map_key. Returns false if the glyph
    // has no Model 1 equivalent.
    static bool map_key(bool shifted, int scancode,
                        int& row, int& col,
                        bool& force_on, bool& force_off);

    // Same contract for a German (QWERTZ) host keyboard.
    static bool map_key_de(bool shifted, int scancode,
                           int& row, int& col,
                           bool& force_on, bool& force_off);
};
