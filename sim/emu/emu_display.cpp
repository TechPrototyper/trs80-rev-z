// TRS-80 Rev Z — emulator display implementation
//
// Mirrors m1_scan_fb.v: same coordinate formula, same dot-within-cell
// tracking from the lagging column counter.

#include "emu_display.h"
#include "emu_keyboard.h"
#include <cstdio>
#include <cstring>
#include <stdexcept>

EmuDisplay::EmuDisplay(int scale)
    : scale_(scale)
{
    if (SDL_Init(SDL_INIT_VIDEO) != 0)
        throw std::runtime_error(SDL_GetError());

    win_ = SDL_CreateWindow(
        "TRS-80 Model I — Rev Z",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        W * scale_, H * scale_,
        SDL_WINDOW_SHOWN);
    if (!win_) throw std::runtime_error(SDL_GetError());

    ren_ = SDL_CreateRenderer(win_, -1,
        SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    if (!ren_) throw std::runtime_error(SDL_GetError());

    // ARGB8888 texture: width=W, height=H; we upload the fb_ as greyscale.
    tex_ = SDL_CreateTexture(ren_,
        SDL_PIXELFORMAT_ARGB8888,
        SDL_TEXTUREACCESS_STREAMING,
        W, H);
    if (!tex_) throw std::runtime_error(SDL_GetError());

    memset(fb_, 0, sizeof(fb_));
}

EmuDisplay::~EmuDisplay()
{
    if (tex_) SDL_DestroyTexture(tex_);
    if (ren_) SDL_DestroyRenderer(ren_);
    if (win_) SDL_DestroyWindow(win_);
    SDL_Quit();
}

void EmuDisplay::write_pixel(uint8_t pixel,
                              uint8_t col,
                              uint8_t line,
                              uint8_t row)
{
    // Mirror m1_scan_fb.v exactly.
    bool cell_start = (col != prev_col_);
    uint8_t dot_now = cell_start ? 0 : dot_;

    prev_col_ = col;
    dot_ = (dot_now == 7) ? 7 : (dot_now + 1);

    // Visible area: col 2..65, row 0..15, dot 0..5 (6 dots per cell).
    if (col < 2 || col > 65) return;
    if (row >= 16)           return;
    if (dot_now >= 6)        return;

    uint8_t a2 = col - 2;
    int x = (int)a2 * 6 + (int)dot_now;
    int y = (int)row * 12 + (int)line;

    if (x < 0 || x >= W || y < 0 || y >= H) return;
    fb_[y * W + x] = pixel ? 0xFF : 0x00;
}

void EmuDisplay::set_frame(uint64_t frame)
{
    char t[64];
    snprintf(t, sizeof t, "TRS-80 Model I — Rev Z  [f %llu]",
             (unsigned long long)frame);
    SDL_SetWindowTitle(win_, t);
}

bool EmuDisplay::present()
{
    // Upload fb_ to texture as ARGB8888 (grey = 0xFF or 0x00).
    void*  pixels;
    int    pitch;
    if (SDL_LockTexture(tex_, nullptr, &pixels, &pitch) != 0)
        return true;

    uint32_t* dst = (uint32_t*)pixels;
    for (int i = 0; i < W * H; i++) {
        uint8_t v = fb_[i];
        // White pixel: 0xFFFFFFFF; black: 0xFF000000 (full alpha, no alpha).
        dst[i] = v ? 0xFFFFFFFF : 0xFF000000;
    }
    SDL_UnlockTexture(tex_);

    SDL_RenderClear(ren_);
    SDL_RenderCopy(ren_, tex_, nullptr, nullptr);
    SDL_RenderPresent(ren_);
    return true;
}

bool EmuDisplay::poll_events(EmuKeyboard* kbd)
{
    SDL_Event ev;
    while (SDL_PollEvent(&ev)) {
        if (ev.type == SDL_QUIT)
            return false;
    }
    // The event pump above refreshed SDL's keyboard state; derive the whole
    // matrix from it ("current report wins", like m1_hid_keys.v).
    if (kbd)
        kbd->rebuild();
    return true;
}
