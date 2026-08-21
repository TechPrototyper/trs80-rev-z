// TRS-80 Rev Z — emulator program sound implementation (see emu_audio.h)

#include "emu_audio.h"

#include <SDL.h>
#include <cstdio>
#include <cstring>
#include <cmath>
#include <cstdlib>

bool EmuAudio::init(int volume_percent)
{
    if (volume_percent < 0)   volume_percent = 0;
    if (volume_percent > 100) volume_percent = 100;
    vol_ = (float)volume_percent / 100.0f;

    if (SDL_InitSubSystem(SDL_INIT_AUDIO) != 0) {
        fprintf(stderr, "emu_audio: SDL audio unavailable (%s)\n",
                SDL_GetError());
        return false;
    }
    SDL_AudioSpec want{}, have{};
    want.freq     = 44100;
    want.format   = AUDIO_F32SYS;
    want.channels = 1;
    want.samples  = 1024;
    want.callback = nullptr;               // queue mode
    dev_ = SDL_OpenAudioDevice(nullptr, 0, &want, &have, 0);
    if (!dev_) {
        fprintf(stderr, "emu_audio: cannot open device (%s)\n",
                SDL_GetError());
        return false;
    }
    SDL_PauseAudioDevice(dev_, 0);
    fprintf(stderr, "emu_audio: program sound on, volume %d%%\n",
            volume_percent);
    return true;
}

EmuAudio::~EmuAudio()
{
    if (dev_)
        SDL_CloseAudioDevice(dev_);
    if (dump_) {
        uint32_t dlen = dump_n_ * 2, flen = 36 + dlen, rate = 44100,
                 brate = rate * 2;
        uint8_t hdr[44] = {'R','I','F','F',0,0,0,0,'W','A','V','E',
                           'f','m','t',' ',16,0,0,0, 1,0, 1,0,
                           0,0,0,0, 0,0,0,0, 2,0, 16,0,
                           'd','a','t','a',0,0,0,0};
        memcpy(hdr + 4,  &flen, 4);
        memcpy(hdr + 24, &rate, 4);
        memcpy(hdr + 28, &brate, 4);
        memcpy(hdr + 40, &dlen, 4);
        fseek(dump_, 0, SEEK_SET);
        fwrite(hdr, 1, 44, dump_);
        fclose(dump_);
        fprintf(stderr, "emu_audio: dumped %u samples\n", dump_n_);
    }
}

// Ladder levels {~Q1, Q0}: OUT value 0 -> 2 (center), 1 -> 3 (high),
// 2 -> 0 (low); the unused fourth code sits at center too.
float EmuAudio::level(uint8_t ladder)
{
    switch (ladder & 3) {
    case 3:  return 1.0f;                  // high
    case 0:  return -1.0f;                 // low
    default: return 0.0f;                  // center
    }
}

void EmuAudio::push(float s)
{
    buf_[buf_n_++] = s;
    if (buf_n_ == (int)(sizeof buf_ / sizeof buf_[0])) {
        SDL_QueueAudio(dev_, buf_, (Uint32)sizeof buf_);
        if (dump_) {
            for (int i = 0; i < buf_n_; i++) {
                float v = buf_[i];
                if (v > 1.0f)  v = 1.0f;
                if (v < -1.0f) v = -1.0f;
                int16_t q = (int16_t)(v * 32000.0f);
                fwrite(&q, 2, 1, dump_);
            }
            dump_n_ += (uint32_t)buf_n_;
        }
        buf_n_ = 0;
    }
}

// --sound-dump: everything the speaker gets, as a 44.1 kHz WAV — for
// listening or measuring without a remote-desktop audio path in the
// way. Header is finalized in the destructor.
bool EmuAudio::dump_to(const std::string& path)
{
    dump_ = fopen(path.c_str(), "wb");
    if (!dump_) {
        fprintf(stderr, "emu_audio: cannot write %s\n", path.c_str());
        return false;
    }
    uint8_t hdr[44] = {0};
    fwrite(hdr, 1, 44, dump_);          // placeholder
    return true;
}

