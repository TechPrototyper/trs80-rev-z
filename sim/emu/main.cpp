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
//   --no-percom       Percom Doubler absent (default: fitted, like DIP4 OFF
//                     on the board) — some DOS boot paths probe the doubler
//   --kbd=<layout>    Host keyboard layout: us (default) or de. Scancodes
//                     are physical, so this decides which legend a key
//                     produces (de: QWERTZ, ':' on shift+'.', etc.)
//   --type=<text>     Auto-type text into the machine ("\n" = ENTER), e.g.
//                     --type="BASIC\n". Starts after --type-at frames.
//   --type-at=<n>     First frame of auto-typing (default 900, ~15 machine
//                     seconds — past the DOS boot banner)
//   --debug-pty       Expose the m1_debug binary-v0 link on a pseudo-tty.
//                     The slave path is printed at startup; point
//                     tools/trszog_bridge.py --serial at it and the emulator
//                     appears to DeZog exactly like the board on its FTDI
//                     port (ADR-0006/0007; baud rate is meaningless on a pty)
//
// The ROM file must be in Verilog $readmemh format — one hex byte per line,
// no address tags.  trs80gp can dump the ROM; see roms/README.md.
//
// Clock domain:
//   m1_core uses a single 10.6445 MHz dot clock.  Without --throttle the
//   simulation runs as fast as Verilator can manage.  With --throttle it
//   inserts host-clock sleeps to pace the simulation to real time.

#include "Vm1_core.h"
#include "Vm1_core___024root.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include "emu_audio.h"
#include "emu_cass.h"
#include "emu_disk.h"
#include "emu_keyboard.h"
#include "emu_display.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include <fcntl.h>
#include <termios.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <util.h>       // openpty
#else
#include <pty.h>        // openpty (link with -lutil on glibc)
#endif

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

    // Pace factor: 1.0 = real time; below 1 slows the machine to a
    // SUSTAINABLE constant rate. Useful because the model tops out
    // around ~0.75x on current hosts — pinning e.g. 0.6 gives a rock-
    // steady pace (and with it rock-steady audio pitch) instead of a
    // host-load-dependent wander.
    void set_factor(double f)
    {
        if (f < 0.05) f = 0.05;
        if (f > 4.0)  f = 4.0;
        ns_per_tick_ = 93.96 / f;
    }

    void wait_for_tick()
    {
        // Target time for tick_: tick_ * 93.96 ns (period at 10.6445 MHz;
        // one rising edge per tick). Sleeping every tick would issue a
        // syscall per 94 ns of emulated time — macOS sleep granularity is
        // ~1 ms, so that ran far BELOW real time. Instead re-sync once
        // every 16384 ticks (~1.5 ms emulated), which a sleep can
        // actually honor.
        if (((++tick_) & 0x3FFF) != 0)
            return;
        using ns = std::chrono::nanoseconds;
        auto target = start_
            + ns((long long)((double)tick_ * ns_per_tick_));
        auto now    = std::chrono::steady_clock::now();
        if (now < target)
            std::this_thread::sleep_until(target);
        else if (now - target > std::chrono::milliseconds(250))
            start_ = now - ns((long long)((double)tick_ * ns_per_tick_));
            // fell behind (window drag, heavy sim stretch): re-anchor
            // instead of racing to catch up
    }

private:
    std::chrono::steady_clock::time_point start_;
    uint64_t tick_;
    double   ns_per_tick_ = 93.96;
};

// ---------------------------------------------------------------------------
// Auto-typing: feed a scripted key sequence into the matrix, one glyph at a
// time, several frames held per key so the ROM/DOS keyboard poll cannot miss
// it. Deterministic (frame-counted), so scripted runs are reproducible.
// ---------------------------------------------------------------------------
class AutoType {
public:
    void program(const std::string& text, int start_frame)
    {
        if (text.empty()) return;
        steps_.push_back({0, start_frame});
        for (size_t i = 0; i < text.size(); i++) {
            char c = text[i];
            if (c == '\\' && i + 1 < text.size() && text[i+1] == 'n')
                { c = '\n'; i++; }
            else if (c == '\\' && i + 1 < text.size() && text[i+1] == 'w') {
                // "\w": wait ~5 machine seconds (tape loads, overlays)
                steps_.push_back({0, 300});
                i++;
                continue;
            }
            uint64_t m = glyph_mask(c);
            if (!m) continue;                    // no Model 1 equivalent
            steps_.push_back({m, 14});           // held (> 2 DOS scan ticks)
            // After ENTER the DOS reloads SYS overlays from disk and the
            // ROM keyboard poll pauses — give it two machine-seconds
            // before the next glyph, or its first characters are eaten.
            steps_.push_back({0, c == '\n' ? 120 : 10});
        }
    }

