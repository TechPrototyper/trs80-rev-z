# TRS-80 Rev Z — simulation harness (Verilator)

VERILATOR ?= verilator
RTL       := ../rtl/m1_video_timing.v ../rtl/m1_cpu_clock.v ../rtl/m1_video_gen.v \
             ../rtl/m1_vram.v ../rtl/m1_addr_decode.v
# CPU sheet: our wrapper + ROM/RAM + the vendored tv80 core with its scoped
# lint waivers (ADR-0003). TV80_REFRESH turns on the R register and the
# refresh M1 cycles (RAS-only refresh).
CPU_RTL   := ../rtl/vendor/tv80/tv80.vlt ../rtl/m1_cpu.v ../rtl/m1_rom.v \
             ../rtl/m1_ram.v ../rtl/m1_ei_ram.v ../rtl/m1_ei.v \
             ../rtl/m1_fdc.v ../rtl/m1_drives.v ../rtl/m1_debug.v \
             ../rtl/vendor/tv80/tv80_core.v \
             ../rtl/vendor/tv80/tv80_alu.v ../rtl/vendor/tv80/tv80_mcode.v \
             ../rtl/vendor/tv80/tv80_reg.v
VFLAGS    := --binary --timing --trace -Wall +define+TV80_REFRESH

TBS       := tb_m1_timing tb_m1_video_gen tb_m1_vram tb_m1_addr_decode tb_m1_io tb_m1_keyboard tb_m1_ei_ram tb_m1_ei tb_m1_fdc tb_m1_cpu
BINS      := $(foreach t,$(TBS),build/$(t)/V$(t))

# Full RTL list for whole-machine builds (m1_core + every block + vendored core)
CORE_RTL  := ../rtl/m1_core.v $(RTL) ../rtl/m1_cpu.v ../rtl/m1_rom.v ../rtl/m1_ram.v \
             ../rtl/m1_ei_ram.v ../rtl/m1_ei.v ../rtl/m1_fdc.v ../rtl/m1_drives.v \
             ../rtl/m1_debug.v \
             ../rtl/m1_io.v ../rtl/m1_keyboard.v \
             ../rtl/vendor/tv80/tv80_core.v ../rtl/vendor/tv80/tv80_alu.v \
             ../rtl/vendor/tv80/tv80_mcode.v ../rtl/vendor/tv80/tv80_reg.v
YOSYS     ?= yosys

.PHONY: all run golden-ram wave wave-gen wave-vram wave-cpu wave-io wave-kbd frames synth clean

all: run

# build + run every testbench
run: $(BINS) build/tb_m1_ram48/Vtb_m1_ram48 build/tb_m1_ei_hb/Vtb_m1_ei_hb build/tb_m1_fdc_sys/Vtb_m1_fdc_sys build/tb_m1_fdc_rd/Vtb_m1_fdc_rd build/tb_m1_fdc_dam/Vtb_m1_fdc_dam build/tb_m1_fdc_wr/Vtb_m1_fdc_wr build/tb_m1_fdc_trk/Vtb_m1_fdc_trk build/tb_m1_fdc_dd/Vtb_m1_fdc_dd build/tb_m1_debug/Vtb_m1_debug build/fdc_disk.hex build/fdc_disk_wp.hex build/fdc_disk_dd.hex build/fdc_dam_disk.hex
	@set -e; for tb in $(TBS); do \
	  echo "=== $$tb ==="; build/$$tb/V$$tb; \
	done
	@echo "=== tb_m1_ram48 (48K machine) ==="
	@build/tb_m1_ram48/Vtb_m1_ram48
	@echo "=== tb_m1_ram48 (16K negative: tags must fail) ==="
	@build/tb_m1_ram48/Vtb_m1_ram48 +noei
	@echo "=== tb_m1_ei_hb (8 heartbeats through the ISR) ==="
	@build/tb_m1_ei_hb/Vtb_m1_ei_hb
	@echo "=== tb_m1_ei_hb (no-EI negative: budget path) ==="
	@build/tb_m1_ei_hb/Vtb_m1_ei_hb +noei
	@echo "=== tb_m1_fdc_sys (WD1771 Type I sequence) ==="
	@build/tb_m1_fdc_sys/Vtb_m1_fdc_sys
	@echo "=== tb_m1_fdc_sys (no-EI negative: float pattern) ==="
	@build/tb_m1_fdc_sys/Vtb_m1_fdc_sys +noei
	@echo "=== tb_m1_fdc_rd (Type II/III reads off the DMK) ==="
	@build/tb_m1_fdc_rd/Vtb_m1_fdc_rd +dmk=build/fdc_disk.hex
	@echo "=== tb_m1_fdc_rd (fetch-refusal negative) ==="
	@build/tb_m1_fdc_rd/Vtb_m1_fdc_rd +dmk=build/fdc_disk.hex +tferr
	@echo "=== tb_m1_fdc_dam (record-type bits, all four DAMs) ==="
	@build/tb_m1_fdc_dam/Vtb_m1_fdc_dam +dmk=build/fdc_dam_disk.hex
	@echo "=== tb_m1_fdc_wr (write + flush round trip) ==="
	@build/tb_m1_fdc_wr/Vtb_m1_fdc_wr +dmk=build/fdc_disk.hex
	@python3 tools/check_dmk_write.py build/written_dmk.hex 2 3
	@echo "=== tb_m1_fdc_wr (write-protect refusal) ==="
	@build/tb_m1_fdc_wr/Vtb_m1_fdc_wr +dmk=build/fdc_disk_wp.hex +wp
	@echo "=== tb_m1_fdc_dd (Percom doubler, mixed-density disk) ==="
	@build/tb_m1_fdc_dd/Vtb_m1_fdc_dd +dmk=build/fdc_disk_dd.hex
	@echo "=== tb_m1_fdc_trk (read track raw + write track format) ==="
	@build/tb_m1_fdc_trk/Vtb_m1_fdc_trk +dmk=build/fdc_disk.hex
	@python3 tools/check_dmk_write.py build/format_dmk.hex 30 0 --e5
	@python3 tools/check_dmk_write.py build/format_dmk.hex 30 1 --e5
	@echo "=== tb_m1_debug (halt/step/breakpoint/memory, ADR-0006) ==="
	@build/tb_m1_debug/Vtb_m1_debug

