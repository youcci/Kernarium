// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <array>
#include <bit>
#include <cstddef>
#include <cstdint>

namespace andarium::vibration {
constexpr uint32_t port = 5557;
// Guest-to-host frame, sent on the connection the host made whenever what the
// vibrator does changes. 12 bytes, little endian: "ANV1", the uint32 time in
// milliseconds the vibrator stays on from now (0 turns it off), then the IEEE
// float32 amplitude in (0, 1]. A later frame replaces an earlier one.
constexpr size_t frame_size = 12;
inline std::array<uint8_t, frame_size> encode(uint32_t duration_ms, float amplitude) {
    std::array<uint8_t, frame_size> frame{'A', 'N', 'V', '1'};
    const auto put = [&frame](size_t offset, uint32_t value) {
        for (size_t i = 0; i < 4; ++i) frame[offset + i] = uint8_t(value >> (8 * i));
    };
    put(4, duration_ms);
    put(8, std::bit_cast<uint32_t>(amplitude));
    return frame;
}
} // namespace andarium::vibration
