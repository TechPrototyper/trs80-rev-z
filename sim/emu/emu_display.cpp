// TRS-80 Rev Z — emulator display implementation
//
// Mirrors m1_scan_fb.v: same coordinate formula, same dot-within-cell
// tracking from the lagging column counter. Skin mode paints a
// procedural Model 1 monitor front once into a static texture and
// projects the picture through a barrel-distorted vertex grid.

#include "emu_display.h"
#include "emu_keyboard.h"
#include <cmath>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <string>

// Vendored public-domain JPEG/PNG decoder (SDL2 core only loads BMP);
// see third_party/stb_image.h for its own license block and CREDITS.md.
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_JPEG
#define STBI_ONLY_PNG
#include "third_party/stb_image.h"

// ---------------------------------------------------------------------------
// Procedural bezel painting helpers (ARGB, CPU-side, once at startup)
// ---------------------------------------------------------------------------
namespace {

struct Canvas {
    std::vector<uint32_t> px;
    int w, h;
    Canvas(int w_, int h_) : px((size_t)w_ * h_, 0xFF000000), w(w_), h(h_) {}
    void set(int x, int y, uint32_t c)
    {
        if (x >= 0 && x < w && y >= 0 && y < h)
            px[(size_t)y * w + x] = c;
    }
};

uint32_t lerp_c(uint32_t a, uint32_t b, float t)
{
    auto ch = [&](int sh) {
        float va = (float)((a >> sh) & 0xFF), vb = (float)((b >> sh) & 0xFF);
        return (uint32_t)(va + (vb - va) * t) << sh;
    };
    return 0xFF000000 | ch(16) | ch(8) | ch(0);
}

// Rounded rectangle with a vertical top->bottom gradient.
void rrect(Canvas& c, int x, int y, int w, int h, int r,
           uint32_t top, uint32_t bot)
{
    for (int j = 0; j < h; j++) {
        uint32_t col = lerp_c(top, bot, (float)j / (float)(h - 1));
        for (int i = 0; i < w; i++) {
            int dx = (i < r) ? r - i : (i >= w - r) ? i - (w - r - 1) : 0;
            int dy = (j < r) ? r - j : (j >= h - r) ? j - (h - r - 1) : 0;
            if (dx > 0 && dy > 0 && dx * dx + dy * dy > r * r)
                continue;
            c.set(x + i, y + j, col);
        }
    }
}

void circle(Canvas& c, int cx, int cy, int r, uint32_t col)
{
    for (int j = -r; j <= r; j++)
        for (int i = -r; i <= r; i++)
            if (i * i + j * j <= r * r)
                c.set(cx + i, cy + j, col);
}

void knob(Canvas& c, int cx, int cy, int r, float pointer_deg)
{
    circle(c, cx, cy, r + 2, 0xFF141412);          // recess
    circle(c, cx, cy, r, 0xFF3C3A36);
    circle(c, cx, cy, r - 3, 0xFF52504A);
    float a = pointer_deg * (float)M_PI / 180.0f;
    for (int t = 2; t < r - 2; t++)
        circle(c, cx + (int)(sinf(a) * (float)t),
               cy - (int)(cosf(a) * (float)t), 1, 0xFFE8E4DA);
}

}  // namespace

// ---------------------------------------------------------------------------
EmuDisplay::EmuDisplay(int scale, bool hidden, Skin skin)
    : scale_(scale), skin_(skin)
{
    if (SDL_Init(SDL_INIT_VIDEO) != 0)
        throw std::runtime_error(SDL_GetError());

    if (skin_ == Skin::NONE) {
        winw_ = W * scale_;
        winh_ = H * scale_;
    } else if (load_photo()) {
        winw_ = photo_w_;                  // window adopts the photo
        winh_ = photo_h_;
    } else {
        winw_ = 1040;                      // procedural fallback layout
        winh_ = 800;
    }

    // hidden: scripted/CI runs — no window on screen, no focus stolen
    // from whatever the user is typing into (a background test window
    // once swallowed a whole chat message as TRS-80 keystrokes)
    win_ = SDL_CreateWindow(
        "TRS-80 Model I — Rev Z",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        winw_, winh_,
        hidden ? SDL_WINDOW_HIDDEN : SDL_WINDOW_SHOWN);
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
    SDL_SetTextureBlendMode(tex_, SDL_BLENDMODE_BLEND);

    if (skin_ != Skin::NONE) {
        SDL_SetTextureScaleMode(tex_, SDL_ScaleModeLinear);
        phosphor_ = (skin_ == Skin::GREEN) ? 0xFF7CFF9C   // P1 green
                                           : 0xFFE9EFFF;  // P4 blue-white
        build_bezel();
        // tube picture area: measured on the photo's glass (or, in the
        // fallback, matching the procedural cutout)
        if (photo_ok_ && skin_ == Skin::GREY)
            build_grid(452.0f, 315.0f, 292.0f, 232.0f);
        else if (photo_ok_)
            build_grid(381.0f, 303.0f, 258.0f, 200.0f);
        else
            build_grid(520.0f, 356.0f, 348.0f, 238.0f);
    }

    memset(fb_, 0, sizeof(fb_));
}