build/tb_m1_timing/Vtb_m1_timing: tb_m1_timing.sv $(RTL)
	@mkdir -p build/tb_m1_timing
	$(VERILATOR) $(VFLAGS) --Mdir build/tb_m1_timing -o Vtb_m1_timing \
	  --top-module tb_m1_timing tb_m1_timing.sv $(RTL)

build/tb_m1_video_gen/Vtb_m1_video_gen: tb_m1_video_gen.sv $(RTL) ../rtl/mcm6670_cg1.hex
	@mkdir -p build/tb_m1_video_gen
	$(VERILATOR) $(VFLAGS) --Mdir build/tb_m1_video_gen -o Vtb_m1_video_gen \
	  --top-module tb_m1_video_gen tb_m1_video_gen.sv $(RTL)

build/tb_m1_vram/Vtb_m1_vram: tb_m1_vram.sv $(RTL) ../rtl/mcm6670_cg1.hex
	@mkdir -p build/tb_m1_vram
	$(VERILATOR) $(VFLAGS) --Mdir build/tb_m1_vram -o Vtb_m1_vram \
	  --top-module tb_m1_vram tb_m1_vram.sv $(RTL)

build/tb_m1_addr_decode/Vtb_m1_addr_decode: tb_m1_addr_decode.sv $(RTL)
	@mkdir -p build/tb_m1_addr_decode
	$(VERILATOR) $(VFLAGS) --Mdir build/tb_m1_addr_decode -o Vtb_m1_addr_decode \
	  --top-module tb_m1_addr_decode tb_m1_addr_decode.sv $(RTL)

# the chapter-5 test image (this repo's own code — never a Tandy ROM)
build/testimg.hex: tools/build_test_image.py
	@mkdir -p build
	python3 tools/build_test_image.py build

# the EI-RAM test image (ADR-0005 stage 1 — this repo's own code)
build/ramtest.hex: tools/build_ram_test.py
	@mkdir -p build
	cd . && python3 tools/build_ram_test.py

build/tb_m1_ei_ram/Vtb_m1_ei_ram: tb_m1_ei_ram.sv ../rtl/m1_ei_ram.v
	@mkdir -p build/tb_m1_ei_ram
	$(VERILATOR) $(VFLAGS) --Mdir build/tb_m1_ei_ram -o Vtb_m1_ei_ram \
	  --top-module tb_m1_ei_ram tb_m1_ei_ram.sv ../rtl/m1_ei_ram.v

build/tb_m1_ei/Vtb_m1_ei: tb_m1_ei.sv ../rtl/m1_ei.v ../rtl/m1_fdc.v ../rtl/m1_drives.v
	@mkdir -p build/tb_m1_ei
	$(VERILATOR) $(VFLAGS) --Mdir build/tb_m1_ei -o Vtb_m1_ei \
	  --top-module tb_m1_ei tb_m1_ei.sv ../rtl/m1_ei.v ../rtl/m1_fdc.v ../rtl/m1_drives.v

build/tb_m1_fdc/Vtb_m1_fdc: tb_m1_fdc.sv ../rtl/m1_fdc.v ../rtl/m1_drives.v
	@mkdir -p build/tb_m1_fdc
	$(VERILATOR) $(VFLAGS) --Mdir build/tb_m1_fdc -o Vtb_m1_fdc \
	  --top-module tb_m1_fdc tb_m1_fdc.sv ../rtl/m1_fdc.v ../rtl/m1_drives.v

