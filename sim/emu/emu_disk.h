// TRS-80 Rev Z — emulator disk model (DMK files on the host filesystem)
//
// Replaces boards/ulx3s/rtl/m1_dmk_fetch.v + m1_sd_fs.v + sd_spi_host.v.
// Implements the exact trk_* handshake that m1_core expects (same protocol
// exercised by sim/dmk_media_model.sv in the unit tests):
//
//   Read path (m1_core drives trk_req):
//     1. m1_core asserts trk_req for one clock with trk_drv / trk_track.
//     2. We stream: for each byte i of the raw DMK track [0, tracklen):
//          trk_vld=1, trk_idx=i, trk_data=byte  — one clock
//          trk_vld=0                             — one clock gap
//        then trk_done=1 for one clock.
//     3. On error (no image, track out of range): trk_err=1 for one clock.
//
//   Write-back path (m1_core drives trk_wb_req):
//     1. m1_core asserts trk_wb_req.
//     2. We assert trk_wb_fetch=1 / trk_wb_idx=i for one clock, then =0;
//        m1_core answers trk_wb_data two clocks after the fetch edge.
//     3. After all bytes collected, write them to the in-memory image and
//        assert trk_wb_done=1 for one clock.
//
// The emulator calls tick() once per rising clock edge (after eval()).

#pragma once
#include <cstdint>
#include <string>
#include <vector>

class EmuDisk {
public:
    // Up to 4 drives. Pass "" for an unmounted slot.
    EmuDisk(const std::string paths[4], const bool wp[4]);
    ~EmuDisk() = default;

    // --- outputs to m1_core ---
    uint8_t  trk_vld  = 0;
    uint8_t  trk_data = 0;
    uint16_t trk_idx  = 0;   // 13 bits used
    uint8_t  trk_done = 0;
    uint8_t  trk_err  = 0;
    uint16_t trk_len  = 0;   // 13 bits; updated on each new trk_req
    uint8_t  trk_dbl  = 0;

    uint8_t  trk_wb_fetch = 0;
    uint16_t trk_wb_idx   = 0;  // 13 bits
    uint8_t  trk_wb_done  = 0;
    uint8_t  trk_wb_err   = 0;

    uint8_t  fdc_disk = 0;   // bit i = drive i has media
    uint8_t  fdc_wp   = 0;   // bit i = drive i is write-protected

    // --- inputs from m1_core (caller sets before tick()) ---
    uint8_t  trk_req        = 0;
    uint8_t  trk_drv        = 0;   // 2 bits
    uint8_t  trk_track      = 0;   // 7 bits
    uint8_t  trk_side       = 0;   // DS latch bit 3: head 1

    uint8_t  trk_wb_req     = 0;
    // trk_wb_data: byte the FDC provides after we assert trk_wb_fetch
    // (m1_core's trk_wb_data output, valid 2 clocks after the fetch edge)
    uint8_t  trk_wb_data_in = 0;

    // Called once per rising clock edge (after top->eval()).
    void tick();

private:
    struct Drive {
        bool                 mounted  = false;
        bool                 wp       = false;
        int                  ntracks  = 0;
        int                  tracklen = 0;
        int                  sides    = 1;   // 2: DS image (2 blocks/cyl)
        bool                 dbl      = false;
        std::vector<uint8_t> image;  // raw DMK bytes
    };

    Drive drives_[4];

    enum class State { IDLE, READ, READ_GAP, DONE_PULSE,
                       ERR_PULSE,
                       WB_FETCH, WB_GAP1, WB_GAP2, WB_CAPTURE,
                       WB_DONE, WB_ERR };
    State state_     = State::IDLE;
    int   cur_drv_   = 0;
    int   cur_track_ = 0;
    int   cur_side_  = 0;
    int   byte_idx_  = 0;

    std::vector<uint8_t> wb_buf_;
};
