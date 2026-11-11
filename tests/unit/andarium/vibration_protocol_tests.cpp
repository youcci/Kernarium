// SPDX-License-Identifier: GPL-2.0-or-later
#include "vibration_protocol.hpp"
#include "require.hpp"

using uml::testing::require;

int main()
{
    // Independent wire fixtures: on for 250 ms at half amplitude, then off at
    // full amplitude.
    using andarium::vibration::encode;
    require(encode(250, 0.5f) ==
            std::array<uint8_t, 12>{'A', 'N', 'V', '1', 0xfa, 0, 0, 0, 0, 0, 0, 0x3f});
    require(encode(0, 1.0f) ==
            std::array<uint8_t, 12>{'A', 'N', 'V', '1', 0, 0, 0, 0, 0, 0, 0x80, 0x3f});
    require(encode(0x01020304, 1.0f)[4] == 4 && encode(0x01020304, 1.0f)[7] == 1);
}
