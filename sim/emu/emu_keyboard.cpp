// TRS-80 Rev Z — emulator keyboard implementation
//
// Mirrors the glyph-faithful mapping in boards/ulx3s/rtl/m1_hid_keys.v,
// architecture included: like the HID module registers a fresh mask per
// report, rebuild() derives the whole matrix from the complete current
// SDL keyboard state. That makes stuck keys impossible by construction —
// a shift override lives exactly as long as the key it belongs to, and
// release order (glyph key vs. shift) cannot strand a matrix bit.
//
// One deliberate difference: m1_hid_keys clips to four concurrent keys
// because the USB boot protocol reports at most four. That is a transport
// artifact of the USB hop, not machine behavior, so it is not modeled here.

#include "emu_keyboard.h"

#include <cstdio>
#include <cstdlib>

// (shift, HID scancode) -> {row, col, force_on, force_off}; transcription
// of m1_hid_keys.v map_key. SDL scancodes are HID usage codes.
bool EmuKeyboard::map_key(bool shifted, int scancode,
                          int& row, int& col,
                          bool& force_on, bool& force_off)
{
    force_on  = false;
    force_off = false;

    // Letters A..Z: HID 0x04..0x1D, contiguous, shift-independent.
    if (scancode >= SDL_SCANCODE_A && scancode <= SDL_SCANCODE_Z) {
        int n = scancode - SDL_SCANCODE_A + 1;   // @=0, A=1 .. Z=26
        row = n >> 3;
        col = n & 7;
        return true;
    }

    switch (scancode) {
    // Digit row, unshifted: plain digits.  Shifted: translate the modern
    // glyph to the Model 1 chord that produces the same character.
    case SDL_SCANCODE_1: row=4; col=1; return true;          // 1 / ! (native)
    case SDL_SCANCODE_2:
        if (shifted) { row=0; col=0; force_off=true; }       // @ key, unshifted
        else         { row=4; col=2; }
        return true;
    case SDL_SCANCODE_3: row=4; col=3; return true;          // 3 / # (native)
    case SDL_SCANCODE_4: row=4; col=4; return true;          // 4 / $ (native)
    case SDL_SCANCODE_5: row=4; col=5; return true;          // 5 / % (native)
    case SDL_SCANCODE_6:
        if (shifted) return false;                           // ^ has no M1 key
        row=4; col=6; return true;
    case SDL_SCANCODE_7:
        if (shifted) { row=4; col=6; }                       // & = M1 shift+6
        else         { row=4; col=7; }
        return true;
    case SDL_SCANCODE_8:
        if (shifted) { row=5; col=2; }                       // * = M1 shift+:
        else         { row=5; col=0; }
        return true;
    case SDL_SCANCODE_9:
        if (shifted) { row=5; col=0; }                       // ( = M1 shift+8
        else         { row=5; col=1; }
        return true;
    case SDL_SCANCODE_0:
        if (shifted) { row=5; col=1; }                       // ) = M1 shift+9
        else         { row=4; col=0; }
        return true;

    // Punctuation
    case SDL_SCANCODE_MINUS:
        if (shifted) return false;                           // _ has no M1 key
        row=5; col=5; return true;
    case SDL_SCANCODE_EQUALS:
        if (shifted) { row=5; col=3; force_on=true; }        // + -> shift+;
        else         { row=5; col=5; force_on=true; }        // = -> shift+-
        return true;
    case SDL_SCANCODE_SEMICOLON:
        if (shifted) { row=5; col=2; force_off=true; }       // : unshifted on M1
        else         { row=5; col=3; force_off=true; }       // ; unshifted on M1
        return true;
    case SDL_SCANCODE_APOSTROPHE:
        if (shifted) { row=4; col=2; force_on=true; }        // " -> shift+2
        else         { row=4; col=7; force_on=true; }        // ' -> shift+7
        return true;
    case SDL_SCANCODE_COMMA:  row=5; col=4; return true;     // , (< matches)
    case SDL_SCANCODE_PERIOD: row=5; col=6; return true;     // . (> matches)
    case SDL_SCANCODE_SLASH:  row=5; col=7; return true;     // / (? matches)

    // Controls and arrows
    case SDL_SCANCODE_RETURN:    row=6; col=0; return true;
    case SDL_SCANCODE_ESCAPE:    row=6; col=2; return true;  // BREAK
    case SDL_SCANCODE_BACKSPACE: row=6; col=5; return true;  // LEFT (erase)
    case SDL_SCANCODE_SPACE:     row=6; col=7; return true;
    case SDL_SCANCODE_HOME:      row=6; col=1; return true;  // CLEAR
    case SDL_SCANCODE_RIGHT:     row=6; col=6; return true;
    case SDL_SCANCODE_LEFT:      row=6; col=5; return true;
    case SDL_SCANCODE_DOWN:      row=6; col=4; return true;
    case SDL_SCANCODE_UP:        row=6; col=3; return true;

    default: return false;
    }
}

