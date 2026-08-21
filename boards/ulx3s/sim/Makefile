# TRS-80 Rev Z — board-level simulation (Verilator)
#
# Benches guarding the board glue:
#   tb_tmds      DVI 8b/10b encoder: decode identity, bounded disparity,
#                control tokens
#   tb_scan_fb   capture framebuffer vs the golden-verified frame_cpu.pgm
#                (needs `make` in ../../sim first: testimg.hex + reference)
#   tb_hid_keys  HID report -> TRS-80 matrix map incl. shift translations
#   tb_selftest  power-on self-test loader end to end
#   tb_sd_loader SD/FAT32 ROM loader against a bit-true SPI card model,
#                five runs: pattern (MBR, fragmented chain), the same on
#                an SDSC card, boot-from-SD to the golden marker, and the
#                no-card / no-file fallbacks
#   tb_sd_fs     drive mounts + sector server (EI stage 0): mount mask,
#                fragmented image read in full, random access across
#                drives, partial last sector, refusal paths — three runs
#                (drives, the same on SDSC, and an imageless card)
#   tb_dmk_fetch DMK track fetcher (EI stage 3): header snapshot, two
#                tracks streamed byte-exactly off the FAT-mounted DMK,
#                refusal paths (unmounted drive, track out of range)
#
# The serializer (ODDRX1F vendor primitives) and the vendored USB core
# itself are synthesis territory and stay out.

VERILATOR ?= verilator
PYTHON    ?= python3
VFLAGS    := --binary --timing -Wall +define+TV80_REFRESH

CORE_RTL  := ../../../rtl/m1_core.v ../../../rtl/m1_cpu_clock.v \
             ../../../rtl/m1_video_timing.v ../../../rtl/m1_video_gen.v \
             ../../../rtl/m1_vram.v ../../../rtl/m1_addr_decode.v \
             ../../../rtl/m1_cpu.v ../../../rtl/m1_rom.v ../../../rtl/m1_ram.v \
             ../../../rtl/m1_ei_ram.v ../../../rtl/m1_ei.v ../../../rtl/m1_fdc.v ../../../rtl/m1_drives.v ../../../rtl/m1_debug.v \
             ../../../rtl/m1_io.v ../../../rtl/m1_keyboard.v \
             ../../../rtl/vendor/tv80/tv80.vlt \
             ../../../rtl/vendor/tv80/tv80_core.v ../../../rtl/vendor/tv80/tv80_alu.v \
             ../../../rtl/vendor/tv80/tv80_mcode.v ../../../rtl/vendor/tv80/tv80_reg.v

.PHONY: all run clean

all: run