bool EmuAudio::load_wav_mono(const std::string& path, Samp& out)
{
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) return false;
    std::vector<uint8_t> d;
    uint8_t buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0)
        d.insert(d.end(), buf, buf + n);
    fclose(f);
    if (d.size() < 44 || memcmp(d.data(), "RIFF", 4)
        || memcmp(d.data() + 8, "WAVE", 4))
        return false;
    auto u32 = [&](size_t o) { return (uint32_t)d[o] | (uint32_t)d[o+1] << 8
                                    | (uint32_t)d[o+2] << 16
                                    | (uint32_t)d[o+3] << 24; };
    auto u16 = [&](size_t o) { return (uint32_t)d[o] | (uint32_t)d[o+1] << 8; };
    uint32_t rate = 0, ch = 1, bits = 16;
    size_t doff = 0, dlen = 0;
    for (size_t o = 12; o + 8 <= d.size();) {
        uint32_t len = u32(o + 4);
        if (!memcmp(&d[o], "fmt ", 4)) {
            ch = u16(o + 10); rate = u32(o + 12); bits = u16(o + 22);
        } else if (!memcmp(&d[o], "data", 4)) {
            doff = o + 8; dlen = len;
        }
        o += 8 + len + (len & 1);
    }
    if (!rate || !doff || bits != 16) return false;
    size_t bytes_per = 2 * ch, count = dlen / bytes_per;
    out.d.clear();
    out.d.reserve(count);
    for (size_t i = 0; i < count; i++) {
        size_t o = doff + i * bytes_per;
        int16_t v = (int16_t)(d[o] | d[o + 1] << 8);
        out.d.push_back((float)v / 32768.0f);
    }
    out.inc = (float)rate / 44100.0f;
    return !out.d.empty();
}

void EmuAudio::load_drive_samples(const std::string& dir)
{
    static const char* step_names[]  = {"seek_step_trs80.wav", "step.wav"};
    static const char* motor_names[] = {"motor_trs80.wav",
                                        "motor_loop.wav"};
    for (auto* nm : step_names)
        if (smp_step_.d.empty())
            load_wav_mono(dir + "/" + nm, smp_step_);
    for (auto* nm : motor_names)
        if (smp_motor_.d.empty())
            load_wav_mono(dir + "/" + nm, smp_motor_);
    fprintf(stderr,
            "emu_audio: drive samples from %s — step %s, motor %s\n",
            dir.c_str(),
            smp_step_.d.empty()  ? "SYNTH" : "loaded",
            smp_motor_.d.empty() ? "SYNTH" : "loaded");
}

static inline float samp_at(const std::vector<float>& v, float pos)
{
    size_t i = (size_t)pos;
    if (i + 1 >= v.size()) return v.back();
    float fr = pos - (float)i;
    return v[i] + fr * (v[i + 1] - v[i]);
}