    // Advance one frame; returns the matrix contribution for this frame.
    void frame()
    {
        if (steps_.empty()) { cur_ = 0; return; }
        cur_ = steps_.front().first;
        if (--steps_.front().second <= 0)
            steps_.pop_front();
    }

    uint64_t keys() const { return cur_; }

private:
    static uint64_t bit(int row, int col)
        { return uint64_t(1) << (row * 8 + col); }

    // ASCII -> Model 1 chord (matrix layout as in emu_keyboard.h).
    static uint64_t glyph_mask(char c)
    {
        const uint64_t SH = bit(7, 0);
        if (c >= 'a' && c <= 'z') c = (char)(c - 'a' + 'A');
        if (c >= 'A' && c <= 'Z') {
            int n = c - 'A' + 1;                 // @=0, A=1 .. Z=26
            return bit(n >> 3, n & 7);
        }
        if (c >= '1' && c <= '7') return bit(4, c - '0');
        switch (c) {
        case '0':  return bit(4, 0);
        case '8':  return bit(5, 0);
        case '9':  return bit(5, 1);
        case '@':  return bit(0, 0);
        case ':':  return bit(5, 2);
        case ';':  return bit(5, 3);
        case ',':  return bit(5, 4);
        case '-':  return bit(5, 5);
        case '.':  return bit(5, 6);
        case '/':  return bit(5, 7);
        case '!':  return bit(4, 1) | SH;
        case '"':  return bit(4, 2) | SH;
        case '#':  return bit(4, 3) | SH;
        case '$':  return bit(4, 4) | SH;
        case '%':  return bit(4, 5) | SH;
        case '&':  return bit(4, 6) | SH;
        case '\'': return bit(4, 7) | SH;
        case '(':  return bit(5, 0) | SH;
        case ')':  return bit(5, 1) | SH;
        case '*':  return bit(5, 2) | SH;
        case '+':  return bit(5, 3) | SH;
        case '=':  return bit(5, 5) | SH;
        case '<':  return bit(5, 4) | SH;
        case '>':  return bit(5, 6) | SH;
        case '?':  return bit(5, 7) | SH;
        case ' ':  return bit(6, 7);
        case '\n': return bit(6, 0);
        default:   return 0;
        }
    }

    std::deque<std::pair<uint64_t, int>> steps_;
    uint64_t cur_ = 0;
};

// ---------------------------------------------------------------------------
// Debug link on a pseudo-tty: the emulator-side stand-in for the board's
// FTDI serial port. Byte queues are serviced once per frame (a syscall per
// simulated clock would dominate the run time); the per-tick valid/ready
// handshake against m1_core only touches the queues.
// ---------------------------------------------------------------------------
class DebugPty {
public:
    bool open()
    {
        struct termios tio;
        cfmakeraw(&tio);
        tio.c_cflag |= CREAD | CS8;
        int slave = -1;
        char name[128];
        if (openpty(&master_, &slave, name, &tio, nullptr) != 0) {
            perror("openpty");
            return false;
        }
        // The slave stays open on our side so the pty survives bridge
        // restarts (no EIO on the master when no one is attached).
        (void)slave;
        fcntl(master_, F_SETFL, O_NONBLOCK);
        printf("emu_debug: binary-v0 debug link on %s\n", name);
        printf("emu_debug: tools/trszog_bridge.py --serial %s\n", name);
        fflush(stdout);
        return true;
    }

    bool enabled() const { return master_ >= 0; }

    // Called once per frame: move bytes between the pty and the queues.
    void service()
    {
        uint8_t buf[512];
        ssize_t n;
        while ((n = ::read(master_, buf, sizeof buf)) > 0)
            for (ssize_t i = 0; i < n; i++) rx_.push_back(buf[i]);
        while (!tx_.empty()) {
            size_t chunk = 0;
            while (chunk < sizeof buf && chunk < tx_.size())
                { buf[chunk] = tx_[chunk]; chunk++; }
            n = ::write(master_, buf, chunk);
            if (n <= 0) break;                    // EAGAIN: retry next frame
            tx_.erase(tx_.begin(), tx_.begin() + n);
        }
    }