# the FDC Type-I test image (EI stage 2 — this repo's own code)
build/fdctest.hex: tools/build_fdc_test.py
	@mkdir -p build
	cd . && python3 tools/build_fdc_test.py

# the FDC read test image + its DMK disk (EI stage 3 — own code/data)
build/fdcrdtest.hex: tools/build_fdc_rd_test.py
	@mkdir -p build
	cd . && python3 tools/build_fdc_rd_test.py

# the record-type (DAM) probe image + its four-DAM DMK disk
build/fdcdamtest.hex: tools/build_fdc_dam_test.py
	@mkdir -p build
	cd . && python3 tools/build_fdc_dam_test.py

build/fdc_dam_disk.hex: tools/build_dmk.py
	@mkdir -p build
	python3 tools/build_dmk.py --out build/fdc_dam_disk --tracks 5 --damtrk 2

build/fdc_disk.hex: tools/build_dmk.py
	@mkdir -p build
	python3 tools/build_dmk.py --out build/fdc_disk

build/fdc_disk_wp.hex: tools/build_dmk.py
	@mkdir -p build
	python3 tools/build_dmk.py --out build/fdc_disk_wp --wp

build/fdc_disk_dd.hex: tools/build_dmk.py
	@mkdir -p build
	python3 tools/build_dmk.py --out build/fdc_disk_dd --dd --tracks 12

# the DD test image (EI stage 6 — this repo's own code)
build/fdcddtest.hex: tools/build_fdc_dd_test.py
	@mkdir -p build
	cd . && python3 tools/build_fdc_dd_test.py

build/tb_m1_fdc_dd/Vtb_m1_fdc_dd: tb_m1_fdc_dd.sv dmk_media_model.sv ../rtl/m1_core.v $(RTL) $(CPU_RTL) ../rtl/m1_io.v ../rtl/m1_keyboard.v ../rtl/mcm6670_cg1.hex build/fdcddtest.hex build/fdc_disk_dd.hex
	@mkdir -p build/tb_m1_fdc_dd
	$(VERILATOR) $(VFLAGS) --Mdir build/tb_m1_fdc_dd -o Vtb_m1_fdc_dd \
	  --top-module tb_m1_fdc_dd tb_m1_fdc_dd.sv dmk_media_model.sv ../rtl/m1_core.v $(RTL) $(CPU_RTL) ../rtl/m1_io.v ../rtl/m1_keyboard.v

# the track-access test image (EI stage 6a — this repo's own code)
build/fdctrktest.hex: tools/build_fdc_trk_test.py
	@mkdir -p build
	cd . && python3 tools/build_fdc_trk_test.py

build/tb_m1_fdc_trk/Vtb_m1_fdc_trk: tb_m1_fdc_trk.sv dmk_media_model.sv ../rtl/m1_core.v $(RTL) $(CPU_RTL) ../rtl/m1_io.v ../rtl/m1_keyboard.v ../rtl/mcm6670_cg1.hex build/fdctrktest.hex build/fdc_disk.hex
	@mkdir -p build/tb_m1_fdc_trk
	$(VERILATOR) $(VFLAGS) --Mdir build/tb_m1_fdc_trk -o Vtb_m1_fdc_trk \
	  --top-module tb_m1_fdc_trk tb_m1_fdc_trk.sv dmk_media_model.sv ../rtl/m1_core.v $(RTL) $(CPU_RTL) ../rtl/m1_io.v ../rtl/m1_keyboard.v

# the FDC write test image (EI stage 5b — this repo's own code)
build/fdcwrtest.hex: tools/build_fdc_wr_test.py
	@mkdir -p build
	cd . && python3 tools/build_fdc_wr_test.py

build/tb_m1_fdc_wr/Vtb_m1_fdc_wr: tb_m1_fdc_wr.sv dmk_media_model.sv ../rtl/m1_core.v $(RTL) $(CPU_RTL) ../rtl/m1_io.v ../rtl/m1_keyboard.v ../rtl/mcm6670_cg1.hex build/fdcwrtest.hex build/fdc_disk.hex build/fdc_disk_wp.hex
	@mkdir -p build/tb_m1_fdc_wr
	$(VERILATOR) $(VFLAGS) --Mdir build/tb_m1_fdc_wr -o Vtb_m1_fdc_wr \
	  --top-module tb_m1_fdc_wr tb_m1_fdc_wr.sv dmk_media_model.sv ../rtl/m1_core.v $(RTL) $(CPU_RTL) ../rtl/m1_io.v ../rtl/m1_keyboard.v