// One drive-sound sample: motor voices for every spinning drive plus
// the step click of the selected one. Fixed loudness by design.
float EmuAudio::drive_mix()
{
    static const float detune[4] = {1.000f, 0.972f, 1.031f, 0.988f};
    float out = 0.0f;
    for (int d = 0; d < 4; d++) {
        // white noise (xorshift) for the motor rumble
        rng_ ^= rng_ << 13; rng_ ^= rng_ >> 17; rng_ ^= rng_ << 5;
        float noise = (float)(int32_t)rng_ * (1.0f / 2147483648.0f);

        if (menv_[d] > 0.001f) {
            // run-out drops the pitch with the envelope — the spindle
            // audibly winds down after the 3 s motor one-shot expires
            float pitch = detune[d] * (0.55f + 0.45f * menv_[d]);
            if (!smp_motor_.d.empty()) {
                out += samp_at(smp_motor_.d, mp_pos_[d]) * menv_[d]
                       * 0.9f;
                mp_pos_[d] += smp_motor_.inc * pitch;
                if (mp_pos_[d] >= (float)smp_motor_.d.size() - 2.0f)
                    mp_pos_[d] = 0.0f;
            } else {
                hum_ph_[d] += 2.0f * (float)M_PI * 96.0f * pitch
                              / 44100.0f;
                if (hum_ph_[d] > 2.0f * (float)M_PI)
                    hum_ph_[d] -= 2.0f * (float)M_PI;
                rumble_[d] += 0.035f * pitch * (noise - rumble_[d]);
                out += (0.55f * rumble_[d] + 0.20f * sinf(hum_ph_[d]))
                       * menv_[d];
            }
        }

        // step voice from a real recording: per-drive player, slight
        // pitch color from the detune, amplitude jitter per hit
        if (!smp_step_.d.empty() && sp_pos_[d] >= 0.0f) {
            out += samp_at(smp_step_.d, sp_pos_[d]) * sp_amp_[d] * 1.4f;
            sp_pos_[d] += smp_step_.inc * detune[d];
            if (sp_pos_[d] >= (float)smp_step_.d.size() - 2.0f)
                sp_pos_[d] = -1.0f;
        }
    }

    // The arm's step: a KNOCK, not a hiss — three damped struck-metal
    // modes (body 620 Hz, metallic 1.9 kHz, a faint 3.4 kHz zing) fed
    // through a short feedback comb: the drive's sheet-metal case
    // ringing for a few reflections.
    static const float f0[3]  = {620.0f, 1900.0f, 3400.0f};
    static const float dk[3]  = {0.99811f, 0.99622f, 0.99434f};
    static const float amp[3] = {0.55f, 0.30f, 0.12f};
    float knock = 0.0f;
    bool  ring  = false;
    for (int m = 0; m < 3; m++) {
        if (ck_env_[m] > 0.0005f) {
            ring = true;
            ck_ph_[m] += 2.0f * (float)M_PI * f0[m] * ck_det_ / 44100.0f;
            if (ck_ph_[m] > 2.0f * (float)M_PI)
                ck_ph_[m] -= 2.0f * (float)M_PI;
            knock += amp[m] * ck_env_[m] * sinf(ck_ph_[m]);
            ck_env_[m] *= dk[m];
        }
    }
    if (ring || comb_live_) {
        float echo = comb_[comb_i_];
        float o    = knock + 0.34f * echo;
        comb_[comb_i_] = o;
        comb_i_ = (comb_i_ + 1) % COMB;
        out += o * 1.1f;
        comb_live_ = (echo > 0.0004f || echo < -0.0004f || ring);
    }
    return out;
}

