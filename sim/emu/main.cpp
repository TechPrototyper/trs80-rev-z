// TRS-80 Rev Z — interactive Verilator emulator, main entry point
//
// Usage:
//   ./trs80emu --rom=path/to/rom.hex [options]
//
// Options:
//   --rom=<file>      12 KiB Level II ROM image in $readmemh hex format (required)
//   --disk0=<file>    DMK image for drive 0  (raw binary; see tools/build_dmk.py)
//   --disk1=<file>    DMK image for drive 1
//   --disk2=<file>    DMK image for drive 2
//   --disk3=<file>    DMK image for drive 3
//   --wp0..--wp3      Force write-protect on the corresponding drive
//   --scale=<n>       SDL2 window pixel scale (default 2; use 3 for HiDPI)
//   --throttle        Run at ~10.6 MHz real time (default: as fast as possible)
//   --no-ei           Set ei_ram_cfg=00 (16K machine, no EI/FDC)
//   --ei16            Set ei_ram_cfg=01 (32K machine)
//   --ei32            Set ei_ram_cfg=10 (48K machine, default)
//
// The ROM file must be in Verilog $readmemh format — one hex byte per line,
// no address tags.  trs80gp can dump the ROM; see roms/README.md.
//
// Clock domain:
//   m1_core uses a single 10.6445 MHz dot clock.  Without --throttle the
//   simulation runs as fast as Verilator can manage.  With --throttle it
//   inserts host-clock sleeps to pace the simulation to real time.

#include "Vm1_core.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include "emu_disk.h"
#include "emu_keyboard.h"
#include "emu_display.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static void usage(const char* argv0)
{
    fprintf(stderr,
        "Usage: %s --rom=<hex> [--disk0=<dmk>] ... [--scale=2] [--throttle]\n",
        argv0);
}

static std::string arg_value(const std::string& arg, const std::string& prefix)
{
    // Extract the value from "--prefix=value"; returns "" if not this option.
    if (arg.size() > prefix.size() &&
        arg.substr(0, prefix.size()) == prefix)
        return arg.substr(prefix.size());
    return "";
}

// Load a $readmemh hex file (one byte per line, no address tags).
// Returns false on failure.
static bool load_hex(const std::string& path,
                     std::vector<uint8_t>& out)
{
    std::ifstream f(path);
    if (!f) { fprintf(stderr, "Cannot open %s\n", path.c_str()); return false; }
    std::string line;
    while (std::getline(f, line)) {
        // Strip comments (// ...)
        auto pos = line.find("//");
        if (pos != std::string::npos) line.resize(pos);
        // Trim whitespace
        while (!line.empty() && (line.front() == ' ' || line.front() == '\t'))
            line.erase(line.begin());
        while (!line.empty() && (line.back() == ' ' || line.back() == '\t'
                                 || line.back() == '\r'))
            line.pop_back();
        if (line.empty()) continue;
        char* end;
        unsigned long v = strtoul(line.c_str(), &end, 16);
        if (end == line.c_str()) continue;  // skip non-hex lines
        out.push_back((uint8_t)v);
    }
    return true;
}

// ---------------------------------------------------------------------------
// Throttle helper: sleeps to keep simulation at real time.
// 10.6445 MHz = 93.96 ns per half-period (we advance one full period = two
// eval() calls per conceptual clock, but m1_core is purely synchronous so
// we drive it on the posedge only, once per tick).
// ---------------------------------------------------------------------------
class Throttle {
public:
    Throttle() : start_(std::chrono::steady_clock::now()), tick_(0) {}