build/tb_m1_fdc_rd/Vtb_m1_fdc_rd: tb_m1_fdc_rd.sv dmk_media_model.sv ../rtl/m1_core.v $(RTL) $(CPU_RTL) ../rtl/m1_io.v ../rtl/m1_keyboard.v ../rtl/mcm6670_cg1.hex build/fdcrdtest.hex build/fdc_disk.hex
	@mkdir -p build/tb_m1_fdc_rd
	$(VERILATOR) $(VFLAGS) --Mdir build/tb_m1_fdc_rd -o Vtb_m1_fdc_rd \
	  --top-module tb_m1_fdc_rd tb_m1_fdc_rd.sv dmk_media_model.sv ../rtl/m1_core.v $(RTL) $(CPU_RTL) ../rtl/m1_io.v ../rtl/m1_keyboard.v

build/tb_m1_fdc_dam/Vtb_m1_fdc_dam: tb_m1_fdc_dam.sv dmk_media_model.sv ../rtl/m1_core.v $(RTL) $(CPU_RTL) ../rtl/m1_io.v ../rtl/m1_keyboard.v ../rtl/mcm6670_cg1.hex build/fdcdamtest.hex build/fdc_dam_disk.hex
	@mkdir -p build/tb_m1_fdc_dam
	$(VERILATOR) $(VFLAGS) --Mdir build/tb_m1_fdc_dam -o Vtb_m1_fdc_dam \
	  --top-module tb_m1_fdc_dam tb_m1_fdc_dam.sv dmk_media_model.sv ../rtl/m1_core.v $(RTL) $(CPU_RTL) ../rtl/m1_io.v ../rtl/m1_keyboard.v

build/tb_m1_fdc_sys/Vtb_m1_fdc_sys: tb_m1_fdc_sys.sv ../rtl/m1_core.v $(RTL) $(CPU_RTL) ../rtl/m1_io.v ../rtl/m1_keyboard.v ../rtl/mcm6670_cg1.hex build/fdctest.hex
	@mkdir -p build/tb_m1_fdc_sys
	$(VERILATOR) $(VFLAGS) --Mdir build/tb_m1_fdc_sys -o Vtb_m1_fdc_sys \
	  --top-module tb_m1_fdc_sys tb_m1_fdc_sys.sv ../rtl/m1_core.v $(RTL) $(CPU_RTL) ../rtl/m1_io.v ../rtl/m1_keyboard.v

# the EI heartbeat test image (EI stage 1 — this repo's own code)
build/eitest.hex: tools/build_ei_test.py
	@mkdir -p build
	cd . && python3 tools/build_ei_test.py

build/tb_m1_ei_hb/Vtb_m1_ei_hb: tb_m1_ei_hb.sv ../rtl/m1_core.v $(RTL) $(CPU_RTL) ../rtl/m1_io.v ../rtl/m1_keyboard.v ../rtl/mcm6670_cg1.hex build/eitest.hex
	@mkdir -p build/tb_m1_ei_hb
	$(VERILATOR) $(VFLAGS) --Mdir build/tb_m1_ei_hb -o Vtb_m1_ei_hb \
	  --top-module tb_m1_ei_hb tb_m1_ei_hb.sv ../rtl/m1_core.v $(RTL) $(CPU_RTL) ../rtl/m1_io.v ../rtl/m1_keyboard.v

build/tb_m1_ram48/Vtb_m1_ram48: tb_m1_ram48.sv ../rtl/m1_core.v $(RTL) $(CPU_RTL) ../rtl/m1_io.v ../rtl/m1_keyboard.v ../rtl/mcm6670_cg1.hex build/ramtest.hex
	@mkdir -p build/tb_m1_ram48
	$(VERILATOR) $(VFLAGS) --Mdir build/tb_m1_ram48 -o Vtb_m1_ram48 \
	  --top-module tb_m1_ram48 tb_m1_ram48.sv ../rtl/m1_core.v $(RTL) $(CPU_RTL) ../rtl/m1_io.v ../rtl/m1_keyboard.v

build/tb_m1_io/Vtb_m1_io: tb_m1_io.sv ../rtl/m1_io.v
	@mkdir -p build/tb_m1_io
	$(VERILATOR) $(VFLAGS) --Mdir build/tb_m1_io -o Vtb_m1_io \
	  --top-module tb_m1_io tb_m1_io.sv ../rtl/m1_io.v

build/tb_m1_keyboard/Vtb_m1_keyboard: tb_m1_keyboard.sv ../rtl/m1_keyboard.v
	@mkdir -p build/tb_m1_keyboard
	$(VERILATOR) $(VFLAGS) --Mdir build/tb_m1_keyboard -o Vtb_m1_keyboard \
	  --top-module tb_m1_keyboard tb_m1_keyboard.sv ../rtl/m1_keyboard.v

