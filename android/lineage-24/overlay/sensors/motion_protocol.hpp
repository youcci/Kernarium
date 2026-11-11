// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <algorithm>
#include <array>
#include <bit>
#include <cmath>
#include <cstdint>
#include <optional>
#include <span>

namespace andarium::motion {
constexpr uint32_t port = 5556;
// The sensors, in the order every list and mask of the protocol uses, by their
// Android sensor type: accelerometer, gyroscope, magnetic field and pressure.
constexpr size_t sensor_count = 4;
constexpr std::array<uint32_t, sensor_count> sensor_types{1, 4, 2, 6};
inline std::optional<size_t> sensor_index(uint32_t type) {
    for (size_t i = 0; i < sensor_count; ++i) {
        if (sensor_types[i] == type) return i;
    }
    return std::nullopt;
}
// Host-to-guest record, 20 bytes, little endian: "ANS1", the Android sensor
// type, three IEEE float32 in the sensor's Android unit and axes: metres per
// second squared, radians per second, microtesla, or the pressure in
// hectopascals followed by two zeros.
constexpr size_t record_size = 20;
struct Sample {
    uint32_t type;
    std::array<float, 3> values;
};
inline std::optional<Sample> decode(std::span<const uint8_t> bytes) {
    if (bytes.size() != record_size || bytes[0] != 'A' || bytes[1] != 'N' ||
        bytes[2] != 'S' || bytes[3] != '1') return std::nullopt;
    const auto word = [&bytes](size_t offset) {
        return uint32_t(bytes[offset]) | (uint32_t(bytes[offset + 1]) << 8) |
               (uint32_t(bytes[offset + 2]) << 16) | (uint32_t(bytes[offset + 3]) << 24);
    };
    Sample sample{word(4), {}};
    if (!sensor_index(sample.type)) return std::nullopt;
    for (size_t i = 0; i < sample.values.size(); ++i) {
        sample.values[i] = std::bit_cast<float>(word(8 + i * 4));
        if (!std::isfinite(sample.values[i])) return std::nullopt;
    }
    return sample;
}

// Guest-to-host control frame, sent on the same connection when the host
// connects and at every change of what applications use. 16 bytes, little
// endian: "ANC2", a uint32 mask of the active sensors (bit 0 accelerometer,
// bit 1 gyroscope, bit 2 magnetic field, bit 3 pressure), then each sensor's
// sampling period as a uint16 in units of 100 microseconds, in that order. The
// host reads a sensor only while it is active. The frame of the service before
// this one, "ANC1", held the first two sensors alone, with uint32 periods in
// microseconds; a host that has seen no frame reads those two continuously.
constexpr size_t control_size = 16;
constexpr int64_t minimum_period_ns = 10'000'000;
constexpr int64_t maximum_period_ns = 1'000'000'000;
inline std::array<uint8_t, control_size> encode_control(
        const std::array<bool, sensor_count>& active,
        const std::array<int64_t, sensor_count>& period_ns) {
    std::array<uint8_t, control_size> frame{'A', 'N', 'C', '2'};
    for (size_t i = 0; i < sensor_count; ++i) {
        if (active[i]) frame[4] |= uint8_t(1u << i);
        const auto period = std::clamp(period_ns[i], minimum_period_ns, maximum_period_ns);
        const auto units = uint16_t(period / 100'000);
        frame[8 + i * 2] = uint8_t(units);
        frame[9 + i * 2] = uint8_t(units >> 8);
    }
    return frame;
}
} // namespace andarium::motion
