#!/bin/bash
# TRS-80 Rev Z — Codespace setup: build the headless Verilator emulator.
set -e

echo "=== TRS-80 Rev Z: building headless emulator ==="

# --- SDL2 stub (headless: no display server in a codespace) ---
mkdir -p /usr/local/include/SDL2
if [ ! -f /usr/local/include/SDL2/SDL.h ]; then
cat > /usr/local/include/SDL2/SDL.h << 'STUB'
#ifndef SDL_STUB_H
#define SDL_STUB_H
/* Minimal SDL2 stub for headless builds.
   In --hidden mode the display/audio/keyboard paths are never exercised,
   but the symbols must resolve at link time. */
typedef struct SDL_Window SDL_Window;
typedef struct SDL_Renderer SDL_Renderer;
typedef struct SDL_Texture SDL_Texture;
typedef unsigned int Uint32;
typedef unsigned char Uint8;
typedef struct { float x, y, z; unsigned int color; } SDL_Vertex;
#define SDL_QUIT 0x100
#define SDL_KEYDOWN 0x300
#define SDL_KB_RELEASED 0
#define SDL_KB_PRESSED 1
#define SDL_SCANCODE_UNKNOWN 0
#define SDL_TEXTUREACCESS_STATIC 0
#define SDL_WINDOW_HIDDEN 0x00000002
#define SDL_RENDERER_SOFTWARE 0x00000001
static inline int SDL_Init(unsigned long f) { return 0; }
static inline void SDL_Quit(void) {}
static inline int SDL_InitSubSystem(unsigned long f) { return 0; }
static inline void SDL_QuitSubSystem(unsigned long f) {}
static inline const char *SDL_GetError(void) { return ""; }
static inline int SDL_CreateWindow(const char*, unsigned, int, int, unsigned) { return 0; }
static inline void SDL_DestroyWindow(SDL_Window*) {}
static inline SDL_Renderer* SDL_CreateRenderer(SDL_Window*, int, unsigned) { return 0; }
static inline void SDL_DestroyRenderer(SDL_Renderer*) {}
static inline SDL_Texture* SDL_CreateTexture(SDL_Renderer*, unsigned, int, int, int, const void*) { return 0; }
static inline void SDL_DestroyTexture(SDL_Texture*) {}
static inline int SDL_UpdateTexture(SDL_Texture*, const void*, int, int) { return 0; }
static inline int SDL_RenderClear(SDL_Renderer*) { return 0; }
static inline int SDL_RenderFillRect(SDL_Renderer*, const void*) { return 0; }
static inline int SDL_RenderDrawPoints(SDL_Renderer*, const void*, int) { return 0; }
static inline int SDL_RenderCopyEx(SDL_Renderer*, SDL_Texture*, const void*, const void*, float, const void*, unsigned) { return 0; }
static inline int SDL_RenderPresent(SDL_Renderer*) { return 0; }
static inline int SDL_PollEvent(void*) { return 0; }
static inline const Uint8* SDL_GetKeyboardState(int*) { static unsigned char k[512]; return k; }
static inline int SDL_OpenAudio(int, unsigned, int, int, void*, int, int, int) { return 0; }
static inline void SDL_CloseAudio(void) {}
static inline Uint32 SDL_GetPerformanceCounter(void) { return 0; }
static inline Uint32 SDL_GetPerformanceFrequency(void) { return 1000000; }
static inline void SDL_Delay(unsigned int ms) {}
#endif
STUB
fi

# Stub shared library so -lSDL2 resolves
if [ ! -f /usr/local/lib/libSDL2.so ]; then
    echo 'void _sdl_stub_anchor(void) {}' > /tmp/sdl_stub.c
    gcc -shared -o /usr/local/lib/libSDL2.so /tmp/sdl_stub.c
fi

export CPLUS_INCLUDE_PATH="/usr/local/include:${CPLUS_INCLUDE_PATH}"
export LIBRARY_PATH="/usr/local/lib:${LIBRARY_PATH}"

# --- Build ---
cd /workspace/sim/emu
make clean 2>/dev/null || true
make -j"$(nproc)" 2>&1 | tail -10

echo ""
echo "=== Build complete ==="
ls -la build/emu/Vm1_core && echo "Binary OK"
