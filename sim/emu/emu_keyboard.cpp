// TRS-80 Rev Z — emulator keyboard implementation
//
// Mirrors the glyph-faithful mapping in boards/ulx3s/rtl/m1_hid_keys.v.

#include "emu_keyboard.h"
#include <cstring>

void EmuKeyboard::set_bit(int row, int col, bool pressed)
{
    int idx = row * 8 + col;
    if (pressed)
        keys_ |=  (uint64_t(1) << idx);
    else
        keys_ &= ~(uint64_t(1) << idx);
}

// Translate SDL keysym -> TRS-80 matrix cell.
// Returns true if a valid mapping was found.
// force_shift / force_noshift: some glyph translations must override the
// TRS-80 SHIFT key state regardless of the physical key state.
bool EmuKeyboard::translate(const SDL_Keysym& sym,
                             int& row, int& col,
                             bool& force_shift, bool& force_noshift)
{
    force_shift   = false;
    force_noshift = false;

    bool shifted = (sym.mod & (KMOD_LSHIFT | KMOD_RSHIFT)) != 0;

    switch (sym.sym) {
    // Letters (row 0-3): row independent of shift
    case SDLK_a: row=0; col=1; return true;
    case SDLK_b: row=0; col=2; return true;
    case SDLK_c: row=0; col=3; return true;
    case SDLK_d: row=0; col=4; return true;
    case SDLK_e: row=0; col=5; return true;
    case SDLK_f: row=0; col=6; return true;
    case SDLK_g: row=0; col=7; return true;
    case SDLK_h: row=1; col=0; return true;
    case SDLK_i: row=1; col=1; return true;
    case SDLK_j: row=1; col=2; return true;
    case SDLK_k: row=1; col=3; return true;
    case SDLK_l: row=1; col=4; return true;
    case SDLK_m: row=1; col=5; return true;
    case SDLK_n: row=1; col=6; return true;
    case SDLK_o: row=1; col=7; return true;
    case SDLK_p: row=2; col=0; return true;
    case SDLK_q: row=2; col=1; return true;
    case SDLK_r: row=2; col=2; return true;
    case SDLK_s: row=2; col=3; return true;
    case SDLK_t: row=2; col=4; return true;
    case SDLK_u: row=2; col=5; return true;
    case SDLK_v: row=2; col=6; return true;
    case SDLK_w: row=2; col=7; return true;
    case SDLK_x: row=3; col=0; return true;
    case SDLK_y: row=3; col=1; return true;
    case SDLK_z: row=3; col=2; return true;

    // Digits and their shifted glyphs
    case SDLK_0: row=4; col=0; return true;
    case SDLK_1: row=4; col=1; return true;  // ! = shift+1 (native)
    case SDLK_2:
        if (shifted) { // @ key — unshifted on M1
            row=0; col=0; force_noshift=true;
        } else {
            row=4; col=2;
        }
        return true;
    case SDLK_3: row=4; col=3; return true;  // # = shift+3 (native)
    case SDLK_4: row=4; col=4; return true;  // $ = shift+4 (native)
    case SDLK_5: row=4; col=5; return true;  // % = shift+5 (native)
    case SDLK_6:
        if (shifted) { // ^ has no M1 key
            return false;
        }
        row=4; col=6;
        return true;
    case SDLK_7:
        if (shifted) { // & = M1 shift+6
            row=4; col=6;
        } else {
            row=4; col=7;
        }
        return true;
    case SDLK_8:
        if (shifted) { // * = M1 shift+:
            row=5; col=2; force_shift=true;
        } else {
            row=5; col=0;
        }
        return true;
    case SDLK_9:
        if (shifted) { // ( = M1 shift+8
            row=5; col=0; force_shift=true;
        } else {
            row=5; col=1;
        }
        return true;

    // Punctuation
    case SDLK_MINUS:
        if (shifted) { // _ has no M1 key
            return false;
        }
        row=5; col=5;
        return true;
    case SDLK_EQUALS:
        if (shifted) { // + -> shift+;
            row=5; col=3; force_shift=true;
        } else { // = -> shift+-
            row=5; col=5; force_shift=true;
        }
        return true;
    case SDLK_SEMICOLON:
        if (shifted) { // : unshifted on M1
            row=5; col=2; force_noshift=true;
        } else { // ; unshifted on M1
            row=5; col=3; force_noshift=true;
        }
        return true;
    case SDLK_QUOTE:
        if (shifted) { // " -> shift+2
            row=4; col=2; force_shift=true;
        } else { // ' -> shift+7
            row=4; col=7; force_shift=true;
        }
        return true;
    case SDLK_COMMA: row=5; col=4; return true;  // , and < both match
    case SDLK_PERIOD: row=5; col=6; return true;  // . and > both match
    case SDLK_SLASH: row=5; col=7; return true;   // / and ? both match

    // Controls and arrows
    case SDLK_RETURN:    row=6; col=0; return true;
    case SDLK_ESCAPE:    row=6; col=2; return true;  // BREAK
    case SDLK_BACKSPACE: row=6; col=5; return true;  // LEFT (erase)
    case SDLK_SPACE:     row=6; col=7; return true;
    case SDLK_HOME:      row=6; col=1; return true;  // CLEAR
    case SDLK_RIGHT:     row=6; col=6; return true;
    case SDLK_LEFT:      row=6; col=5; return true;
    case SDLK_DOWN:      row=6; col=4; return true;
    case SDLK_UP:        row=6; col=3; return true;

    default: return false;
    }
    return false;
}

void EmuKeyboard::handle(const SDL_Event& ev)
{
    if (ev.type != SDL_KEYDOWN && ev.type != SDL_KEYUP)
        return;

    bool pressed = (ev.type == SDL_KEYDOWN);
    const SDL_Keysym& sym = ev.key.keysym;

    // Shift keys live in row 7
    if (sym.sym == SDLK_LSHIFT) { set_bit(7, 0, pressed); return; }
    if (sym.sym == SDLK_RSHIFT) { set_bit(7, 1, pressed); return; }

    int  row = 0, col = 0;
    bool force_shift = false, force_noshift = false;

    if (!translate(sym, row, col, force_shift, force_noshift))
        return;

    set_bit(row, col, pressed);

    if (pressed) {
        if (force_shift)   { set_bit(7, 0, true); }
        if (force_noshift) { set_bit(7, 0, false); set_bit(7, 1, false); }
    } else {
        // On key-up: clear forced-shift only if it was the responsible key.
        // Simplification: mirroring the HID module's "current report wins"
        // approach — when the key is released the host shift state is restored
        // on the next SDL event (key-up of the shift key if held).
    }
}
