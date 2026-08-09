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
VFLAGS := --exe --cc --timing -Wall +define+TV80_REFRESH \
          --build -j 0 \
          --Mdir build/emu

SDL2_CFLAGS := $(shell sdl2-config --cflags 2>/dev/null || echo -I/usr/include/SDL2)
SDL2_LIBS   := $(shell sdl2-config --libs   2>/dev/null || echo -lSDL2)

CXXFLAGS_EXTRA := $(SDL2_CFLAGS) -O2 -std=c++17
LDFLAGS_EXTRA  := $(SDL2_LIBS)

SRCS := main.cpp emu_disk.cpp emu_keyboard.cpp emu_display.cpp

EMU := build/emu/Vm1_core

.PHONY: all run clean

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

clean:
	rm -rf build/
