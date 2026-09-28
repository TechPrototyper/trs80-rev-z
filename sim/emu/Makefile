# TRS-80 Rev Z — interactive Verilator emulator
#
# Builds a single binary 'trs80emu' that runs m1_core under Verilator with
# an SDL2 window for display and keyboard, and DMK files from the host
# filesystem in place of the SD card.
#
# Prerequisites (besides the oss-cad-suite already used by sim/):
#   apt install libsdl2-dev   (Debian/Ubuntu)
#   brew install sdl2         (macOS)
#
# Usage:
#   make                      — build trs80emu
#   make run ROM=path.hex     — build and run (no disk)
#   make run ROM=path.hex DISK0=newdos.dmk   — run with drive 0
#   make dist                 — assemble a release tarball (dist/*.tar.gz):
#                                binary + README + LICENSE/NOTICE + sample
#                                config. DIST_NAME overrides the archive
#                                name (.github/workflows/emu-release.yml
#                                sets it per matrix leg; without it, make
#                                dist guesses from `uname`)
#   make clean

VERILATOR ?= verilator

# RTL sources — identical to the whole-machine list in sim/Makefile
RTL := ../../rtl/m1_video_timing.v \
       ../../rtl/m1_cpu_clock.v    \
       ../../rtl/m1_video_gen.v    \
       ../../rtl/m1_vram.v         \
       ../../rtl/m1_addr_decode.v

CPU_RTL := ../../rtl/vendor/tv80/tv80.vlt \
           ../../rtl/m1_cpu.v             \
           ../../rtl/m1_rom.v             \
           ../../rtl/m1_ram.v             \
           ../../rtl/m1_ei_ram.v          \
           ../../rtl/m1_ei.v              \
           ../../rtl/m1_fdc.v             \
           ../../rtl/m1_drives.v          \
           ../../rtl/m1_debug.v           \
           ../../rtl/vendor/tv80/tv80_core.v  \
           ../../rtl/vendor/tv80/tv80_alu.v   \
           ../../rtl/vendor/tv80/tv80_mcode.v \
           ../../rtl/vendor/tv80/tv80_reg.v

CORE_RTL := ../../rtl/m1_core.v $(RTL) $(CPU_RTL) \
            ../../rtl/m1_io.v ../../rtl/m1_keyboard.v

# Verilator flags for the emulator build (--exe: C++ main, no --binary)
# FONT_HEX defaults to a path relative to sim/ (the testbench cwd); the
# emulator binary can be started from anywhere, so bake in the absolute path.
# MARCH: -march= value for the model build. "native" is right on real
# hardware; CI building portable multi-arch images overrides it (e.g.
# x86-64-v3, armv8-a) so the binary runs on any consumer of the image.
# PROF: hook for profile-guided optimization, e.g.
#   make PROF="-fprofile-generate=/tmp/pgo"   (train, exit cleanly: SIGINT)
#   make PROF="-fprofile-use=/tmp/pgo -fprofile-correction"
# PGO is worth it: +20-27% wall clock measured on both EPYC and Apple M.
MARCH ?= native
PROF  ?=

VFLAGS := --exe --cc -Wall +define+TV80_REFRESH \
          -GFONT_HEX='"$(abspath ../../rtl/mcm6670_cg1.hex)"' \
          -O3 --CFLAGS "-march=$(MARCH) -flto $(PROF)" --LDFLAGS "-flto $(PROF)" \
          -MAKEFLAGS OPT_FAST=-O3 \
          --build -j 0 \
          --Mdir build/emu

SDL2_CFLAGS := $(shell sdl2-config --cflags 2>/dev/null || echo -I/usr/include/SDL2)
SDL2_LIBS   := $(shell sdl2-config --libs   2>/dev/null || echo -lSDL2)

# --debug-pty's openpty() lives in libc on macOS (<util.h>) but needs
# -lutil on glibc (<pty.h>) — see main.cpp's #if defined(__APPLE__).
UNAME_S := $(shell uname -s)
ifneq ($(UNAME_S),Darwin)
SDL2_LIBS += -lutil
endif

CXXFLAGS_EXTRA := $(SDL2_CFLAGS) -O2 -std=c++17
LDFLAGS_EXTRA  := $(SDL2_LIBS)

SRCS := main.cpp emu_disk.cpp emu_cass.cpp emu_audio.cpp emu_keyboard.cpp emu_display.cpp

EMU := build/emu/Vm1_core

# Release tarball name: OS-arch, e.g. trs80-emu-darwin-arm64,
# trs80-emu-linux-x64 (matching oss-cad-suite-build's own asset naming, so
# the two are easy to cross-reference). Override with DIST_NAME=... for CI;
# left alone, `make dist` guesses from the local `uname`.
UNAME_M   := $(shell uname -m)
DIST_OS   := $(shell echo $(UNAME_S) | tr '[:upper:]' '[:lower:]')
DIST_NAME ?= trs80-emu-$(DIST_OS)-$(UNAME_M)
DIST_DIR  := dist/$(DIST_NAME)

.PHONY: all run clean dist

all: $(EMU)

$(EMU): $(SRCS) emu_disk.h emu_keyboard.h emu_display.h $(CORE_RTL) \
        ../../rtl/mcm6670_cg1.hex
	@mkdir -p build/emu
	$(VERILATOR) $(VFLAGS) \
	  --top-module m1_core \
	  -CFLAGS "$(CXXFLAGS_EXTRA)" \
	  -LDFLAGS "$(LDFLAGS_EXTRA)" \
	  $(CORE_RTL) \
	  $(SRCS) \
	  -o Vm1_core

run: $(EMU)
	$(EMU) --rom=$(ROM) \
	  $(if $(DISK0),--disk0=$(DISK0)) \
	  $(if $(DISK1),--disk1=$(DISK1)) \
	  $(if $(DISK2),--disk2=$(DISK2)) \
	  $(if $(DISK3),--disk3=$(DISK3)) \
	  $(if $(THROTTLE),--throttle) \
	  $(EXTRA_ARGS)

dist: $(EMU)
	rm -rf $(DIST_DIR)
	mkdir -p $(DIST_DIR)
	cp $(EMU) $(DIST_DIR)/
	cp README.md $(DIST_DIR)/
	cp trs80revz.sample.json $(DIST_DIR)/
	cp ../../LICENSE $(DIST_DIR)/LICENSE
	cp ../../NOTICE.md $(DIST_DIR)/NOTICE.md
	tar czf dist/$(DIST_NAME).tar.gz -C dist $(DIST_NAME)
	@echo "dist/$(DIST_NAME).tar.gz"

clean:
	rm -rf build/ dist/