build/tb_m1_cpu/Vtb_m1_cpu: tb_m1_cpu.sv ../rtl/m1_core.v $(RTL) $(CPU_RTL) ../rtl/m1_io.v ../rtl/m1_keyboard.v ../rtl/mcm6670_cg1.hex build/testimg.hex
	@mkdir -p build/tb_m1_cpu
	$(VERILATOR) $(VFLAGS) --Mdir build/tb_m1_cpu -o Vtb_m1_cpu \
	  --top-module tb_m1_cpu tb_m1_cpu.sv ../rtl/m1_core.v $(RTL) $(CPU_RTL) ../rtl/m1_io.v ../rtl/m1_keyboard.v

wave: run
	gtkwave build/tb_m1_timing.vcd &

wave-gen: run
	gtkwave build/tb_m1_video_gen.vcd &

wave-vram: run
	gtkwave build/tb_m1_vram.vcd &

wave-cpu: run
	gtkwave build/tb_m1_cpu.vcd &

wave-io: run
	gtkwave build/tb_m1_io.vcd &

wave-kbd: run
	gtkwave build/tb_m1_keyboard.vcd &

# Golden-model check (SPEC §6): byte-exact VRAM comparison against trs80gp.
# trs80gp is an external macOS app, not part of this repo; set TRS80GP to its
# binary. Note -dx: on Model 1 a custom -rom must boot into ROM (FDC disabled),
# or the emulator waits for a disk and never runs the automation loop.
TRS80GP ?= /Applications/trs80gp.app/Contents/MacOS/trs80gp
golden: build/tb_m1_cpu/Vtb_m1_cpu build/testimg.hex
	@build/tb_m1_cpu/Vtb_m1_cpu >/dev/null   # (re)generate build/vram_cpu.bin
	@test -x "$(TRS80GP)" || { echo "set TRS80GP to the trs80gp binary"; exit 2; }
	@python3 -c "d=open('build/testimg.bin','rb').read(); \
open('build/testimg12k.bin','wb').write(d + b'\0'*(12288-len(d)))"
	@rm -f build/trs80-text-0.bin
	@cd build && "$(TRS80GP)" -m1 -dx -rom testimg12k.bin -turbo -batch \
	  -ik 6 80 -ik 0 02 -id 40 -it -ix >/dev/null 2>&1
	@python3 tools/compare_vram.py build/trs80-text-0.bin build/vram_cpu.bin

# Golden check for the 48K machine (ADR-0005 stage 1): the EI-RAM test
# image against trs80gp -m1 -mem 48. Same pattern as `golden`.
golden-ram: build/tb_m1_ram48/Vtb_m1_ram48 build/ramtest.hex
	@build/tb_m1_ram48/Vtb_m1_ram48 >/dev/null   # (re)generate build/vram_ram48.bin
	@test -x "$(TRS80GP)" || { echo "set TRS80GP to the trs80gp binary"; exit 2; }
	@python3 -c "d=open('build/ramtest.bin','rb').read(); \
open('build/ramtest12k.bin','wb').write(d + b'\0'*(12288-len(d)))"
	@rm -f build/trs80-text-0.bin
	@cd build && "$(TRS80GP)" -m1 -mem 48 -dx -rom ramtest12k.bin -turbo -batch \
	  -id 40 -it -ix >/dev/null 2>&1
	@mv build/trs80-text-0.bin build/trs80-text-ram48.bin
	@python3 tools/compare_vram.py build/trs80-text-ram48.bin build/vram_ram48.bin

# Golden check for the EI heartbeat (EI stage 1). NOTE the flags: -dx
# removes the whole EI (verified 2026-07-24: no heartbeat, 37E0 floats
# 0xFF), so this run keeps the disk hardware and inserts an unformatted
# blank disk with "-d dmk" to make the automation loop start.
golden-ei: build/tb_m1_ei_hb/Vtb_m1_ei_hb build/eitest.hex
	@build/tb_m1_ei_hb/Vtb_m1_ei_hb >/dev/null   # (re)generate build/vram_ei.bin
	@test -x "$(TRS80GP)" || { echo "set TRS80GP to the trs80gp binary"; exit 2; }
	@python3 -c "d=open('build/eitest.bin','rb').read(); \
open('build/eitest12k.bin','wb').write(d + b'\0'*(12288-len(d)))"
	@rm -f build/trs80-text-0.bin
	@cd build && "$(TRS80GP)" -m1 -mem 48 -rom eitest12k.bin -d dmk -turbo -batch \
	  -id 200 -it -ix >/dev/null 2>&1
	@mv build/trs80-text-0.bin build/trs80-text-ei.bin
	@python3 tools/compare_vram.py build/trs80-text-ei.bin build/vram_ei.bin

