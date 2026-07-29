# TRS-80 Rev Z — ULX3S board build (yosys -> nextpnr-ecp5 -> ecppack)
#
# Targets: make [bit]   full flow to build/ulx3s_top.bit
#          make synth   netlist only
#          make pnr     place & route + timing report
#          make prog    flash to SRAM via openFPGALoader (board attached)
#
# The 85F on the ULX3S is a LFE5U-85F in CABGA381. The 25 MHz input pin is
# constrained in the LPF; the PLL-derived dot clock picks up the --freq
# default (10.6445 MHz).

YOSYS   ?= yosys
NEXTPNR ?= nextpnr-ecp5
ECPPACK ?= ecppack
LOADER  ?= openFPGALoader

RTL_CORE := $(wildcard ../../rtl/*.v) $(wildcard ../../rtl/vendor/tv80/*.v)
RTL_BOARD:= $(wildcard rtl/*.v) $(wildcard vendor/usb_hid_host/*.v) vendor/usb_hid_host/usb_hid_host_rom.hex

.PHONY: all synth pnr bit prog clean

all: bit

# the self-test image is repository code, built by the sim harness
../../sim/build/testimg.hex:
	$(MAKE) -C ../../sim build/testimg.hex

synth: build/ulx3s_top.json
build/ulx3s_top.json: synth.ys $(RTL_BOARD) $(RTL_CORE) ../../rtl/mcm6670_cg1.hex ../../sim/build/testimg.hex
	@mkdir -p build
	$(YOSYS) -q -l build/synth.log synth.ys
	@echo "synth: netlist in build/ulx3s_top.json (log: build/synth.log)"

pnr: build/ulx3s_top.config
build/ulx3s_top.config: build/ulx3s_top.json ulx3s_v20.lpf
	$(NEXTPNR) --85k --package CABGA381 --freq 10.6445 \
	  --json build/ulx3s_top.json --lpf ulx3s_v20.lpf \
	  --textcfg build/ulx3s_top.config \
	  --report build/timing.json 2>&1 | tee build/pnr.log | \
	  grep -iE "Max frequency|Device utilisation|DP16KD|TRELLIS_FF|TRELLIS_COMB|LUT|ERROR"
	@echo "pnr: full log in build/pnr.log"

bit: build/ulx3s_top.bit
build/ulx3s_top.bit: build/ulx3s_top.config
	$(ECPPACK) --compress build/ulx3s_top.config build/ulx3s_top.bit
	@echo "bit: build/ulx3s_top.bit"

prog: build/ulx3s_top.bit
	$(LOADER) -b ulx3s build/ulx3s_top.bit

clean:
	rm -rf build
