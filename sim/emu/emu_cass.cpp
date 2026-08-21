// TRS-80 Rev Z — emulator cassette deck implementation (see emu_cass.h)

#include "emu_cass.h"

#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstring>

bool EmuCassette::load(const std::string& path, int baud)
{
    size_t dot = path.rfind('.');
    std::string ext = (dot == std::string::npos) ? "" : path.substr(dot);
    for (auto& c : ext) c = (char)tolower(c);

    bool ok = (ext == ".wav") ? load_wav(path) : load_cas(path, baud);
    if (ok)
        fprintf(stderr,
                "emu_cass: %s mounted, %zu pulses, %.1f s of tape\n",
                path.c_str(), pulses_.size(),
                pulses_.empty() ? 0.0 : (double)pulses_.back() / 1e6);
    return ok;
}

bool EmuCassette::load_cas(const std::string& path, int baud)
{
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) { fprintf(stderr, "emu_cass: cannot open %s\n", path.c_str());
              return false; }
    std::vector<uint8_t> data;
    uint8_t buf[4096];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0)
        data.insert(data.end(), buf, buf + n);
    fclose(f);

    const uint64_t bit_us  = 1000000ULL / (uint64_t)baud;   // 2000 at 500 Bd
    const uint64_t data_off = bit_us / 2;
    uint64_t t = 20000;                                     // spin-up gap
    for (uint8_t b : data)
        for (int i = 7; i >= 0; i--) {
            pulses_.push_back(t);                           // clock pulse
            if ((b >> i) & 1)
                pulses_.push_back(t + data_off);            // data pulse
            t += bit_us;
        }
    return true;
}

bool EmuCassette::load_wav(const std::string& path)
{
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) { fprintf(stderr, "emu_cass: cannot open %s\n", path.c_str());
              return false; }
    std::vector<uint8_t> d;
    uint8_t buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0)
        d.insert(d.end(), buf, buf + n);
    fclose(f);

    auto u32 = [&](size_t o) { return (uint32_t)d[o] | (uint32_t)d[o+1] << 8
                                    | (uint32_t)d[o+2] << 16
                                    | (uint32_t)d[o+3] << 24; };
    auto u16 = [&](size_t o) { return (uint32_t)d[o] | (uint32_t)d[o+1] << 8; };

    if (d.size() < 44 || memcmp(d.data(), "RIFF", 4)
        || memcmp(d.data() + 8, "WAVE", 4)) {
        fprintf(stderr, "emu_cass: %s is not a WAV file\n", path.c_str());
        return false;
    }

    // walk the chunks for fmt + data
    uint32_t rate = 0, channels = 1, bits = 8;
    size_t   doff = 0, dlen = 0;
    for (size_t o = 12; o + 8 <= d.size();) {
        uint32_t len = u32(o + 4);
        if (!memcmp(&d[o], "fmt ", 4)) {
            channels = u16(o + 10);
            rate     = u32(o + 12);
            bits     = u16(o + 22);
        } else if (!memcmp(&d[o], "data", 4)) {
            doff = o + 8;
            dlen = len;
        }
        o += 8 + len + (len & 1);
    }
    if (!rate || !doff) {
        fprintf(stderr, "emu_cass: %s: no fmt/data chunk\n", path.c_str());
        return false;
    }

    // first channel, normalized to signed
    size_t bytes_per = (bits / 8) * channels;
    size_t count = dlen / bytes_per;
    auto sample = [&](size_t i) -> double {
        size_t o = doff + i * bytes_per;
        if (bits == 8)  return ((int)d[o] - 128) / 128.0;
        int16_t v = (int16_t)(d[o] | d[o + 1] << 8);
        return v / 32768.0;
    };

    // Z4 model: peak-relative threshold with hysteresis + refractory.
    double peak = 0;
    for (size_t i = 0; i < count; i++)
        peak = fmax(peak, fabs(sample(i)));
    if (peak < 0.01) {
        fprintf(stderr, "emu_cass: %s: silent tape\n", path.c_str());
        return false;
    }
    const double thr_hi = 0.40 * peak, thr_lo = 0.10 * peak;
    const uint64_t refractory = 250;      // us: inside one pulse envelope
    bool     armed = true;
    uint64_t last  = 0;
    bool     first = true;
    for (size_t i = 0; i < count; i++) {
        double v = sample(i);
        uint64_t t = (uint64_t)((double)i * 1e6 / rate);
        if (armed && v > thr_hi
            && (first || t - last >= refractory)) {
            pulses_.push_back(t + 20000);   // keep the spin-up gap idiom
            last  = t;
            first = false;
            armed = false;
        } else if (!armed && v < thr_lo) {
            armed = true;
        }
    }
    return true;
}

void EmuCassette::tick()
{
    uint32_t a = acc_ + ACC_K;
    acc_ = a & 0xFFFFFF;
    if (!(a >> 24))
        return;                            // not a 1 MHz tick

    if (motor) {
        pos_us_++;
        if (next_ < pulses_.size() && pos_us_ >= pulses_[next_]) {
            high_us_ = PULSE_US;
            next_++;
        } else if (high_us_ > 0)
            high_us_--;
    } else if (high_us_ > 0)
        high_us_--;
    out = (high_us_ > 0) ? 1 : 0;
}