run: build/tb_tmds/Vtb_tmds build/tb_scan_fb/Vtb_scan_fb build/tb_hid_keys/Vtb_hid_keys build/tb_selftest/Vtb_selftest build/tb_dbg_uart/Vtb_dbg_uart build/tb_sd_loader/Vtb_sd_loader build/tb_sd_fs/Vtb_sd_fs build/tb_dmk_fetch/Vtb_dmk_fetch build/tb_cass_sd/Vtb_cass_sd build/fat_pattern.hex build/fat_boot.hex build/fat_nofile.hex build/fat_drives.hex build/fat_dmk.hex build/fat_cass.hex
	@set -e; for tb in tb_tmds tb_scan_fb tb_hid_keys tb_selftest tb_dbg_uart; do \
	  echo "=== $$tb ==="; build/$$tb/V$$tb; \
	done
	@set -e; \
	echo "=== tb_sd_loader (pattern, MBR + fragmented chain) ==="; \
	build/tb_sd_loader/Vtb_sd_loader +mode=pattern +img=build/fat_pattern.hex +payload=build/fat_pattern.payload.hex +plen=12288; \
	echo "=== tb_sd_loader (pattern, SDSC byte addressing) ==="; \
	build/tb_sd_loader/Vtb_sd_loader +mode=pattern +sdsc +img=build/fat_pattern.hex +payload=build/fat_pattern.payload.hex +plen=12288; \
	echo "=== tb_sd_loader (boot the test image from SD, superfloppy) ==="; \
	build/tb_sd_loader/Vtb_sd_loader +mode=boot +img=build/fat_boot.hex +payload=build/fat_boot.payload.hex +plen=4096; \
	echo "=== tb_sd_loader (no card: fallback) ==="; \
	build/tb_sd_loader/Vtb_sd_loader +mode=nocard; \
	echo "=== tb_sd_loader (no file: fallback) ==="; \
	build/tb_sd_loader/Vtb_sd_loader +mode=nofile +img=build/fat_nofile.hex; \
	echo "=== tb_sd_loader (moody card: init succeeds on the 3rd try) ==="; \
	build/tb_sd_loader/Vtb_sd_loader +mode=pattern +sdflaky +img=build/fat_pattern.hex +payload=build/fat_pattern.payload.hex +plen=12288
	@set -e; \
	echo "=== tb_sd_fs (drive mounts + random access) ==="; \
	build/tb_sd_fs/Vtb_sd_fs +mode=drives +img=build/fat_drives.hex +payload=build/fat_drives.payload.hex +d0=build/fat_drives.d0.hex +d1=build/fat_drives.d1.hex +d3=build/fat_drives.d3.hex +sz0=20000 +sz1=13333 +sz3=24000 +mounts=11; \
	echo "=== tb_sd_fs (drive mounts, SDSC byte addressing) ==="; \
	build/tb_sd_fs/Vtb_sd_fs +mode=drives +sdsc +img=build/fat_drives.hex +payload=build/fat_drives.payload.hex +d0=build/fat_drives.d0.hex +d1=build/fat_drives.d1.hex +d3=build/fat_drives.d3.hex +sz0=20000 +sz1=13333 +sz3=24000 +mounts=11; \
	echo "=== tb_sd_fs (no images: all unmounted) ==="; \
	build/tb_sd_fs/Vtb_sd_fs +mode=none +img=build/fat_nofile.hex; \
	echo "=== tb_dmk_fetch (tracks off the FAT-mounted DMK) ==="; \
	build/tb_dmk_fetch/Vtb_dmk_fetch +img=build/fat_dmk.hex +dmk=../../../sim/build/fdc_disk.hex; \
	echo "=== tb_cass_sd (SD cassette deck: play, rewind, record) ==="; \
	build/tb_cass_sd/Vtb_cass_sd +img=build/fat_cass.hex +cas=build/fat_cass.cas.hex +clen=8

# FAT32 card images for the SD loader bench (simulation tooling; the
# "boot" payload is the repository's own test image, never a Tandy ROM)
build/fat_pattern.hex: tools/build_fat32.py
	@mkdir -p build
	$(PYTHON) tools/build_fat32.py --out build/fat_pattern --pattern 12288 --fragment

build/fat_boot.hex: tools/build_fat32.py ../../../sim/build/testimg.hex
	@mkdir -p build
	$(PYTHON) tools/build_fat32.py --out build/fat_boot --file-hex ../../../sim/build/testimg.hex --superfloppy

build/fat_nofile.hex: tools/build_fat32.py
	@mkdir -p build
	$(PYTHON) tools/build_fat32.py --out build/fat_nofile --pattern 512 --no-file

# drives: 0 = fragmented, 1 = size not a sector multiple, 2 = decoy only,
# 3 = plain (sizes reappear as +sz plusargs in the tb_sd_fs runs above)
build/fat_drives.hex: tools/build_fat32.py
	@mkdir -p build
	$(PYTHON) tools/build_fat32.py --out build/fat_drives --pattern 12288 --fragment \
	  --drive 0:20000:frag --drive 1:13333 --drive 2:empty --drive 3:24000

build/tb_sd_loader/Vtb_sd_loader: tb_sd_loader.sv sd_card_model.sv ../rtl/m1_sd_fs.v ../rtl/sd_spi_host.v ../rtl/m1_selftest_loader.v $(CORE_RTL)
	@mkdir -p build/tb_sd_loader
	$(VERILATOR) $(VFLAGS) --Mdir build/tb_sd_loader -o Vtb_sd_loader \
	  --top-module tb_sd_loader tb_sd_loader.sv sd_card_model.sv \
	  ../rtl/m1_sd_fs.v ../rtl/sd_spi_host.v \
	  ../rtl/m1_selftest_loader.v $(CORE_RTL)

# FAT card with the cassette slots: an 8-byte tape + a CASSOUT target
build/fat_cass.hex: tools/build_fat32.py
	@mkdir -p build
	$(PYTHON) tools/build_fat32.py --out build/fat_cass --pattern 512 \
	  --cassette 8 --cassout 4096

