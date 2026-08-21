// TRS-80 Rev Z — emulator program sound (M7 stage 1)
//
// The Model 1 has no sound chip: games sing through the cassette
// output ladder (port 0xFF D1:D0 -> R53-R56), normally into a tape
// recorder's monitor speaker or a small amp. This module is that amp:
// it samples the ladder on the emulated 1 MHz grid, DC-blocks it (the
// speaker never heard the standing level, only the swings) and queues
// it to SDL at 44.1 kHz.
//
// Pacing is honest: the sample period adapts so the queue stays level
// with the wall clock. When the simulation runs below real time the
// pitch drops by exactly the same factor — the machine you hear is the
// machine you see, never a resampled idealization of it.
//
// Volume applies to the PROGRAM sound only; the drive sounds that
// arrive with M7 stage 2 keep their fixed, period-correct loudness
// relative to it.

#pragma once
#include <cstdint>
#include <string>

class EmuAudio {
public:
    // volume 0..100; returns false if SDL audio is unavailable (the
    // emulator then simply runs silent).
    bool init(int volume_percent);
    ~EmuAudio();

    bool enabled() const { return dev_ != 0; }

    // Mirror everything the speaker gets into a 44.1 kHz mono WAV.
    bool dump_to(const std::string& path);

    // Call once per rising dot-clock edge with the ladder level
    // (m1_core.cass_out).
    void tick(uint8_t ladder);

private:
    uint32_t dev_ = 0;
    float    vol_ = 0.6f;

    uint32_t acc_ = 0;                     // 1 MHz phase accumulator
    static constexpr uint32_t ACC_K = 1576139;   // 2^24 / 10.6445

    float  period_us_  = 1000000.0f / 44100.0f;
    float  sample_acc_ = 0.0f;

    // feed-forward pace tracking (see .cpp): emulated-us per wall-us,
    // smoothed; the queue only takes bursts and a slow centering trim
    uint64_t emu_us_    = 0;
    uint64_t last_wall_ = 0;               // SDL performance counter
    uint64_t last_emu_  = 0;
    float    pace_      = 1.0f;
    float    trim_      = 1.0f;
    bool     trim_on_   = false;

    FILE*    dump_   = nullptr;
    uint32_t dump_n_ = 0;

    float  x_prev_ = 0.0f;                 // DC-blocker state
    float  y_prev_ = 0.0f;

    float  buf_[512];
    int    buf_n_ = 0;
    uint64_t since_adjust_  = 0;
    uint64_t total_samples_ = 0;

    static float level(uint8_t ladder);
    void   push(float s);
};