    void wait_for_tick()
    {
        // Target time for tick_: tick_ * 93.96 ns (half-period at 10.6445 MHz).
        // We advance one rising edge per tick, so period = 93.96 ns.
        ++tick_;
        using ns = std::chrono::nanoseconds;
        auto target = start_ + ns(static_cast<long long>(tick_) * 93960LL / 1000);
        auto now    = std::chrono::steady_clock::now();
        if (now < target)
            std::this_thread::sleep_until(target);
    }

private:
    std::chrono::steady_clock::time_point start_;
    uint64_t tick_;
};

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
int main(int argc, char** argv)
{
    std::string rom_path;
    std::string disk_paths[4];
    bool        disk_wp[4] = {};
    int         scale      = 2;
    bool        throttle   = false;
    int         ei_cfg     = 2;   // 48K by default

    for (int i = 1; i < argc; i++) {
        std::string a(argv[i]);
        std::string v;
        if ((v = arg_value(a, "--rom="))   != "") { rom_path    = v; }
        else if ((v = arg_value(a, "--disk0=")) != "") { disk_paths[0] = v; }
        else if ((v = arg_value(a, "--disk1=")) != "") { disk_paths[1] = v; }
        else if ((v = arg_value(a, "--disk2=")) != "") { disk_paths[2] = v; }
        else if ((v = arg_value(a, "--disk3=")) != "") { disk_paths[3] = v; }
        else if (a == "--wp0") { disk_wp[0] = true; }
        else if (a == "--wp1") { disk_wp[1] = true; }
        else if (a == "--wp2") { disk_wp[2] = true; }
        else if (a == "--wp3") { disk_wp[3] = true; }
        else if ((v = arg_value(a, "--scale=")) != "") { scale = atoi(v.c_str()); }
        else if (a == "--throttle") { throttle = true; }
        else if (a == "--no-ei")   { ei_cfg = 0; }
        else if (a == "--ei16")    { ei_cfg = 1; }
        else if (a == "--ei32")    { ei_cfg = 2; }
        else { fprintf(stderr, "Unknown option: %s\n", a.c_str()); usage(argv[0]); return 1; }
    }

    if (rom_path.empty()) {
        fprintf(stderr, "Error: --rom=<hex> is required\n");
        usage(argv[0]);
        return 1;
    }

    // ---- Load ROM ----
    std::vector<uint8_t> rom;
    if (!load_hex(rom_path, rom)) return 1;
    if (rom.size() < 12288 || rom.size() > 16384) {
        fprintf(stderr, "ROM image: expected 12288–16384 bytes, got %zu\n",
                rom.size());
        return 1;
    }

    // ---- Instantiate models ----
    EmuDisk     disk(disk_paths, disk_wp);
    EmuKeyboard kbd;
    EmuDisplay  disp(scale);

    // ---- Verilator model ----
    VerilatedContext ctx;
    ctx.commandArgs(argc, argv);
    Vm1_core top(&ctx);

    // ---- Reset sequence (hold reset low for 4 clocks, then release) ----
    top.por_rst_n     = 0;
    top.dbg_rst_n     = 0;
    top.reset_btn_n   = 1;
    top.test_n        = 1;
    top.int_n         = 1;
    top.wait_n        = 1;
    top.ld_en         = 0;
    top.ld_addr       = 0;
    top.ld_data       = 0;
    top.ei_ram_cfg    = (uint8_t)ei_cfg;
    top.fdc_disk      = 0;
    top.fdc_wp        = 0;
    top.percom_en     = 1;
    top.trk_vld       = 0;
    top.trk_data      = 0;
    top.trk_idx       = 0;
    top.trk_done      = 0;
    top.trk_err       = 0;
    top.trk_len       = 0;
    top.trk_dbl       = 0;
    top.trk_wb_fetch  = 0;
    top.trk_wb_idx    = 0;
    top.trk_wb_done   = 0;
    top.trk_wb_err    = 0;
    top.keys          = 0;
    top.cass_in       = 0;
    top.dbg_in_valid  = 0;
    top.dbg_in_data   = 0;
    top.dbg_out_ready = 1;
    top.clk = 0; top.eval();

    // ROM load: 4 idle clocks, then stream bytes on negedge (like tb_m1_boot.sv)
    for (int pre = 0; pre < 4; pre++) {
        top.clk = 1; top.eval();
        top.clk = 0; top.eval();
    }
    for (size_t i = 0; i < rom.size(); i++) {
        top.clk = 0; top.eval();  // negedge
        top.ld_en   = 1;
        top.ld_addr = (uint32_t)i;
        top.ld_data = rom[i];
        top.clk = 1; top.eval();  // posedge
    }
    top.clk = 0; top.eval();
    top.ld_en = 0;

    // Release reset
    top.por_rst_n = 1;
    top.dbg_rst_n = 1;

    // Populate disk signals
    top.fdc_disk = disk.fdc_disk;
    top.fdc_wp   = disk.fdc_wp;

    Throttle thr;

    // ---- Main simulation loop ----
    bool running = true;
    while (running && !ctx.gotFinish()) {

        // --- Rising edge ---
        top.clk = 1;
        top.eval();

        // --- Feed disk model inputs (from m1_core outputs) ---
        disk.trk_req        = top.trk_req;
        disk.trk_drv        = top.trk_drv;
        disk.trk_track      = top.trk_track;
        disk.trk_wb_req     = top.trk_wb_req;
        disk.trk_wb_data_in = top.trk_wb_data;   // FDC exposes byte here

        disk.tick();

        // --- Apply disk model outputs back to m1_core ---
        top.trk_vld      = disk.trk_vld;
        top.trk_data     = disk.trk_data;
        top.trk_idx      = disk.trk_idx;
        top.trk_done     = disk.trk_done;
        top.trk_err      = disk.trk_err;
        top.trk_len      = disk.trk_len;
        top.trk_dbl      = disk.trk_dbl;
        top.trk_wb_fetch = disk.trk_wb_fetch;
        top.trk_wb_idx   = disk.trk_wb_idx;
        top.trk_wb_done  = disk.trk_wb_done;
        top.trk_wb_err   = disk.trk_wb_err;

        // --- Update keyboard matrix ---
        top.keys = kbd.keys();

        // --- Capture video dot ---
        disp.write_pixel(top.pixel, (uint8_t)top.col,
                         (uint8_t)top.line, (uint8_t)top.row);

        // --- Falling edge ---
        top.clk = 0;
        top.eval();

        // --- Present frame once per VDRV rising edge (end of vertical blank) ---
        static uint8_t prev_vdrv = 0;
        if (!prev_vdrv && top.vdrv) {
            disp.present();
            running = disp.poll_events(&kbd);
        }
        prev_vdrv = top.vdrv;

        if (throttle)
            thr.wait_for_tick();
    }

    top.final();
    return 0;
}
