// TRS-80 Rev Z — emulator keyboard model
//
// Translates SDL2 key events into the 64-bit TRS-80 keyboard matrix that
// m1_core expects on its `keys[63:0]` input. The mapping mirrors
// boards/ulx3s/rtl/m1_hid_keys.v (glyph-faithful, not position-faithful).
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
#include <SDL2/SDL.h>

class EmuKeyboard {
public:
    EmuKeyboard() : keys_(0) {}

    // Call for every SDL_KEYDOWN / SDL_KEYUP event.
    void handle(const SDL_Event& ev);

    // Returns the current 64-bit key matrix for m1_core.keys.
    uint64_t keys() const { return keys_; }

private:
    uint64_t keys_;

    void set_bit(int row, int col, bool pressed);

    // Translate an SDL_Keysym to (row,col) with optional shift override.
    // Returns false if the key has no M1 equivalent.
    // force_shift / force_noshift modify the SHIFT row bits.
    bool translate(const SDL_Keysym& sym,
                   int& row, int& col,
                   bool& force_shift, bool& force_noshift);
};