# FAT card carrying the core generator's DMK in DRIVE1 (stage 3)
build/fat_dmk.hex: tools/build_fat32.py ../../../sim/build/fdc_disk.hex
	@mkdir -p build
	$(PYTHON) tools/build_fat32.py --out build/fat_dmk --pattern 512 \
	  --drive 1:@../../../sim/build/fdc_disk.dmk

../../../sim/build/fdc_disk.hex:
	$(MAKE) -C ../../../sim build/fdc_disk.hex

build/tb_dmk_fetch/Vtb_dmk_fetch: tb_dmk_fetch.sv sd_card_model.sv ../rtl/m1_sd_fs.v ../rtl/sd_spi_host.v ../rtl/m1_dmk_fetch.v
	@mkdir -p build/tb_dmk_fetch
	$(VERILATOR) $(VFLAGS) --Mdir build/tb_dmk_fetch -o Vtb_dmk_fetch \
	  --top-module tb_dmk_fetch tb_dmk_fetch.sv sd_card_model.sv \
	  ../rtl/m1_sd_fs.v ../rtl/sd_spi_host.v ../rtl/m1_dmk_fetch.v

build/tb_cass_sd/Vtb_cass_sd: tb_cass_sd.sv sd_card_model.sv ../rtl/m1_sd_fs.v ../rtl/sd_spi_host.v ../rtl/m1_sd_arb.v ../rtl/m1_cass_sd.v
	@mkdir -p build/tb_cass_sd
	$(VERILATOR) $(VFLAGS) --Mdir build/tb_cass_sd -o Vtb_cass_sd \
	  --top-module tb_cass_sd tb_cass_sd.sv sd_card_model.sv \
	  ../rtl/m1_sd_fs.v ../rtl/sd_spi_host.v \
	  ../rtl/m1_sd_arb.v ../rtl/m1_cass_sd.v

build/tb_sd_fs/Vtb_sd_fs: tb_sd_fs.sv sd_card_model.sv ../rtl/m1_sd_fs.v ../rtl/sd_spi_host.v
	@mkdir -p build/tb_sd_fs
	$(VERILATOR) $(VFLAGS) --Mdir build/tb_sd_fs -o Vtb_sd_fs \
	  --top-module tb_sd_fs tb_sd_fs.sv sd_card_model.sv \
	  ../rtl/m1_sd_fs.v ../rtl/sd_spi_host.v

build/tb_selftest/Vtb_selftest: tb_selftest.sv ../rtl/m1_selftest_loader.v $(CORE_RTL)
	@mkdir -p build/tb_selftest
	$(VERILATOR) $(VFLAGS) --Mdir build/tb_selftest -o Vtb_selftest \
	  --top-module tb_selftest tb_selftest.sv ../rtl/m1_selftest_loader.v $(CORE_RTL)

build/tb_hid_keys/Vtb_hid_keys: tb_hid_keys.sv ../rtl/m1_hid_keys.v
	@mkdir -p build/tb_hid_keys
	$(VERILATOR) $(VFLAGS) --Mdir build/tb_hid_keys -o Vtb_hid_keys \
	  --top-module tb_hid_keys tb_hid_keys.sv ../rtl/m1_hid_keys.v

build/tb_tmds/Vtb_tmds: tb_tmds.sv ../rtl/tmds_encoder.v
	@mkdir -p build/tb_tmds
	$(VERILATOR) $(VFLAGS) --Mdir build/tb_tmds -o Vtb_tmds \
	  --top-module tb_tmds tb_tmds.sv ../rtl/tmds_encoder.v

build/tb_scan_fb/Vtb_scan_fb: tb_scan_fb.sv ../rtl/m1_scan_fb.v $(CORE_RTL)
	@mkdir -p build/tb_scan_fb
	$(VERILATOR) $(VFLAGS) --Mdir build/tb_scan_fb -o Vtb_scan_fb \
	  --top-module tb_scan_fb tb_scan_fb.sv ../rtl/m1_scan_fb.v $(CORE_RTL)

clean:
	rm -rf build

build/tb_dbg_uart/Vtb_dbg_uart: tb_dbg_uart.sv ../rtl/dbg_uart.v $(CORE_RTL)
	@mkdir -p build/tb_dbg_uart
	$(VERILATOR) $(VFLAGS) --Mdir build/tb_dbg_uart -o Vtb_dbg_uart \
	  --top-module tb_dbg_uart tb_dbg_uart.sv ../rtl/dbg_uart.v $(CORE_RTL)
