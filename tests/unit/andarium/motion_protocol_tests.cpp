// SPDX-License-Identifier: GPL-2.0-or-later
#include "motion_protocol.hpp"
#include "require.hpp"

using uml::testing::require;

int main()
{
    // Independent wire fixture: +1, -2, +0.5 radians/second.
    std::array<uint8_t, 20> bytes{
        'A', 'N', 'S', '1', 4, 0, 0, 0,
        0, 0, 0x80, 0x3f, 0, 0, 0, 0xc0, 0, 0, 0, 0x3f};
    const auto sample = andarium::motion::decode(bytes);
    require(sample.has_value());
    require(sample->type == 4);
    require(sample->values == std::array<float, 3>{1, -2, 0.5f});
    require(!andarium::motion::decode(std::span(bytes).first(19)));
    bytes[0] = 0;
    require(!andarium::motion::decode(bytes));
    bytes[0] = 'A';
    bytes[4] = 99;
    require(!andarium::motion::decode(bytes));
    bytes[4] = 1;
    require(andarium::motion::decode(bytes).has_value());
    bytes[10] = 0x80;
    bytes[11] = 0x7f; // Infinity is never a physical measurement.
    require(!andarium::motion::decode(bytes));
    bytes[10] = 0xc0; // Neither is NaN.
    require(!andarium::motion::decode(bytes));

    // The magnetic field in microtesla and the pressure in hectopascals are
    // records of the same form; the pressure is the first value.
    bytes = {'A', 'N', 'S', '1', 2, 0, 0, 0,
             0, 0, 0xa0, 0x41, 0, 0, 0x20, 0xc2, 0, 0, 0, 0}; // 20, -40, 0
    auto field = andarium::motion::decode(bytes);
    require(field.has_value() && field->type == 2);
    require(field->values == std::array<float, 3>{20, -40, 0});
    bytes = {'A', 'N', 'S', '1', 6, 0, 0, 0,
             0, 0x50, 0x7d, 0x44, 0, 0, 0, 0, 0, 0, 0, 0}; // 1013.25
    auto pressure = andarium::motion::decode(bytes);
    require(pressure.has_value() && pressure->type == 6);
    require(pressure->values[0] == 1013.25f);
    using andarium::motion::sensor_index;
    require(sensor_index(1) == 0 && sensor_index(4) == 1 && sensor_index(2) == 2 &&
            sensor_index(6) == 3 && !sensor_index(3));

    // Independent control frame fixtures: the accelerometer alone at 20 ms
    // (the other periods are carried and not read), then all four, at 66.7 ms,
    // 1 s, 20 ms and 1 s, in units of 100 us.
    using andarium::motion::encode_control;
    const int64_t ms = 1'000'000;
    require(encode_control({true, false, false, false}, {20 * ms, 10 * ms, 10 * ms, 10 * ms}) ==
            std::array<uint8_t, 16>{'A', 'N', 'C', '2', 1, 0, 0, 0,
                                    0xc8, 0, 0x64, 0, 0x64, 0, 0x64, 0});
    require(encode_control({true, true, true, true}, {66'667'000, 1000 * ms, 20 * ms, 1000 * ms}) ==
            std::array<uint8_t, 16>{'A', 'N', 'C', '2', 0x0f, 0, 0, 0,
                                    0x9a, 0x02, 0x10, 0x27, 0xc8, 0, 0x10, 0x27});
    // Nothing in use, and periods the sensor framework would never ask for,
    // which the frame brings into 10 ms to 1 s.
    require(encode_control({false, false, false, false}, {0, 5000 * ms, 0, 0}) ==
            std::array<uint8_t, 16>{'A', 'N', 'C', '2', 0, 0, 0, 0,
                                    0x64, 0, 0x10, 0x27, 0x64, 0, 0x64, 0});
    require(encode_control({false, false, true, false}, {10 * ms, 10 * ms, 10 * ms, 10 * ms})[4] == 4);
    require(encode_control({false, false, false, true}, {10 * ms, 10 * ms, 10 * ms, 10 * ms})[4] == 8);
}