    bool     rx_pending() const { return !rx_.empty(); }
    uint8_t  rx_front()   const { return rx_.front(); }
    void     rx_pop()           { rx_.pop_front(); }
    void     tx_push(uint8_t b) { tx_.push_back(b); }

private:
    int master_ = -1;
    std::deque<uint8_t> rx_, tx_;
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
    double      throttle_factor = 1.0;
    bool        debug_pty  = false;
    bool        percom     = true;
    std::string type_text;
    int         type_at    = 900;
    int         ei_cfg     = 2;   // 48K by default
    std::string pctrace;          // "lo:hi:file" — instruction-fetch PC log
    int         enter_until = 0;  // hold ENTER until this frame (boot skips)
    std::string kbd_layout = "us";
    std::string cas_path;
    std::string cas_save;
    int         cas_baud = 500;
    bool        sound    = true;
    int         volume   = 60;
    std::string sound_dump;
    bool        drive_sounds = true;

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
        else if ((v = arg_value(a, "--throttle=")) != "") {
            throttle = true; throttle_factor = atof(v.c_str());
        }
        else if (a == "--debug-pty") { debug_pty = true; }
        else if (a == "--no-percom") { percom = false; }
        else if ((v = arg_value(a, "--type=")) != "") { type_text = v; }
        else if ((v = arg_value(a, "--type-at=")) != "") { type_at = atoi(v.c_str()); }
        else if ((v = arg_value(a, "--pctrace=")) != "") { pctrace = v; }
        else if ((v = arg_value(a, "--enter-until=")) != "") { enter_until = atoi(v.c_str()); }
        else if ((v = arg_value(a, "--kbd=")) != "") { kbd_layout = v; }
        else if ((v = arg_value(a, "--cas=")) != "") { cas_path = v; }
        else if ((v = arg_value(a, "--cas-baud=")) != "") { cas_baud = atoi(v.c_str()); }
        else if ((v = arg_value(a, "--cas-save=")) != "") { cas_save = v; }
        else if (a == "--no-sound") { sound = false; }
        else if ((v = arg_value(a, "--volume=")) != "") { volume = atoi(v.c_str()); }
        else if ((v = arg_value(a, "--sound-dump=")) != "") { sound_dump = v; }
        else if (a == "--no-drive-sounds") { drive_sounds = false; }
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
    EmuCassette cass;
    if (!cas_path.empty() && !cass.load(cas_path, cas_baud))
        return 1;
    if (!cas_save.empty())
        cass.record_to(cas_save);
    EmuAudio audio;
    if (sound)
        sound = audio.init(volume);
    if (sound && !sound_dump.empty())
        audio.dump_to(sound_dump);
    audio.set_drive_sounds(drive_sounds);
    EmuKeyboard kbd;
    if (kbd_layout == "de") {
        kbd.set_layout(EmuKeyboard::Layout::DE);
    } else if (kbd_layout != "us") {
        fprintf(stderr, "--kbd: unknown layout '%s' (us, de)\n",
                kbd_layout.c_str());
        return 1;
    }
    EmuDisplay  disp(scale);
    DebugPty    dbg;
    if (debug_pty && !dbg.open()) return 1;
    AutoType    autotype;
    autotype.program(type_text, type_at);

    // ---- Verilator model ----
    VerilatedContext ctx;
    ctx.commandArgs(argc, argv);
    Vm1_core top(&ctx);

    // ---- PC trace (instruction-fetch log, "lo:hi:file") ----
    FILE*    pct_f  = nullptr;
    unsigned pct_lo = 0, pct_hi = 0xFFFF;
    if (!pctrace.empty()) {
        size_t c1 = pctrace.find(':'), c2 = pctrace.find(':', c1 + 1);
        if (c1 == std::string::npos || c2 == std::string::npos) {
            fprintf(stderr, "--pctrace expects lo:hi:file (hex bounds)\n");
            return 1;
        }
        pct_lo = strtoul(pctrace.substr(0, c1).c_str(), nullptr, 16);
        pct_hi = strtoul(pctrace.substr(c1 + 1, c2 - c1 - 1).c_str(), nullptr, 16);
        pct_f  = fopen(pctrace.substr(c2 + 1).c_str(), "w");
        if (!pct_f) { perror("--pctrace file"); return 1; }
    }

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
    top.percom_en     = percom ? 1 : 0;
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
    thr.set_factor(throttle_factor);

