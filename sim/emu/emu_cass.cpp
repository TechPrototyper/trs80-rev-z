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

    // recorder: positive ladder spikes while the motor runs
    if (!save_path_.empty()) {
        if (motor && out_ladder == 3 && ladder_d_ != 3)
            wr_pulses_.push_back(pos_us_);
        ladder_d_ = out_ladder;
        if (!motor && motor_d_ && wr_pulses_.size() > 16)
            flush_recording();             // one save = motor-on stretch
        motor_d_ = motor;
    }
}

void EmuCassette::flush_recording()
{
    // pulse gaps -> bits (the golden-pinned 500-baud rule: a pulse
    // < 1.5 ms after a clock is a data '1')
    std::vector<int> bits;
    for (size_t i = 0; i + 1 < wr_pulses_.size();) {
        if (wr_pulses_[i + 1] - wr_pulses_[i] < 1500) {
            bits.push_back(1);
            i += 2;
        } else {
            bits.push_back(0);
            i += 1;
        }
    }
    for (int k = 0; k < 16; k++) bits.push_back(0);   // final byte pad

    std::vector<uint8_t> bytes;
    for (size_t k = 0; k + 8 <= bits.size(); k += 8) {
        uint8_t b = 0;
        for (int j = 0; j < 8; j++)
            b = (uint8_t)((b << 1) | bits[k + j]);
        bytes.push_back(b);
    }

    std::string path = save_path_;
    if (saves_ > 0) {                      // second save: -1, -2, ...
        size_t dot = path.rfind('.');
        char tag[8];
        snprintf(tag, sizeof tag, "-%d", saves_);
        path = (dot == std::string::npos)
               ? path + tag
               : path.substr(0, dot) + tag + path.substr(dot);
    }

    size_t dot = path.rfind('.');
    std::string ext = (dot == std::string::npos) ? "" : path.substr(dot);
    for (auto& c : ext) c = (char)tolower(c);

    FILE* f = fopen(path.c_str(), "wb");
    if (!f) { fprintf(stderr, "emu_cass: cannot write %s\n", path.c_str()); }
    else if (ext == ".wav") {
        // 44100 Hz mono 8-bit: a +/- spike per pulse, center elsewhere
        const uint32_t rate = 44100;
        uint64_t dur = wr_pulses_.back() + 5000;
        uint32_t nsamp = (uint32_t)(dur * rate / 1000000ULL);
        std::vector<uint8_t> pcm(nsamp, 128);
        for (uint64_t t : wr_pulses_) {
            uint32_t s0 = (uint32_t)(t * rate / 1000000ULL);
            for (uint32_t k = 0; k < rate / 10000 && s0 + k < nsamp; k++)
                pcm[s0 + k] = 240;                     // ~100 us positive
            for (uint32_t k = rate / 10000;
                 k < rate / 5000 && s0 + k < nsamp; k++)
                pcm[s0 + k] = 16;                      // ~100 us negative
        }
        uint32_t dlen = nsamp, flen = 36 + dlen;
        uint8_t hdr[44] = {'R','I','F','F',0,0,0,0,'W','A','V','E',
                           'f','m','t',' ',16,0,0,0, 1,0, 1,0,
                           0,0,0,0, 0,0,0,0, 1,0, 8,0,
                           'd','a','t','a',0,0,0,0};
        memcpy(hdr + 4,  &flen, 4);
        memcpy(hdr + 24, &rate, 4);
        memcpy(hdr + 28, &rate, 4);
        memcpy(hdr + 40, &dlen, 4);
        fwrite(hdr, 1, 44, f);
        fwrite(pcm.data(), 1, pcm.size(), f);
        fclose(f);
    } else {
        fwrite(bytes.data(), 1, bytes.size(), f);
        fclose(f);
    }
    if (f)
        fprintf(stderr,
                "emu_cass: saved %zu pulses -> %zu bytes -> %s\n",
                wr_pulses_.size(), bytes.size(), path.c_str());
    saves_++;
    wr_pulses_.clear();
}
