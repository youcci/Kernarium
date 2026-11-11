// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <span>

namespace andarium::camera {
constexpr uint32_t port = 5559;

// The one size the host's camera is read at.
constexpr size_t width = 640;
constexpr size_t height = 480;
constexpr uint8_t none = 0;
constexpr uint8_t back = 1;
constexpr uint8_t front = 2;

// Guest-to-host request, sent when the host connects, when a camera is opened
// or closed, and for every image. 8 bytes: "ANQ1"; the camera Android has
// open (0 none, 1 back, 2 front); 1 to ask for one image of that camera, else
// 0; two zero bytes. The host's camera runs only while a camera is open.
constexpr size_t request_size = 8;
constexpr std::array<uint8_t, request_size> encode_request(uint8_t camera, bool image) {
    return {'A', 'N', 'Q', '1', camera, uint8_t(image ? 1 : 0), 0, 0};
}

// Host-to-guest image, the answer to a request for one: the camera's latest
// picture, or a black one before it has any. An 8-byte header ("ANI1", the
// camera, three zero bytes), then the picture as the sensor lies (its long
// side is the width): 640 x 480 luma bytes, row after row, then 240 rows of
// 320 Cb, Cr pairs (4:2:0, full range).
constexpr size_t header_size = 8;
constexpr size_t luma_size = width * height;
constexpr size_t pixels_size = luma_size + luma_size / 2;
constexpr size_t image_size = header_size + pixels_size;

// The camera an image is of, or none for bytes that are not an image.
inline uint8_t image_camera(std::span<const uint8_t> bytes) {
    constexpr std::array<uint8_t, 4> magic{'A', 'N', 'I', '1'};
    if (bytes.size() != image_size || memcmp(bytes.data(), magic.data(), magic.size()) != 0 ||
        (bytes[4] != back && bytes[4] != front) || bytes[5] != 0 || bytes[6] != 0 ||
        bytes[7] != 0) return none;
    return bytes[4];
}

// The planes of a 4:2:0 buffer as gralloc describes a locked one: row strides
// in bytes, and the distance between two chroma samples of one plane.
struct Planes {
    uint8_t* y;
    uint8_t* cb;
    uint8_t* cr;
    size_t y_stride;
    size_t c_stride;
    size_t c_step;
};

// Copies an image's pixels into a buffer of the same size. A buffer that
// interleaves its chroma as the image does takes it a row at a time.
inline void copy_pixels(std::span<const uint8_t, pixels_size> pixels, const Planes& to) {
    for (size_t row = 0; row < height; ++row) {
        memcpy(to.y + row * to.y_stride, pixels.data() + row * width, width);
    }
    const bool interleaved = to.c_step == 2 && to.cr == to.cb + 1;
    for (size_t row = 0; row < height / 2; ++row) {
        const uint8_t* from = pixels.data() + luma_size + row * width;
        if (interleaved) {
            memcpy(to.cb + row * to.c_stride, from, width);
            continue;
        }
        for (size_t column = 0; column < width / 2; ++column) {
            to.cb[row * to.c_stride + column * to.c_step] = from[2 * column];
            to.cr[row * to.c_stride + column * to.c_step] = from[2 * column + 1];
        }
    }
}
} // namespace andarium::camera