# Golden check for the WD1771 Type I set (EI stage 2). Same trs80gp
# flags as golden-ei: no -dx, unformatted disk in drive 0 via -d dmk.
golden-fdc: build/tb_m1_fdc_sys/Vtb_m1_fdc_sys build/fdctest.hex
	@build/tb_m1_fdc_sys/Vtb_m1_fdc_sys >/dev/null   # (re)generate build/vram_fdc.bin
	@test -x "$(TRS80GP)" || { echo "set TRS80GP to the trs80gp binary"; exit 2; }
	@python3 -c "d=open('build/fdctest.bin','rb').read(); \
open('build/fdctest12k.bin','wb').write(d + b'\0'*(12288-len(d)))"
	@rm -f build/trs80-text-0.bin
	@cd build && "$(TRS80GP)" -m1 -mem 48 -rom fdctest12k.bin -d dmk -turbo -batch \
	  -id 400 -it -ix >/dev/null 2>&1
	@mv build/trs80-text-0.bin build/trs80-text-fdc.bin
	@python3 tools/compare_vram.py build/trs80-text-fdc.bin build/vram_fdc.bin

# Golden for the stage-5 write scenario: the same image + a THROWAWAY
# copy of the same DMK in trs80gp (it mutates its disk too); the wp run
# uses the write-protected disk. Artifact CRC check on our written media.
golden-fdc-wr: build/tb_m1_fdc_wr/Vtb_m1_fdc_wr build/fdcwrtest.hex
	@build/tb_m1_fdc_wr/Vtb_m1_fdc_wr +dmk=build/fdc_disk.hex >/dev/null
	@python3 tools/check_dmk_write.py build/written_dmk.hex 2 3
	@test -x "$(TRS80GP)" || { echo "set TRS80GP to the trs80gp binary"; exit 2; }
	@python3 -c "d=open('build/fdcwrtest.bin','rb').read(); \
open('build/fdcwrtest12k.bin','wb').write(d + b'\0'*(12288-len(d)))"
	@cp build/fdc_disk.dmk build/wrdisk_gp.dmk
	@rm -f build/trs80-text-0.bin
	@cd build && "$(TRS80GP)" -m1 -mem 48 -rom fdcwrtest12k.bin -d0 wrdisk_gp.dmk -turbo -batch \
	  -id 400 -it -ix >/dev/null 2>&1
	@mv build/trs80-text-0.bin build/trs80-text-fdc-wr.bin
	@python3 tools/compare_vram.py build/trs80-text-fdc-wr.bin build/vram_fdc_wr.bin
	@build/tb_m1_fdc_wr/Vtb_m1_fdc_wr +dmk=build/fdc_disk_wp.hex +wp >/dev/null
	@cp build/fdc_disk_wp.dmk build/wpdisk_gp.dmk
	@rm -f build/trs80-text-0.bin
	@cd build && "$(TRS80GP)" -m1 -mem 48 -rom fdcwrtest12k.bin -d0 wpdisk_gp.dmk -turbo -batch \
	  -id 400 -it -ix >/dev/null 2>&1
	@mv build/trs80-text-0.bin build/trs80-text-fdc-wp.bin
	@python3 tools/compare_vram.py build/trs80-text-fdc-wp.bin build/vram_fdc_wp.bin

# Golden for stage 6: the Percom doubler on the mixed-density disk,
# trs80gp with -ddp on a throwaway copy
golden-fdc-dd: build/tb_m1_fdc_dd/Vtb_m1_fdc_dd build/fdcddtest.hex
	@build/tb_m1_fdc_dd/Vtb_m1_fdc_dd +dmk=build/fdc_disk_dd.hex >/dev/null
	@test -x "$(TRS80GP)" || { echo "set TRS80GP to the trs80gp binary"; exit 2; }
	@python3 -c "d=open('build/fdcddtest.bin','rb').read(); \
open('build/fdcddtest12k.bin','wb').write(d + b'\0'*(12288-len(d)))"
	@cp build/fdc_disk_dd.dmk build/dddisk_gp.dmk
	@rm -f build/trs80-text-0.bin
	@cd build && "$(TRS80GP)" -m1 -mem 48 -rom fdcddtest12k.bin -d0 dddisk_gp.dmk -ddp -turbo -batch \
	  -id 600 -it -ix >/dev/null 2>&1
	@mv build/trs80-text-0.bin build/trs80-text-fdc-dd.bin
	@python3 tools/compare_vram.py build/trs80-text-fdc-dd.bin build/vram_fdc_dd.bin

