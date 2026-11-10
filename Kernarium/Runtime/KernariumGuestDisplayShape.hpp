// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace kernarium::display_shape {

/* The kernel argument through which the runtime tells an Android guest what
 * the host's screen hides of its display: the height and the width of the
 * cutout in the middle of the top edge (a notch or an island) and the radius
 * of the corners, in density-independent pixels, as "<height>,<width>,<radius>".
 * The launcher owns it: the release's command-line file cannot set it (it is a
 * launcher prefix). It becomes ro.boot.kernarium.display_shape, which the
 * guest's display shape script reads. android/lineage-24/README.md owns what
 * the guest does with it. */
inline constexpr std::string_view prefix {
    "androidboot.kernarium.display_shape="};

/* No screen hides this much of a display. */
inline constexpr std::uint32_t maximum = 999;

/* The argument's value for a display, or none for one the screen hides
 * nothing of. Also none for what no screen has: a measure above `maximum`, or
 * a cutout with a height and no width or a width and no height. */
[[nodiscard]] inline std::optional<std::string> value(
    std::uint32_t cutoutHeight,
    std::uint32_t cutoutWidth,
    std::uint32_t cornerRadius)
{
    if (cutoutHeight > maximum || cutoutWidth > maximum ||
        cornerRadius > maximum || (cutoutHeight == 0) != (cutoutWidth == 0) ||
        (cutoutHeight == 0 && cornerRadius == 0))
        return std::nullopt;
    return std::to_string(cutoutHeight) + ',' + std::to_string(cutoutWidth) +
        ',' + std::to_string(cornerRadius);
}

} // namespace kernarium::display_shape