    // ---- Main simulation loop ----
    bool running = true;
    uint64_t framecnt = 0;
    while (running && !ctx.gotFinish()) {

        // --- Debug link: sample the handshake pre-edge (clk still 0 and
        // combinationally settled) — a valid/ready pair seen here transfers
        // at the rising edge below, same contract as tb_m1_debug's host ---
        bool    dbg_in_fire = false, dbg_out_fire = false;
        uint8_t dbg_out_byte = 0;
        if (dbg.enabled()) {
            dbg_in_fire  = top.dbg_in_valid && top.dbg_in_ready;
            dbg_out_fire = top.dbg_out_valid && top.dbg_out_ready;
            dbg_out_byte = top.dbg_out_data;
        }

        // --- Rising edge ---
        top.clk = 1;
        top.eval();

        // --- Debug link: complete transfers, present the next byte ---
        if (dbg.enabled()) {
            if (dbg_in_fire)  dbg.rx_pop();
            if (dbg_out_fire) dbg.tx_push(dbg_out_byte);
            top.dbg_in_valid = dbg.rx_pending() ? 1 : 0;
            top.dbg_in_data  = dbg.rx_pending() ? dbg.rx_front() : 0;
        }

        // --- PC trace: log each instruction fetch (M1/T1 rising edge).
        // tv80 one-hot cycle state: mcycle[0] = M1, tstate[1] = T1; PC
        // still holds the fetch address at that moment. ---
        if (pct_f) {
            static bool prev_m1t1 = false;
            bool m1t1 =
                (top.rootp->m1_core__DOT__u_cpu__DOT__z40__DOT__mcycle & 1) &&
                (top.rootp->m1_core__DOT__u_cpu__DOT__z40__DOT__tstate & 2);
            if (m1t1 && !prev_m1t1) {
                unsigned pc =
                    top.rootp->m1_core__DOT__u_cpu__DOT__z40__DOT__PC;
                if (pc >= pct_lo && pc <= pct_hi)
                    fprintf(pct_f, "@%04x\n", pc);
            }
            prev_m1t1 = m1t1;
        }

        // --- Feed disk model inputs (from m1_core outputs) ---
        disk.trk_req        = top.trk_req;
        disk.trk_drv        = top.trk_drv;
        disk.trk_track      = top.trk_track;
        disk.trk_side       = top.trk_side;
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

        // --- Cassette deck: motor-gated tape into cass_in ---
        cass.motor      = top.cass_motor;
        cass.out_ladder = top.cass_out;
        cass.tick();
        top.cass_in = cass.out;

        // --- Sound: the ladder (program) + the drive-event stream ---
        if (sound)
            audio.tick(top.cass_out, top.snd, disk.fdc_disk);

        // --- Update keyboard matrix (live keyboard + scripted input) ---
        top.keys = kbd.keys() | autotype.keys();
        top.reset_btn_n = kbd.reset_pressed() ? 0 : 1;   // F12 = RESET button
        if (framecnt < (uint64_t)enter_until)
            top.keys |= uint64_t(1) << (6 * 8 + 0);   // hold ENTER (row 6 bit 0)

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
            autotype.frame();
            if ((++framecnt % 60) == 0)
                disp.set_frame(framecnt);
            // pace report: emulated frames vs wall clock, every ~5 s
            {
                static auto   t0 = std::chrono::steady_clock::now();
                static auto   tl = t0;
                static uint64_t fl = 0;
                auto nowt = std::chrono::steady_clock::now();
                double dt = std::chrono::duration<double>(nowt - tl).count();
                if (dt >= 5.0) {
                    double fps = (double)(framecnt - fl) / dt;
                    fprintf(stderr, "emu: %.1f fps (%.2fx realtime)\n",
                            fps, fps / 60.0);
                    fflush(stderr);
                    tl = nowt;
                    fl = framecnt;
                }
            }
            if (dbg.enabled())
                dbg.service();
        }
        prev_vdrv = top.vdrv;

        if (throttle)
            thr.wait_for_tick();
    }

    if (pct_f) fclose(pct_f);
    top.final();
    return 0;
}