// Load the photographic monitor front for the chosen skin.
// assets/skin_grey.jpg: Tandy Video Display, cropped from "TRS-80
// model 1" by Jason Scott (Wikimedia Commons, CC BY 2.0), lit test
// pattern retouched to an unpowered tube. assets/skin_green.jpg:
// cropped from "TRS-80 Model I - Rechnermuseum" by Flominator/
// ProhibitOnions (Wikimedia Commons, CC BY-SA 3.0). Full provenance
// in CREDITS.md.
bool EmuDisplay::load_photo()
{
    const char* name = (skin_ == Skin::GREY) ? "skin_grey.jpg"
                                             : "skin_green.jpg";
    std::vector<std::string> dirs = {"assets/", "../assets/",
                                     "../../assets/", "../../../assets/",
                                     "../../../../assets/"};
    if (char* base = SDL_GetBasePath()) {
        std::string b(base);
        SDL_free(base);
        for (auto rel : {"assets/", "../../assets/", "../../../assets/",
                         "../../../../assets/"})
            dirs.push_back(b + rel);
    }
    for (const auto& d : dirs) {
        std::string path = d + name;
        int w = 0, h = 0, comp = 0;
        unsigned char* img = stbi_load(path.c_str(), &w, &h, &comp, 4);
        if (!img)
            continue;
        photo_px_.resize((size_t)w * h);
        for (size_t i = 0; i < (size_t)w * h; i++) {
            const unsigned char* p = img + i * 4;
            photo_px_[i] = 0xFF000000u | ((uint32_t)p[0] << 16)
                         | ((uint32_t)p[1] << 8) | (uint32_t)p[2];
        }
        stbi_image_free(img);
        photo_w_ = w;
        photo_h_ = h;
        photo_ok_ = true;
        fprintf(stderr, "emu_display: photo bezel %s (%dx%d)\n",
                path.c_str(), w, h);
        return true;
    }
    fprintf(stderr,
            "emu_display: no photo bezel found (%s) — procedural front\n",
            name);
    return false;
}

// Paint the monitor front once: the photo when one was found, else the
// procedural drawing. Fallback layout (1040x800): case body with
// rounded corners, darker front panel, black tube cutout around the
// picture, controls at the bottom.
void EmuDisplay::build_bezel()
{
    if (photo_ok_) {
        bezel_ = SDL_CreateTexture(ren_, SDL_PIXELFORMAT_ARGB8888,
                                   SDL_TEXTUREACCESS_STATIC,
                                   photo_w_, photo_h_);
        SDL_UpdateTexture(bezel_, nullptr, photo_px_.data(),
                          photo_w_ * (int)sizeof(uint32_t));
        return;
    }

    Canvas c(winw_, winh_);

    if (skin_ == Skin::GREY) {
        // first-series RCA-style case: silver-grey shell, charcoal
        // front, the red power key bottom right
        rrect(c, 8, 8, winw_ - 16, winh_ - 16, 34,
              0xFFC9C6BE, 0xFF9B978D);                    // shell
        rrect(c, 52, 48, winw_ - 104, 620, 26,
              0xFF6E6A63, 0xFF57544E);                    // front panel
        rrect(c, 108, 78, winw_ - 216, 554, 40,
              0xFF17181A, 0xFF101113);                    // tube cutout
        // control strip
        rrect(c, 52, 690, winw_ - 104, 74, 12,
              0xFFB4B0A7, 0xFF8F8B82);
        // red power key
        rrect(c, winw_ - 190, 704, 96, 44, 8,
              0xFFC8372E, 0xFF8F1F18);
        // badge
        rrect(c, 84, 712, 220, 30, 6, 0xFF3A3835, 0xFF2C2A28);
    } else {
        // green-phosphor revision: darker two-tone case, full-width
        // bezel plate with three knobs
        rrect(c, 8, 8, winw_ - 16, winh_ - 16, 34,
              0xFFA9AA9E, 0xFF7E7F74);                    // shell
        rrect(c, 48, 44, winw_ - 96, 632, 24,
              0xFF34342F, 0xFF232320);                    // bezel plate
        rrect(c, 104, 76, winw_ - 208, 560, 40,
              0xFF121412, 0xFF0B0D0B);                    // tube cutout
        // knob strip on the plate
        rrect(c, 48, 690, winw_ - 96, 74, 12,
              0xFF2B2B27, 0xFF1D1D1A);
        knob(c, 170, 727, 22, 210.0f);                    // power/volume
        knob(c, 260, 727, 22, 45.0f);                     // brightness
        knob(c, 350, 727, 22, 300.0f);                    // contrast
        rrect(c, winw_ - 300, 712, 220, 30, 6,
              0xFF15514A, 0xFF0E3B36);                    // badge
    }

    bezel_ = SDL_CreateTexture(ren_, SDL_PIXELFORMAT_ARGB8888,
                               SDL_TEXTUREACCESS_STATIC, winw_, winh_);
    SDL_UpdateTexture(bezel_, nullptr, c.px.data(),
                      winw_ * (int)sizeof(uint32_t));
}