// German (QWERTZ) host keyboard: same glyph-faithful idea, but the key
// legends differ — Y/Z swapped, '"' on shift+2, '&' on shift+6, '/' on
// shift+7, '(' ')' on shift+8/9, '=' on shift+0, '?' on shift+ß, the
// '+'/'*' and '#'/'\'' keys, '<'/'>' on the ISO key, ';' ':' on
// shift+','/'.'  Umlaut keys have no Model 1 glyph; Ö keeps the US
// ';'/':' as a convenience since that position is muscle memory.
bool EmuKeyboard::map_key_de(bool shifted, int scancode,
                             int& row, int& col,
                             bool& force_on, bool& force_off)
{
    force_on  = false;
    force_off = false;

    switch (scancode) {
    // QWERTZ: the physical Y position carries Z and vice versa.
    case SDL_SCANCODE_Y: row=3; col=2; return true;          // legend Z
    case SDL_SCANCODE_Z: row=3; col=1; return true;          // legend Y

    // Digit row, German legends. Native M1 chords pass shift through.
    case SDL_SCANCODE_1: row=4; col=1; return true;          // 1 / !
    case SDL_SCANCODE_2: row=4; col=2; return true;          // 2 / "
    case SDL_SCANCODE_3:
        if (shifted) return false;                           // § has no M1 key
        row=4; col=3; return true;
    case SDL_SCANCODE_4: row=4; col=4; return true;          // 4 / $
    case SDL_SCANCODE_5: row=4; col=5; return true;          // 5 / %
    case SDL_SCANCODE_6: row=4; col=6; return true;          // 6 / &
    case SDL_SCANCODE_7:
        if (shifted) { row=5; col=7; force_off=true; }       // / unshifted on M1
        else         { row=4; col=7; }
        return true;
    case SDL_SCANCODE_8: row=5; col=0; return true;          // 8 / (
    case SDL_SCANCODE_9: row=5; col=1; return true;          // 9 / )
    case SDL_SCANCODE_0:
        if (shifted) { row=5; col=5; }                       // = = M1 shift+-
        else         { row=4; col=0; }
        return true;
    case SDL_SCANCODE_MINUS:                                 // ß / ?
        if (shifted) { row=5; col=7; return true; }          // ? = M1 shift+/
        return false;                                        // ß has no M1 key
    case SDL_SCANCODE_EQUALS: return false;                  // ´ / `

    // Ü has no M1 glyph; the +/* key right of it:
    case SDL_SCANCODE_LEFTBRACKET: return false;
    case SDL_SCANCODE_RIGHTBRACKET:
        if (shifted) { row=5; col=2; }                       // * = M1 shift+:
        else         { row=5; col=3; force_on=true; }        // + = M1 shift+;
        return true;

    // Ö: convenience — keep the US ';'/':' of that position.
    case SDL_SCANCODE_SEMICOLON:
        if (shifted) { row=5; col=2; force_off=true; }       // : unshifted on M1
        else         { row=5; col=3; force_off=true; }       // ; unshifted on M1
        return true;
    case SDL_SCANCODE_APOSTROPHE: return false;              // Ä

    // The #/' key (left of ENTER on ISO boards).
    case SDL_SCANCODE_NONUSHASH:
    case SDL_SCANCODE_BACKSLASH:
        if (shifted) { row=4; col=7; }                       // ' = M1 shift+7
        else         { row=4; col=3; force_on=true; }        // # = M1 shift+3
        return true;

    // The </> ISO key next to the left shift.
    case SDL_SCANCODE_NONUSBACKSLASH:
        if (shifted) { row=5; col=6; }                       // > = M1 shift+.
        else         { row=5; col=4; force_on=true; }        // < = M1 shift+,
        return true;

    case SDL_SCANCODE_COMMA:
        if (shifted) { row=5; col=3; force_off=true; }       // ; unshifted on M1
        else         { row=5; col=4; }
        return true;
    case SDL_SCANCODE_PERIOD:
        if (shifted) { row=5; col=2; force_off=true; }       // : unshifted on M1
        else         { row=5; col=6; }
        return true;
    case SDL_SCANCODE_SLASH:                                 // - / _
        if (shifted) return false;                           // _ has no M1 key
        row=5; col=5; return true;

    // Letters (minus Y/Z above), controls, arrows: as in the US map.
    default:
        return map_key(shifted, scancode, row, col, force_on, force_off);
    }
}

void EmuKeyboard::rebuild()
{
    int numkeys = 0;
    const Uint8* st = SDL_GetKeyboardState(&numkeys);

    bool lshift = numkeys > SDL_SCANCODE_LSHIFT && st[SDL_SCANCODE_LSHIFT];
    bool rshift = numkeys > SDL_SCANCODE_RSHIFT && st[SDL_SCANCODE_RSHIFT];
    bool phys_shift = lshift || rshift;

    uint64_t mask = 0;
    bool any_on = false, any_off = false;

    for (int sc = 0; sc < numkeys; sc++) {
        if (!st[sc]) continue;
        int row, col;
        bool fon, foff;
        bool hit = (layout_ == Layout::DE)
                   ? map_key_de(phys_shift, sc, row, col, fon, foff)
                   : map_key(phys_shift, sc, row, col, fon, foff);
        if (!hit) continue;
        mask |= uint64_t(1) << (row * 8 + col);
        any_on  |= fon;
        any_off |= foff;
    }

    // Shift chord: forced-on wins, then forced-off, then the physical state
    // (same resolution order as m1_hid_keys.v).
    if (any_on) {
        mask |= uint64_t(1) << (8 * 7 + 0);
    } else if (!any_off && phys_shift) {
        if (lshift) mask |= uint64_t(1) << (8 * 7 + 0);
        if (rshift) mask |= uint64_t(1) << (8 * 7 + 1);
    }

    // EMU_KBD_LOG=1: trace every matrix change with the scancodes behind
    // it — the tool for "this key types the wrong glyph" reports.
    if (getenv("EMU_KBD_LOG") && mask != keys_) {
        fprintf(stderr, "kbd: layout=%s shift=%d%d mask=%016llx sc=[",
                layout_ == Layout::DE ? "de" : "us", lshift, rshift,
                (unsigned long long)mask);
        for (int sc = 0; sc < numkeys; sc++)
            if (st[sc]) fprintf(stderr, " %02x", sc);
        fprintf(stderr, " ]\n");
        fflush(stderr);
    }

    keys_ = mask;
}
