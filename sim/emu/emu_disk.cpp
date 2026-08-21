// TRS-80 Rev Z — emulator disk model implementation
//
// See emu_disk.h for the protocol description.

#include "emu_disk.h"

#include <cstdio>
#include <cstring>
#include <stdexcept>

EmuDisk::EmuDisk(const std::string paths[4], const bool wp_override[4])
{
    for (int d = 0; d < 4; d++) {
        if (paths[d].empty()) continue;

        FILE* f = fopen(paths[d].c_str(), "rb");
        if (!f) {
            fprintf(stderr, "emu_disk: cannot open drive %d: %s\n",
                    d, paths[d].c_str());
            continue;
        }

        fseek(f, 0, SEEK_END);
        long sz = ftell(f);
        rewind(f);
        if (sz < 16) {
            fprintf(stderr, "emu_disk: drive %d image too short\n", d);
            fclose(f);
            continue;
        }

        Drive& dr = drives_[d];
        dr.image.resize((size_t)sz);
        if (fread(dr.image.data(), 1, (size_t)sz, f) != (size_t)sz) {
            fprintf(stderr, "emu_disk: drive %d read error\n", d);
            fclose(f);
            continue;
        }
        fclose(f);

        // Parse DMK header (same as dmk_media_model.sv)
        dr.wp       = wp_override[d] || (dr.image[0] == 0xFF);
        dr.ntracks  = (int)dr.image[1];
        dr.tracklen = (int)dr.image[2] | ((int)dr.image[3] << 8);
        dr.dbl      = (dr.image[4] & 0xC0) == 0x00;  // stored doubled
        // Double-sided image (header bit 4 clear and the file actually
        // holds two track blocks per cylinder): two blocks per cylinder,
        // side 1 reachable via the DS drive-select convention (latch
        // bit 3 + drive bit -> trk_side).
        dr.sides    = (!(dr.image[4] & 0x10) &&
                       (long)dr.image.size() >=
                           16L + 2L * dr.ntracks * dr.tracklen) ? 2 : 1;
        dr.mounted  = (dr.ntracks > 0 && dr.tracklen >= 130 &&
                       dr.tracklen <= 8192);

        if (!dr.mounted) {
            fprintf(stderr,
                    "emu_disk: drive %d has bad header "
                    "(ntracks=%d tracklen=%d)\n",
                    d, dr.ntracks, dr.tracklen);
        } else {
            fprintf(stderr,
                    "emu_disk: drive %d mounted, %d tracks, len=%d%s%s%s\n",
                    d, dr.ntracks, dr.tracklen,
                    dr.dbl  ? ", dbl"  : "",
                    dr.sides == 2 ? ", 2-sided" : "",
                    dr.wp   ? ", WP"   : "");
            fdc_disk |= (uint8_t)(1u << d);
            if (dr.wp)
                fdc_wp |= (uint8_t)(1u << d);
        }
    }
}

void EmuDisk::tick()
{
    // Default: deassert all pulses (unless we set them below).
    trk_vld      = 0;
    trk_done     = 0;
    trk_err      = 0;
    trk_wb_fetch = 0;
    trk_wb_done  = 0;
    trk_wb_err   = 0;

    switch (state_) {

    case State::IDLE:
        if (trk_req) {
            cur_drv_   = trk_drv  & 0x3;
            cur_track_ = trk_track & 0x7F;
            cur_side_  = trk_side & 0x1;
            byte_idx_  = 0;
            if (getenv("EMU_DISK_LOG"))
                fprintf(stderr, "emu_disk: fetch drv %d trk %d side %d\n",
                        cur_drv_, cur_track_, cur_side_);

            const Drive& dr = drives_[cur_drv_];
            if (!dr.mounted || cur_track_ >= dr.ntracks ||
                cur_side_ >= dr.sides) {
                state_ = State::ERR_PULSE;
            } else {
                trk_len = (uint16_t)dr.tracklen;
                trk_dbl = dr.dbl ? 1 : 0;
                state_  = State::READ;
            }
        } else if (trk_wb_req) {
            cur_drv_   = trk_drv  & 0x3;
            cur_track_ = trk_track & 0x7F;
            cur_side_  = trk_side & 0x1;
            byte_idx_  = 0;
            const Drive& dr = drives_[cur_drv_];
            if (!dr.mounted || dr.wp || cur_track_ >= dr.ntracks ||
                cur_side_ >= dr.sides) {
                state_ = State::WB_ERR;
            } else {
                wb_buf_.assign((size_t)dr.tracklen, 0x00);
                state_ = State::WB_FETCH;
            }
        }
        break;

    // ----------------------------------------------------------------
    // Read path: stream one byte every two clocks (vld, gap, vld, gap,
    // ...) then a done pulse — identical to dmk_media_model.sv.
    // ----------------------------------------------------------------
    case State::READ: {
        const Drive& dr = drives_[cur_drv_];
        int base = 16 + (cur_track_ * dr.sides + cur_side_) * dr.tracklen;
        trk_vld  = 1;
        trk_idx  = (uint16_t)byte_idx_;
        trk_data = dr.image[(size_t)(base + byte_idx_)];
        byte_idx_++;
        if (byte_idx_ < dr.tracklen)
            state_ = State::READ_GAP;
        else
            state_ = State::DONE_PULSE;
        break;
    }

    case State::READ_GAP:
        state_ = State::READ;
        break;

    case State::DONE_PULSE:
        trk_done = 1;
        state_   = State::IDLE;
        break;

    case State::ERR_PULSE:
        trk_err = 1;
        state_  = State::IDLE;
        break;

    // ----------------------------------------------------------------
    // Write-back path: fetch each byte from the FDC's buffer with a
    // two-clock gap before capture, then store and done.
    // ----------------------------------------------------------------
    case State::WB_FETCH: {
        const Drive& dr = drives_[cur_drv_];
        trk_wb_fetch = 1;
        trk_wb_idx   = (uint16_t)byte_idx_;
        // The FDC answers trk_wb_data two clocks after the fetch edge.
        state_ = State::WB_GAP1;
        (void)dr;
        break;
    }

    case State::WB_GAP1:
        state_ = State::WB_GAP2;
        break;

    case State::WB_GAP2:
        state_ = State::WB_CAPTURE;
        break;

    case State::WB_CAPTURE: {
        // trk_wb_data_in is valid this cycle.
        if (byte_idx_ < (int)wb_buf_.size())
            wb_buf_[(size_t)byte_idx_] = trk_wb_data_in;
        byte_idx_++;
        const Drive& dr = drives_[cur_drv_];
        if (byte_idx_ < dr.tracklen) {
            state_ = State::WB_FETCH;
        } else {
            // Commit to in-memory image.
            int base = 16 + (cur_track_ * dr.sides + cur_side_) * dr.tracklen;
            memcpy(drives_[cur_drv_].image.data() + base,
                   wb_buf_.data(),
                   (size_t)dr.tracklen);
            state_ = State::WB_DONE;
        }
        break;
    }

    case State::WB_DONE:
        trk_wb_done = 1;
        state_      = State::IDLE;
        break;

    case State::WB_ERR:
        trk_wb_err = 1;
        state_     = State::IDLE;
        break;
    }
}
