// TRS-80 Rev Z — emulator cassette deck (M2)
//
// Plays a tape file into m1_core.cass_in, motor-gated like a real
// CTR-41 on the remote plug: the tape only rolls while the relay is
// closed, and pauses in place when it opens. Two formats:
//
//   .cas — the raw byte stream. Pulses are synthesized at 500 baud
//          (Level II low-speed: 2 ms per bit MSB first, clock pulse at
//          the cell start, a '1' adds a data pulse 1 ms in) — the same
//          timing the golden bench pinned against trs80gp -c
//          (make golden-cass).
//   .wav — audio. The Z4 analog front end (filter/rectifier/level
//          detector) is modeled here in the media layer, where the
//          analog half of the circuit lives: peak-relative threshold
//          with hysteresis and a refractory window turns each recorded
//          pulse into one clean cass_in edge.
//
// tick() is called once per rising dot-clock edge; a phase accumulator
// derives the same 1 MHz grid the EI uses (ADR-0001 idiom).

#pragma once
#include <cstdint>
#include <string>
#include <vector>

class EmuCassette {
public:
    // Returns false (with a message on stderr) if the file cannot be
    // parsed. baud applies to .cas synthesis only.
    bool load(const std::string& path, int baud = 500);

    bool loaded() const { return !pulses_.empty(); }

    // --- per-tick interface ---
    uint8_t motor = 0;        // in: cassette relay (m1_core.cass_motor)
    uint8_t out   = 0;        // out: cass_in level for m1_core

    void tick();

private:
    std::vector<uint64_t> pulses_;   // motor-on microseconds
    size_t   next_    = 0;
    uint64_t pos_us_  = 0;
    int      high_us_ = 0;
    uint32_t acc_     = 0;           // 1 MHz phase accumulator

    static constexpr int      PULSE_US = 50;
    static constexpr uint32_t ACC_K    = 1576139;  // 2^24 / 10.6445

    bool load_cas(const std::string& path, int baud);
    bool load_wav(const std::string& path);
};
