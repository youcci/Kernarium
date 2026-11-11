// SPDX-License-Identifier: GPL-2.0-or-later
#include "camera_protocol.hpp"
#include "require.hpp"

#include <algorithm>
#include <vector>

using uml::testing::require;
namespace wire = andarium::camera;

namespace {
uint8_t luma(size_t row, size_t column) { return uint8_t(row * 7 + column); }
uint8_t blue(size_t row, size_t column) { return uint8_t(row + 2 * column); }
uint8_t red(size_t row, size_t column) { return uint8_t(3 * row + column + 1); }

// Whether a buffer of this layout holds the test picture after a copy, and
// the copy left the padding of its rows alone.
bool copies(size_t y_stride, size_t c_stride, size_t c_step, bool red_first)
{
    std::vector<uint8_t> pixels(wire::pixels_size);
    for (size_t row = 0; row < wire::height; ++row)
        for (size_t column = 0; column < wire::width; ++column)
            pixels[row * wire::width + column] = luma(row, column);
    for (size_t row = 0; row < wire::height / 2; ++row)
        for (size_t column = 0; column < wire::width / 2; ++column) {
            pixels[wire::luma_size + row * wire::width + 2 * column] = blue(row, column);
            pixels[wire::luma_size + row * wire::width + 2 * column + 1] = red(row, column);
        }

    std::vector<uint8_t> y(wire::height * y_stride, 0xee);
    // Interleaved chroma shares one plane; planar chroma has one each.
    std::vector<uint8_t> first(wire::height / 2 * c_stride, 0xee);
    std::vector<uint8_t> second(wire::height / 2 * c_stride, 0xee);
    uint8_t* cb = first.data();
    uint8_t* cr = c_step == 2 ? first.data() + 1 : second.data();
    if (red_first) std::swap(cb, cr);
    wire::copy_pixels(std::span<const uint8_t, wire::pixels_size>(pixels),
                      {y.data(), cb, cr, y_stride, c_stride, c_step});

    for (size_t row = 0; row < wire::height; ++row) {
        for (size_t column = 0; column < wire::width; ++column)
            if (y[row * y_stride + column] != luma(row, column)) return false;
        if (y_stride > wire::width && y[row * y_stride + wire::width] != 0xee) return false;
    }
    for (size_t row = 0; row < wire::height / 2; ++row) {
        for (size_t column = 0; column < wire::width / 2; ++column)
            if (cb[row * c_stride + column * c_step] != blue(row, column) ||
                cr[row * c_stride + column * c_step] != red(row, column)) return false;
        const size_t used = wire::width / 2 * c_step;
        if (c_stride > used && first[row * c_stride + used] != 0xee) return false;
    }
    return true;
}
} // namespace

int main()
{
    // Independent wire fixtures: one picture of the back camera, please, and
    // no camera is open.
    require(wire::encode_request(wire::back, true) ==
            std::array<uint8_t, 8>{'A', 'N', 'Q', '1', 1, 1, 0, 0});
    require(wire::encode_request(wire::none, false) ==
            std::array<uint8_t, 8>{'A', 'N', 'Q', '1', 0, 0, 0, 0});

    require(wire::image_size == 460808);
    std::vector<uint8_t> image(wire::image_size);
    const std::array<uint8_t, 8> header{'A', 'N', 'I', '1', 2, 0, 0, 0};
    std::copy(header.begin(), header.end(), image.begin());
    require(wire::image_camera(image) == wire::front);
    // Not an image: a camera that is none or unknown, a set reserved byte,
    // another magic, another size.
    for (const uint8_t camera : {0, 3}) {
        image[4] = camera;
        require(wire::image_camera(image) == wire::none);
    }
    image[4] = 1;
    require(wire::image_camera(image) == wire::back);
    image[7] = 1;
    require(wire::image_camera(image) == wire::none);
    image[7] = 0;
    image[3] = '2';
    require(wire::image_camera(image) == wire::none);
    image[3] = '1';
    require(wire::image_camera(std::span(image).first(image.size() - 1)) == wire::none);

    // A buffer laid out as the image, one with padded rows, one with its
    // chroma the other way round, and planar ones.
    require(copies(640, 640, 2, false));
    require(copies(704, 704, 2, false));
    require(copies(640, 640, 2, true));
    require(copies(640, 320, 1, false));
    require(copies(672, 336, 1, true));
}