void EmuAudio::tick(uint8_t ladder, uint8_t snd, uint8_t disks)
{
    // step pulses last one dot clock — latch them before the 1 MHz gate
    if (drives_on_ && (snd & 0x02)) {
        uint8_t sel = (snd >> 3) & 0xF;
        int d = (sel & 1) ? 0 : (sel & 2) ? 1 : (sel & 4) ? 2 : 3;
        if (sel)
            step_pend_[d] = true;
    }

    uint32_t a = acc_ + ACC_K;
    acc_ = a & 0xFFFFFF;
    if (!(a >> 24))
        return;                            // not a 1 MHz tick
    emu_us_++;

    sample_acc_ += 1.0f;
    if (sample_acc_ < period_us_)
        return;
    sample_acc_ -= period_us_;

    // motor envelopes: ~0.35 s spin-up, ~0.9 s run-out; every drive
    // with a disk hangs on the one shared motor line
    bool motor = (snd & 0x04) != 0;
    for (int d = 0; d < 4; d++) {
        if (drives_on_ && motor && (disks & (1 << d))) {
            menv_[d] += 6.5e-5f * (1.2f - menv_[d]);   // ~0.35 s spin-up
            if (menv_[d] > 1.0f) menv_[d] = 1.0f;
        } else {
            menv_[d] -= 2.5e-5f;           // ~0.9 s run-out
            if (menv_[d] < 0.0f) menv_[d] = 0.0f;
        }
        if (step_pend_[d]) {
            step_pend_[d] = false;
            // strike: hard attack (phase reset), slight per-hit and
            // per-drive variation so a seek rattles alive
            rng_ ^= rng_ << 13; rng_ ^= rng_ >> 17; rng_ ^= rng_ << 5;
            float v = 0.85f + 0.15f * ((float)(rng_ & 0xFFFF) / 65536.0f);
            static const float detune[4] = {1.000f, 0.972f, 1.031f,
                                            0.988f};
            if (!smp_step_.d.empty()) {
                sp_pos_[d] = 0.0f;         // real recording: retrigger
                sp_amp_[d] = v;
            } else {
                ck_det_ = detune[d];
                for (int m = 0; m < 3; m++) {
                    ck_env_[m] = v;
                    ck_ph_[m]  = 0.0f;
                }
            }
        }
    }

    // DC-blocking one-pole high-pass (fc ~ 20 Hz at 44.1 kHz)
    float x = level(ladder);
    float y = 0.997f * (y_prev_ + x - x_prev_);
    x_prev_ = x;
    y_prev_ = y;
    // fade in over the first second — the controller converges muted
    float fade = (total_samples_ < 44100)
                 ? (float)total_samples_ / 44100.0f : 1.0f;
    total_samples_++;
    float mix = y * vol_ + (drives_on_ ? drive_mix() * 0.30f : 0.0f);
    if (mix > 1.0f)  mix = 1.0f;
    if (mix < -1.0f) mix = -1.0f;
    push(mix * fade * fade);

    // Pitch comes from a MEASUREMENT, not a queue controller: every
    // ~1/8 wall second the emulated-vs-wall pace is sampled and folded
    // into a slow EMA; the sample period is pace * (1e6/44100). The
    // queue only absorbs the bursty production (the sim sprints
    // between frame presents) plus a slow trim that keeps it centered
    // — its corrections are far below audibility. A queue-driven
    // controller here turns burst noise straight into pitch (first a
    // Doppler wow, then a full siren — both heard live, 2026-08-21).
    if (++since_adjust_ >= 512) {
        since_adjust_ = 0;
        uint64_t now = SDL_GetPerformanceCounter();
        double   f   = (double)SDL_GetPerformanceFrequency();
        if (last_wall_ == 0) {
            last_wall_ = now;
            last_emu_  = emu_us_;
        } else if ((double)(now - last_wall_) >= f / 8.0) {
            double wall_us = (double)(now - last_wall_) * 1e6 / f;
            double emul_us = (double)(emu_us_ - last_emu_);
            float  inst    = (float)(emul_us / wall_us);
            if (inst > 0.05f && inst < 4.0f)
                pace_ += 0.15f * (inst - pace_);
            last_wall_ = now;
            last_emu_  = emu_us_;

            // Trim with hysteresis: engage outside +/-40% of target,
            // release inside +/-15%, and move at 0.4 per-mille per
            // 1/8 s (~0.3%/s) — an order below audibility. The queue
            // is allowed to breathe; only a sustained drift is chased.
            float queued = (float)(SDL_GetQueuedAudioSize(dev_)
                                   / sizeof(float));
            const float target = 8192.0f;
            if (!trim_on_) {
                if (queued > target * 1.4f || queued < target * 0.6f)
                    trim_on_ = true;
            } else if (queued < target * 1.15f
                       && queued > target * 0.85f)
                trim_on_ = false;
            if (trim_on_) {
                if (queued > target) trim_ *= 1.0004f;
                else                 trim_ *= 0.9996f;
            }
            if (trim_ < 0.85f) trim_ = 0.85f;
            if (trim_ > 1.20f) trim_ = 1.20f;

            period_us_ = pace_ * trim_ * (1000000.0f / 44100.0f);
            if (period_us_ < 8.0f)  period_us_ = 8.0f;
            if (period_us_ > 60.0f) period_us_ = 60.0f;
            if (getenv("EMU_AUDIO_LOG")) {
                fprintf(stderr,
                        "emu_audio: pace %.3f trim %.3f queue %.0f "
                        "period %.2f us\n",
                        (double)pace_, (double)trim_, (double)queued,
                        (double)period_us_);
                fflush(stderr);
            }
        }
    }
}
