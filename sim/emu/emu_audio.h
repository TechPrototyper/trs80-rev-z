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
// Volume applies to the PROGRAM sound only; the drive sounds keep a
// fixed, period-correct loudness relative to it (M7 stage 2): four
// synthesized voices driven by the m1_drives event stream — motor
// spin-up/run/run-out per drive with a small per-drive detune (real
// drives never sounded identical), and a step click per head pulse.
// All drives with a disk spin together, exactly like the shared motor
// line of the real cable.

#pragma once
#include <cstdint>
#include <string>
#include <vector>

class EmuAudio {
public:
    // volume 0..100; returns false if SDL audio is unavailable (the
    // emulator then simply runs silent).
    bool init(int volume_percent);
    ~EmuAudio();

    bool enabled() const { return dev_ != 0; }

    // Mirror everything the speaker gets into a 44.1 kHz mono WAV.
    bool dump_to(const std::string& path);

    // Call once per rising dot-clock edge. ladder = m1_core.cass_out;
    // snd = m1_core.snd {DS latch[3:0], motor, step, dirc};
    // disks = media-present mask (drive sounds need a disk to spin).
    void tick(uint8_t ladder, uint8_t snd, uint8_t disks);

    void set_drive_sounds(bool on) { drives_on_ = on; }

    // Load real recordings from a directory (WAV, mono/stereo, 16-bit,
    // any rate): "seek_step_trs80.wav"/"step.wav" for the arm,
    // "motor_trs80.wav"/"motor_loop.wav" as the spindle loop. Missing
    // files fall back to the synthesized voice; without the option the
    // engine is fully procedural (the repo ships no audio assets).
    void load_drive_samples(const std::string& dir);

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

    // drive-sound voices
    bool     drives_on_ = true;
    float    menv_[4]   = {0, 0, 0, 0};    // motor envelope per drive
    float    hum_ph_[4] = {0, 0, 0, 0};
    float    rumble_[4] = {0, 0, 0, 0};    // low-passed noise state
    bool     step_pend_[4] = {false, false, false, false};
    uint32_t rng_ = 0x2626C3A5;

    // sample players (loaded voices; -1 position = idle)
    struct Samp { std::vector<float> d; float inc = 1.0f; };
    Samp     smp_step_, smp_motor_;
    float    sp_pos_[4] = {-1, -1, -1, -1};
    float    sp_amp_[4] = {0, 0, 0, 0};
    float    mp_pos_[4] = {0, 0, 0, 0};

    static bool load_wav_mono(const std::string& path, Samp& out);

    // step "clack": three struck-metal modes + a short sheet-metal
    // case comb (the drive lived in a metal box — the arm's knock has
    // a boxy ring, not a hiss)
    float    ck_env_[3] = {0, 0, 0};
    float    ck_ph_[3]  = {0, 0, 0};
    float    ck_det_    = 1.0f;            // per-hit color (drive detune)
    static constexpr int COMB = 512;       // ~11.6 ms at 44.1 kHz
    float    comb_[COMB] = {};
    int      comb_i_ = 0;
    bool     comb_live_ = false;

    float drive_mix();

    float  x_prev_ = 0.0f;                 // DC-blocker state
    float  y_prev_ = 0.0f;

    float  buf_[512];
    int    buf_n_ = 0;
    uint64_t since_adjust_  = 0;
    uint64_t total_samples_ = 0;

    static float level(uint8_t ladder);
    void   push(float s);
};