# Golden for the stage-6a track access (same discipline as fdc-wr)
golden-fdc-trk: build/tb_m1_fdc_trk/Vtb_m1_fdc_trk build/fdctrktest.hex
	@build/tb_m1_fdc_trk/Vtb_m1_fdc_trk +dmk=build/fdc_disk.hex >/dev/null
	@python3 tools/check_dmk_write.py build/format_dmk.hex 30 0 --e5
	@python3 tools/check_dmk_write.py build/format_dmk.hex 30 1 --e5
	@echo "=== tb_m1_debug (halt/step/breakpoint/memory, ADR-0006) ==="
	@build/tb_m1_debug/Vtb_m1_debug
	@test -x "$(TRS80GP)" || { echo "set TRS80GP to the trs80gp binary"; exit 2; }
	@python3 -c "d=open('build/fdctrktest.bin','rb').read(); \
open('build/fdctrktest12k.bin','wb').write(d + b'\0'*(12288-len(d)))"
	@cp build/fdc_disk.dmk build/trkdisk_gp.dmk
	@rm -f build/trs80-text-0.bin
	@cd build && "$(TRS80GP)" -m1 -mem 48 -rom fdctrktest12k.bin -d0 trkdisk_gp.dmk -turbo -batch \
	  -id 600 -it -ix >/dev/null 2>&1
	@mv build/trs80-text-0.bin build/trs80-text-fdc-trk.bin
	@python3 tools/compare_vram.py build/trs80-text-fdc-trk.bin build/vram_fdc_trk.bin

# EI stage 4 — the boot chain with the REAL Level II ROM (external file,
# never committed; ROM policy). ROM= points at a 12288-byte image, DISK=
# at a DMK (default: our own banner boot disk, checked with +banner; a
# real DOS DMK is the stage-4 acceptance — then the golden compare IS
# the check). Skips politely when the ROM is not present.
ROM     ?= $(HOME)/Projects/fpga-trs80/roms/level2_v13.rom
DISK    ?= build/bootdisk
BOOT_MS ?= 2500

build/bootdisk.hex: tools/build_dmk.py
	@mkdir -p build
	python3 tools/build_dmk.py --out build/bootdisk --boot

build/tb_m1_boot/Vtb_m1_boot: tb_m1_boot.sv dmk_media_model.sv ../rtl/m1_core.v $(RTL) $(CPU_RTL) ../rtl/m1_io.v ../rtl/m1_keyboard.v ../rtl/mcm6670_cg1.hex
	@mkdir -p build/tb_m1_boot
	$(VERILATOR) $(VFLAGS) --Mdir build/tb_m1_boot -o Vtb_m1_boot \
	  --top-module tb_m1_boot tb_m1_boot.sv dmk_media_model.sv ../rtl/m1_core.v $(RTL) $(CPU_RTL) ../rtl/m1_io.v ../rtl/m1_keyboard.v

golden-boot: build/tb_m1_boot/Vtb_m1_boot build/bootdisk.hex
	@test -f "$(ROM)" || { echo "SKIP golden-boot: no ROM at $(ROM)"; exit 0; }
	@test -x "$(TRS80GP)" || { echo "set TRS80GP to the trs80gp binary"; exit 2; }
	@python3 -c "d=open('$(ROM)','rb').read(); assert len(d)==12288, len(d); \
open('build/bootrom.hex','w').write('\n'.join('%02x'%b for b in d))"
	@python3 -c "d=open('$(DISK).dmk','rb').read(); \
open('build/bootdmk.hex','w').write('\n'.join('%02x'%b for b in d))"
	@build/tb_m1_boot/Vtb_m1_boot +rom=build/bootrom.hex +dmk=build/bootdmk.hex \
	  +ms=$(BOOT_MS) \
	  $(if $(filter build/bootdisk,$(DISK)),+banner,) >/dev/null
	@rm -f build/trs80-text-0.bin
	@cd build && "$(TRS80GP)" -m1 -mem 48 -rom $(ROM) -d0 $(abspath $(DISK)).dmk -turbo -batch \
	  -id 400 -it -ix >/dev/null 2>&1
	@mv build/trs80-text-0.bin build/trs80-text-boot.bin
	@python3 tools/compare_vram.py build/trs80-text-boot.bin build/vram_boot.bin

# Golden check for the stage-3 sector reads: the same DMK mounted in
# trs80gp (-d0), same flags discipline (no -dx). The RNF path waits out
# real index pulses, so give the emulator time (-id 600).
golden-fdc-rd: build/tb_m1_fdc_rd/Vtb_m1_fdc_rd build/fdcrdtest.hex build/fdc_disk.hex
	@build/tb_m1_fdc_rd/Vtb_m1_fdc_rd +dmk=build/fdc_disk.hex >/dev/null
	@test -x "$(TRS80GP)" || { echo "set TRS80GP to the trs80gp binary"; exit 2; }
	@python3 -c "d=open('build/fdcrdtest.bin','rb').read(); \
open('build/fdcrdtest12k.bin','wb').write(d + b'\0'*(12288-len(d)))"
	@rm -f build/trs80-text-0.bin
	@cd build && "$(TRS80GP)" -m1 -mem 48 -rom fdcrdtest12k.bin -d0 fdc_disk.dmk -batch \
	  -id 600 -it -ix >/dev/null 2>&1
	@mv build/trs80-text-0.bin build/trs80-text-fdc-rd.bin
	@python3 tools/compare_vram.py build/trs80-text-fdc-rd.bin build/vram_fdc_rd.bin

