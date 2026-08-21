// TRS-80 Rev Z — emulator display model
//
// Replaces boards/ulx3s/rtl/m1_scan_fb.v + DVI stack.
//
// write_pixel() is called once per simulated dot clock with the signals
// straight off m1_core (pixel, col, line, row).  It builds a 384×192
// 1-bpp framebuffer using the same coordinate formula the scan-fb RTL uses:
//
//   x = (col - 2) * 6 + dot_in_cell   (col lags two cells behind the shift path)
//   y = row * 12 + line
//
// present() renders the framebuffer. Plain mode scales it into the
// window as before. Skin mode (M7 stage 3) sets the picture into a
// procedurally drawn Model 1 monitor front — the grey first-series
// case (white P4 phosphor, red power key) or the later green-phosphor
// revision (dark bezel, three front knobs) — and bends it over a CRT:
// a vertex grid with mild barrel distortion and a corner vignette,
// "not perfectly straight, but straight enough".

#pragma once
#include <cstdint>
#include <string>
#include <vector>
#include <SDL.h>

// Forward declaration: emu_display optionally forwards key events to the
// keyboard model (avoids a circular header dependency).
class EmuKeyboard;

class EmuDisplay {
public:
    enum class Skin { NONE, GREY, GREEN };

    // scale: integer pixel multiplier (2 or 3 recommended; skin mode
    // sizes its own window and ignores it).
    explicit EmuDisplay(int scale = 2, bool hidden = false,
                        Skin skin = Skin::NONE);
    ~EmuDisplay();

    // Called per dot clock with m1_core's video outputs (after eval()).
    void write_pixel(uint8_t pixel,
                     uint8_t col,   // 7-bit column counter (0..127)
                     uint8_t line,  // 4-bit scan line in character row (0..11)
                     uint8_t row);  // 5-bit character row (0..21)

    // Render the current framebuffer.  Returns false if quit requested.
    bool present();

    // Save the next rendered frame as a BMP (before it is presented).
    void request_shot(const std::string& path) { shot_path_ = path; }

    // Drain pending SDL events, then rebuild the keyboard matrix from the
    // refreshed SDL keyboard state.
    // Returns false if quit requested.  Call once per rendered frame.
    bool poll_events(EmuKeyboard* kbd = nullptr);

private:
    static constexpr int W = 384;
    static constexpr int H = 192;

public:
    // Show the simulated frame count in the window title (scripting aid:
    // --type-at is frame-based and the simulation is deterministic).
    void set_frame(uint64_t frame);

private:
    SDL_Window*   win_  = nullptr;
    SDL_Renderer* ren_  = nullptr;
    SDL_Texture*  tex_  = nullptr;
    SDL_Texture*  bezel_ = nullptr;

    // 1-bpp packed as bytes (1 = white, 0 = black)
    uint8_t fb_[W * H] = {};

    // dot-within-cell tracking (mirrors m1_scan_fb.v)
    uint8_t prev_col_ = 0x7F;
    uint8_t dot_      = 0;

    int  scale_;
    Skin skin_ = Skin::NONE;
    int  winw_ = 0, winh_ = 0;
    uint32_t phosphor_ = 0xFFFFFFFF;

    std::vector<SDL_Vertex> verts_;
    std::vector<int>        idx_;

    std::string shot_path_;

    void build_bezel();
    void build_grid(float cx, float cy, float rx, float ry);
};
