// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <array>
#include <bit>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

namespace andarium::location {
constexpr uint32_t port = 5558;

// Host-to-guest fix, one for every position the host's location service
// reports. 88 bytes, little endian: "ANL1"; a uint32 of GnssLocation's flags
// for the values that follow (0x01 latitude and longitude, 0x02 altitude, 0x04
// speed, 0x08 bearing, 0x10 horizontal accuracy, 0x20 vertical accuracy, 0x40
// speed accuracy, 0x80 bearing accuracy); nine IEEE float64 in that order
// (degrees, degrees, metres above the WGS 84 ellipsoid, metres per second,
// degrees, metres, metres, metres per second, degrees); then the int64 time of
// the fix in milliseconds since the Unix epoch. A value whose flag is clear is
// not read. A fix always has its position and horizontal accuracy.
constexpr size_t fix_size = 88;
constexpr uint32_t has_position = 0x01;
constexpr uint32_t has_horizontal_accuracy = 0x10;
constexpr uint32_t all_flags = 0xff;
struct Fix {
    uint32_t flags;
    // Latitude, longitude, altitude, speed, bearing, then the accuracies of
    // the position, altitude, speed and bearing.
    std::array<double, 9> values;
    int64_t time_ms;
};
inline std::optional<Fix> decode(std::span<const uint8_t> bytes) {
    if (bytes.size() != fix_size || bytes[0] != 'A' || bytes[1] != 'N' || bytes[2] != 'L' ||
        bytes[3] != '1') return std::nullopt;
    const auto quad = [&bytes](size_t offset) {
        uint64_t value = 0;
        for (size_t i = 0; i < 8; ++i) value |= uint64_t(bytes[offset + i]) << (8 * i);
        return value;
    };
    Fix fix{uint32_t(quad(4)), {}, int64_t(quad(80))};
    const auto required = has_position | has_horizontal_accuracy;
    if ((fix.flags & ~all_flags) != 0 || (fix.flags & required) != required || fix.time_ms <= 0) {
        return std::nullopt;
    }
    // The flag of each value: the position's covers latitude and longitude.
    constexpr std::array<uint32_t, 9> flag{0x01, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80};
    for (size_t i = 0; i < fix.values.size(); ++i) {
        if ((fix.flags & flag[i]) == 0) continue;
        fix.values[i] = std::bit_cast<double>(quad(8 + i * 8));
        // A speed and every accuracy are magnitudes.
        if (!std::isfinite(fix.values[i]) || (i >= 5 && fix.values[i] < 0) ||
            (i == 3 && fix.values[i] < 0)) return std::nullopt;
    }
    if (std::abs(fix.values[0]) > 90 || std::abs(fix.values[1]) > 180) return std::nullopt;
    return fix;
}

// Guest-to-host demand frame, sent on the same connection when the host
// connects and whenever the location framework starts or stops the HAL. 8
// bytes, little endian: "ANG1", then a uint32 that is 1 while the framework
// wants fixes and 0 while it does not. The host locates only while it is 1.
constexpr size_t demand_size = 8;
inline std::array<uint8_t, demand_size> encode_demand(bool active) {
    return {'A', 'N', 'G', '1', uint8_t(active ? 1 : 0), 0, 0, 0};
}
} // namespace andarium::location
