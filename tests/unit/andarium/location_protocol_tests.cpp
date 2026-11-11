// SPDX-License-Identifier: GPL-2.0-or-later
#include "location_protocol.hpp"
#include "require.hpp"

#include <algorithm>

using uml::testing::require;

int main()
{
    using andarium::location::decode;
    // Independent wire fixture, the one the host's tests encode: 52.5, -0.25,
    // 64 m, 1.5 m/s, 90 degrees, accuracies 8 m, 4 m, 0.5 m/s and 2 degrees,
    // at 1 700 000 000 250 ms.
    std::array<uint8_t, 88> bytes{
        'A', 'N', 'L', '1', 0xff, 0, 0, 0,
        0, 0, 0, 0, 0, 0x40, 0x4a, 0x40,
        0, 0, 0, 0, 0, 0, 0xd0, 0xbf,
        0, 0, 0, 0, 0, 0, 0x50, 0x40,
        0, 0, 0, 0, 0, 0, 0xf8, 0x3f,
        0, 0, 0, 0, 0, 0x80, 0x56, 0x40,
        0, 0, 0, 0, 0, 0, 0x20, 0x40,
        0, 0, 0, 0, 0, 0, 0x10, 0x40,
        0, 0, 0, 0, 0, 0, 0xe0, 0x3f,
        0, 0, 0, 0, 0, 0, 0, 0x40,
        0xfa, 0x68, 0xe5, 0xcf, 0x8b, 0x01, 0, 0};
    const auto fix = decode(bytes);
    require(fix.has_value());
    require(fix->flags == 0xff);
    require(fix->values == std::array<double, 9>{52.5, -0.25, 64, 1.5, 90, 8, 4, 0.5, 2});
    require(fix->time_ms == 1'700'000'000'250);

    const auto with = [&bytes](size_t offset, std::initializer_list<uint8_t> replacement) {
        auto changed = bytes;
        std::copy(replacement.begin(), replacement.end(), changed.begin() + offset);
        return decode(changed);
    };
    require(!decode(std::span(bytes).first(87)));
    require(!with(3, {'2'}));
    // A value whose flag is clear is not read, even when it is not a number.
    const auto bare = with(4, {0x11});
    require(bare.has_value());
    require(bare->values == std::array<double, 9>{52.5, -0.25, 0, 0, 0, 8, 0, 0, 0});
    require(with(24, {0, 0, 0, 0, 0, 0, 0xf8, 0x7f}).has_value() == false);
    auto unread = bytes;
    unread[4] = 0x11;
    unread[30] = 0xf8;
    unread[31] = 0x7f;
    require(decode(unread).has_value());
    // A fix always has its position and horizontal accuracy, and no other flag.
    require(!with(4, {0xfe}));
    require(!with(4, {0xef}));
    require(!with(5, {1}));
    // A position off the globe, a negative accuracy or speed and a time before
    // the epoch are never a fix.
    require(!with(8, {0, 0, 0, 0, 0, 0xc0, 0x56, 0x40}));  // latitude 91
    require(!with(16, {0, 0, 0, 0, 0, 0xa0, 0x66, 0xc0})); // longitude -181
    require(!with(48, {0, 0, 0, 0, 0, 0, 0x20, 0xc0}));    // accuracy -8
    require(!with(32, {0, 0, 0, 0, 0, 0, 0xf8, 0xbf}));    // speed -1.5
    require(!with(80, {0, 0, 0, 0, 0, 0, 0, 0}));
    require(!with(80, {0, 0, 0, 0, 0, 0, 0, 0x80}));

    // Independent demand frame fixtures.
    using andarium::location::encode_demand;
    require(encode_demand(true) == std::array<uint8_t, 8>{'A', 'N', 'G', '1', 1, 0, 0, 0});
    require(encode_demand(false) == std::array<uint8_t, 8>{'A', 'N', 'G', '1', 0, 0, 0, 0});
}