# Golden check for the WD1771 record-type bits: track 2 of the DAM disk
# carries all four DAMs (FB/FA/F9/F8); the probe tags each Type II read
# status. TRS-80 DOS directories use FA/F8 and verify these bits.
golden-fdc-dam: build/tb_m1_fdc_dam/Vtb_m1_fdc_dam build/fdcdamtest.hex build/fdc_dam_disk.hex
	@build/tb_m1_fdc_dam/Vtb_m1_fdc_dam +dmk=build/fdc_dam_disk.hex >/dev/null
	@test -x "$(TRS80GP)" || { echo "set TRS80GP to the trs80gp binary"; exit 2; }
	@python3 -c "d=open('build/fdcdamtest.bin','rb').read(); \
open('build/fdcdamtest12k.bin','wb').write(d + b'\0'*(12288-len(d)))"
	@rm -f build/trs80-text-0.bin
	@cd build && "$(TRS80GP)" -m1 -mem 48 -rom fdcdamtest12k.bin -d0 fdc_dam_disk.dmk -batch \
	  -id 600 -it -ix >/dev/null 2>&1
	@mv build/trs80-text-0.bin build/trs80-text-fdc-dam.bin
	@python3 tools/compare_vram.py build/trs80-text-fdc-dam.bin build/vram_fdc_dam.bin

# render the simulated frames as PNGs (4x, roughly CRT-ish aspect)
frames: run
	python3 tools/pgm2png.py build/frame64.pgm build/frame64.png --scale-x=3 --scale-y=4
	python3 tools/pgm2png.py build/frame32.pgm build/frame32.png --scale-x=3 --scale-y=4
	python3 tools/pgm2png.py build/frame_streaks.pgm build/frame_streaks.png --scale-x=3 --scale-y=4
	python3 tools/pgm2png.py build/frame_cpu.pgm build/frame_cpu.png --scale-x=3 --scale-y=4
	@echo "frames: sim/build/frame64.png, frame32.png, frame_streaks.png, frame_cpu.png"

# Implementability check: synthesize the whole machine for the ECP5 (ULX3S).
# This proves the verified RTL maps to the target and reports resources — it is
# NOT verification (that is `make` + `make golden`). ROM/RAM/VRAM/font infer
# EBR block RAM (DP16KD) via their registered read ports (chapter 8 §5).
synth: build/m1_core.json
build/m1_core.json: $(CORE_RTL)
	@mkdir -p build
	$(YOSYS) -q -p "read_verilog -DTV80_REFRESH -sv $(CORE_RTL); \
	  synth_ecp5 -top m1_core -json build/m1_core.json"
	@echo "synth: ECP5 netlist in build/m1_core.json (see log for LUT/FF/RAM counts)"

# Place & route the whole machine for the ULX3S ECP5 (LFE5U-85F) and read out
# the achieved Fmax at the 10.6445 MHz dot clock. Unconstrained I/O: this is an
# internal-timing / fit estimate for the bare m1_core, not a board build (that
# needs a per-board wrapper + .lpf pin map — the M1 milestone). Still not
# verification (that is `make` + `make golden`).
NEXTPNR ?= nextpnr-ecp5
pnr: build/m1_core.json
	$(NEXTPNR) --85k --freq 10.6445 --json build/m1_core.json \
	  --lpf-allow-unconstrained --report build/m1_core_timing.json \
	  --write build/m1_core_routed.json 2>&1 | tee build/pnr.log | \
	  grep -iE "Max frequency|Info: Device utilisation|TRELLIS_FF|LUT4|DP16KD|Total"
	@echo "pnr: full log in build/pnr.log"

clean:
	rm -rf build

# ---- debug core (ADR-0006 stage A) ----
build/dbgtest.hex: tools/build_dbg_test.py
	@mkdir -p build
	cd . && python3 tools/build_dbg_test.py

build/tb_m1_debug/Vtb_m1_debug: tb_m1_debug.sv ../rtl/m1_core.v $(RTL) $(CPU_RTL) ../rtl/m1_io.v ../rtl/m1_keyboard.v ../rtl/mcm6670_cg1.hex build/dbgtest.hex
	@mkdir -p build/tb_m1_debug
	$(VERILATOR) $(VFLAGS) --Mdir build/tb_m1_debug -o Vtb_m1_debug \
	  --top-module tb_m1_debug tb_m1_debug.sv ../rtl/m1_core.v $(RTL) $(CPU_RTL) ../rtl/m1_io.v ../rtl/m1_keyboard.v