// Vertex grid with mild barrel distortion + corner vignette.
void EmuDisplay::build_grid(float cx, float cy, float rx, float ry)
{
    const int NX = 25, NY = 19;
    // Barrel, not pincushion: a CRT face is (very slightly) convex
    // toward the viewer, so straight lines bow OUTWARD, center a hair
    // magnified, corners pinned — the first cut curved the wrong way
    // ("Hohlspiegel") and far too much.
    const float K = 0.016f;
    verts_.clear();
    idx_.clear();
    for (int gy = 0; gy < NY; gy++) {
        for (int gx = 0; gx < NX; gx++) {
            float u = (float)gx / (NX - 1), v = (float)gy / (NY - 1);
            float nx = 2.0f * u - 1.0f, ny = 2.0f * v - 1.0f;
            float r2 = nx * nx + ny * ny;
            float f  = (1.0f - K * r2) / (1.0f - 2.0f * K);
            SDL_Vertex vx{};
            vx.position.x = cx + nx * f * rx;
            vx.position.y = cy + ny * f * ry;
            vx.tex_coord.x = u;
            vx.tex_coord.y = v;
            Uint8 sh = (Uint8)(255.0f * (1.0f - 0.10f * r2));
            vx.color = {sh, sh, sh, 255};
            verts_.push_back(vx);
        }
    }
    for (int gy = 0; gy < NY - 1; gy++)
        for (int gx = 0; gx < NX - 1; gx++) {
            int a = gy * NX + gx, b = a + 1, d = a + NX, e = d + 1;
            idx_.insert(idx_.end(), {a, b, d, b, e, d});
        }
}

EmuDisplay::~EmuDisplay()
{
    if (bezel_) SDL_DestroyTexture(bezel_);
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
    // Upload fb_ to texture (lit dots in the phosphor color).
    void*  pixels;
    int    pitch;
    if (SDL_LockTexture(tex_, nullptr, &pixels, &pitch) != 0)
        return true;

    uint32_t lit = (skin_ == Skin::NONE) ? 0xFFFFFFFF : phosphor_;
    uint32_t* dst = (uint32_t*)pixels;
    for (int i = 0; i < W * H; i++)
        dst[i] = fb_[i] ? lit : 0xFF000000;
    SDL_UnlockTexture(tex_);

    SDL_RenderClear(ren_);
    if (skin_ == Skin::NONE) {
        SDL_RenderCopy(ren_, tex_, nullptr, nullptr);
    } else {
        SDL_RenderCopy(ren_, bezel_, nullptr, nullptr);
        SDL_RenderGeometry(ren_, tex_,
                           verts_.data(), (int)verts_.size(),
                           idx_.data(), (int)idx_.size());
    }

    if (!shot_path_.empty()) {
        SDL_Surface* s = SDL_CreateRGBSurfaceWithFormat(
            0, winw_, winh_, 32, SDL_PIXELFORMAT_ARGB8888);
        if (s && SDL_RenderReadPixels(ren_, nullptr,
                                      SDL_PIXELFORMAT_ARGB8888,
                                      s->pixels, s->pitch) == 0) {
            SDL_SaveBMP(s, shot_path_.c_str());
            fprintf(stderr, "emu_display: shot -> %s\n",
                    shot_path_.c_str());
        }
        if (s) SDL_FreeSurface(s);
        shot_path_.clear();
    }

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
