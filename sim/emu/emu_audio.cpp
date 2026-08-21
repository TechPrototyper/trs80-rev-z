// TRS-80 Rev Z — emulator program sound implementation (see emu_audio.h)

#include "emu_audio.h"

#include <SDL.h>
#include <cstdio>
#include <cstring>
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

void EmuAudio::tick(uint8_t ladder)
{
    uint32_t a = acc_ + ACC_K;
    acc_ = a & 0xFFFFFF;
    if (!(a >> 24))
        return;                            // not a 1 MHz tick
    emu_us_++;

    sample_acc_ += 1.0f;
    if (sample_acc_ < period_us_)
        return;
    sample_acc_ -= period_us_;

    // DC-blocking one-pole high-pass (fc ~ 20 Hz at 44.1 kHz)
    float x = level(ladder);
    float y = 0.997f * (y_prev_ + x - x_prev_);
    x_prev_ = x;
    y_prev_ = y;
    // fade in over the first second — the controller converges muted
    float fade = (total_samples_ < 44100)
                 ? (float)total_samples_ / 44100.0f : 1.0f;
    total_samples_++;
    push(y * vol_ * fade * fade);

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
