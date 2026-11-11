// SPDX-License-Identifier: Apache-2.0

#define LOG_TAG "andarium.camera"

#include "camera_protocol.hpp"
#include <BaseQemuCamera.h>
#include <host_link.hpp>
#include <service_entry.h>
#include <ui/GraphicBufferMapper.h>
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <vector>

namespace {
using namespace android::hardware::camera::provider::implementation;
using namespace android::hardware::camera::provider::implementation::hw;
namespace wire = andarium::camera;
using Pixels = std::shared_ptr<const std::vector<uint8_t>>;

// The host's camera, on the HAL's private connection. The host captures only
// while Android has a camera open, and sends a picture when asked for one.
class HostFeed {
public:
    static HostFeed& get() {
        static HostFeed feed;
        return feed;
    }
    void open(uint8_t camera) {
        std::lock_guard lock(mutex_);
        open_ = camera;
        tell();
    }
    void close(uint8_t camera) {
        std::lock_guard lock(mutex_);
        if (open_ != camera) return;
        open_ = wire::none;
        tell();
    }
    // The camera's latest picture, or null without a host that answers.
    Pixels next(uint8_t camera) {
        std::unique_lock lock(mutex_);
        fresh_ = wire::none;
        if (!link_.send(wire::encode_request(camera, true))) return nullptr;
        const auto arrived = [&] { return fresh_ == camera; };
        if (!arrived_.wait_for(lock, std::chrono::milliseconds(500), arrived)) return nullptr;
        return pixels_;
    }

private:
    // Called with mutex_ held.
    void tell() { link_.send(wire::encode_request(open_, false)); }
    void attached() {
        std::lock_guard lock(mutex_);
        tell();
    }
    bool received(andarium::HostLink::Frame image) {
        const auto camera = wire::image_camera(image);
        if (camera == wire::none) return false;
        std::lock_guard lock(mutex_);
        // A still that is being compressed keeps the picture it reads.
        if (!pixels_ || pixels_.use_count() > 1) {
            pixels_ = std::make_shared<std::vector<uint8_t>>(wire::pixels_size);
        }
        memcpy(pixels_->data(), image.data() + wire::header_size, wire::pixels_size);
        fresh_ = camera;
        arrived_.notify_all();
        return true;
    }
    std::mutex mutex_;
    std::condition_variable arrived_;
    uint8_t open_ = wire::none;
    // The camera of a picture that arrived after the last request for one.
    uint8_t fresh_ = wire::none;
    std::shared_ptr<std::vector<uint8_t>> pixels_;
    andarium::HostLink link_{"Andarium camera", wire::port, wire::image_size,
                             [this] { attached(); },
                             [this](andarium::HostLink::Frame image) { return received(image); }};
};

std::span<const uint8_t, wire::pixels_size> span(const std::vector<uint8_t>& pixels) {
    return std::span<const uint8_t, wire::pixels_size>(pixels.data(), wire::pixels_size);
}

bool write(const std::vector<uint8_t>& pixels, const native_handle_t* buffer) {
    auto& mapper = android::GraphicBufferMapper::get();
    android_ycbcr planes;
    if (mapper.lockYCbCr(buffer, static_cast<uint32_t>(BufferUsage::CPU_WRITE_OFTEN),
                         {int32_t(wire::width), int32_t(wire::height)},
                         &planes) != android::NO_ERROR) return false;
    wire::copy_pixels(span(pixels),
                      {static_cast<uint8_t*>(planes.y), static_cast<uint8_t*>(planes.cb),
                       static_cast<uint8_t*>(planes.cr), planes.ystride, planes.cstride,
                       planes.chroma_step});
    return mapper.unlock(buffer) == android::NO_ERROR;
}

bool compress(const std::vector<uint8_t>& pixels, const CameraMetadata& metadata,
              const native_handle_t* buffer, size_t size) {
    // The JPEG encoder reads planar chroma.
    std::vector<uint8_t> planar(wire::pixels_size);
    uint8_t* const y = planar.data();
    uint8_t* const cb = y + wire::luma_size;
    uint8_t* const cr = cb + wire::luma_size / 4;
    wire::copy_pixels(span(pixels), {y, cb, cr, wire::width, wire::width / 2, 1});
    const android_ycbcr image{y, cb, cr, wire::width, wire::width / 2, 1, {}};
    return HwCamera::compressJpeg({uint16_t(wire::width), uint16_t(wire::height)}, image,
                                  metadata, buffer, size);
}

constexpr BufferUsage with(BufferUsage usage, BufferUsage more) {
    return static_cast<BufferUsage>(static_cast<int64_t>(usage) | static_cast<int64_t>(more));
}

// One of the host's cameras as goldfish's provider sees a camera: the base
// class describes it and answers the controls, and every picture is the
// host's. Preview, analysis and video streams are 4:2:0 buffers the picture is
// copied into; a still is compressed here from the same picture.
class HostCamera final : public BaseQemuCamera {
public:
    HostCamera(const Parameters& parameters, uint8_t camera)
        : BaseQemuCamera(parameters), camera_(camera) {}

    std::tuple<PixelFormat, BufferUsage, Dataspace, int32_t> overrideStreamParams(
            PixelFormat format, BufferUsage usage, Dataspace dataspace) const override {
        const auto written =
                with(usage, with(BufferUsage::CAMERA_OUTPUT, BufferUsage::CPU_WRITE_OFTEN));
        const bool encoded = with(usage, BufferUsage::VIDEO_ENCODER) == usage;
        switch (format) {
            case PixelFormat::IMPLEMENTATION_DEFINED:
            case PixelFormat::YCBCR_420_888:
                return {PixelFormat::YCBCR_420_888, written, Dataspace::JFIF, encoded ? 8 : 4};
            case PixelFormat::BLOB:
                if (dataspace != Dataspace::JFIF) return {format, usage, dataspace, kErrorBadDataspace};
                return {format, written, dataspace, 4};
            default:
                return {format, usage, dataspace, kErrorBadFormat};
        }
    }
    bool configure(const CameraMetadata& session, size_t count, const Stream* streams,
                   const HalStream* hal_streams) override {
        std::vector<StreamInfo> configured(count);
        for (size_t i = 0; i < count; ++i) {
            if (streams[i].width != int32_t(wire::width) ||
                streams[i].height != int32_t(wire::height)) return false;
            configured[i] = {streams[i].id, hal_streams[i].overrideFormat,
                             size_t(streams[i].bufferSize)};
        }
        streams_ = std::move(configured);
        applyMetadata(session);
        HostFeed::get().open(camera_);
        return true;
    }
    void close() override {
        HostFeed::get().close(camera_);
        streams_.clear();
    }
    std::tuple<int64_t, int64_t, CameraMetadata, std::vector<StreamBuffer>,
               std::vector<DelayedStreamBuffer>>
    processCaptureRequest(CameraMetadata update, Span<CachedStreamBuffer*> buffers) override {
        CameraMetadata result = update.metadata.empty() ? updateCaptureResultMetadata()
                                                        : applyMetadata(std::move(update));
        const Pixels pixels = HostFeed::get().next(camera_);
        std::vector<StreamBuffer> done;
        std::vector<DelayedStreamBuffer> delayed;
        for (CachedStreamBuffer* buffer : buffers) {
            const auto stream = std::find_if(
                    streams_.begin(), streams_.end(),
                    [buffer](const StreamInfo& info) { return info.id == buffer->getStreamId(); });
            if (!pixels || stream == streams_.end()) {
                done.push_back(buffer->finish(false));
            } else if (stream->format == PixelFormat::BLOB) {
                delayed.push_back([pixels, buffer, size = stream->blob_size,
                                   metadata = mCaptureResultMetadata](bool wanted) {
                    return buffer->finish(wanted && buffer->waitAcquireFence(100) &&
                                          compress(*pixels, metadata, buffer->getBuffer(), size));
                });
            } else {
                done.push_back(buffer->finish(buffer->waitAcquireFence(100) &&
                                              write(*pixels, buffer->getBuffer())));
            }
        }
        // A request without a picture fails its buffers and not the camera:
        // the host answers again once it is in front.
        return {mFrameDurationNs, mSensorExposureDurationNs, std::move(result), std::move(done),
                std::move(delayed)};
    }

    // What the base class says of an emulator's camera and is not so here:
    // no raw stream, and 15 pictures a second, which is what an interpreted
    // guest can copy.
    uint32_t getAvailableCapabilitiesBitmap() const override {
        return (1U << ANDROID_REQUEST_AVAILABLE_CAPABILITIES_BACKWARD_COMPATIBLE) |
               (1U << ANDROID_REQUEST_AVAILABLE_CAPABILITIES_READ_SENSOR_SETTINGS);
    }
    Span<const PixelFormat> getSupportedPixelFormats() const override {
        static const PixelFormat formats[] = {PixelFormat::IMPLEMENTATION_DEFINED,
                                              PixelFormat::YCBCR_420_888, PixelFormat::BLOB};
        return formats;
    }
    std::tuple<int32_t, int32_t, int32_t> getMaxNumOutputStreams() const override {
        return {0, 2, 1};
    }
    Span<const std::pair<int32_t, int32_t>> getTargetFpsRanges() const override {
        static const std::pair<int32_t, int32_t> ranges[] = {{5, rate}, {rate, rate}};
        return ranges;
    }
    std::pair<int32_t, int32_t> getDefaultTargetFpsRange(RequestTemplate) const override {
        return {rate, rate};
    }
    int64_t getMinFrameDurationNs() const override { return 1000000000 / rate; }
    int64_t getDefaultSensorFrameDuration() const override { return 1000000000 / rate; }

private:
    static constexpr int32_t rate = 15;
    struct StreamInfo {
        int32_t id;
        PixelFormat format;
        size_t blob_size;
    };
    const uint8_t camera_;
    std::vector<StreamInfo> streams_;
};
} // namespace

int main() {
    // The host connects before Android opens a camera.
    HostFeed::get();
    // Android's ids are 0 for the back camera and 1 for the front one. A
    // phone's sensors lie on their side, the back one a quarter turn one way
    // and the front one the other.
    static const BaseQemuCamera::Parameters back{"back", {{640, 480}}, {{0, 0}, {160, 120}},
                                                 {640, 480}, true, 90};
    static const BaseQemuCamera::Parameters front{"front", {{640, 480}}, {{0, 0}, {160, 120}},
                                                  {640, 480}, false, 270};
    static const HwCameraFactory cameras[] = {
            [] { return std::make_unique<HostCamera>(back, wire::back); },
            [] { return std::make_unique<HostCamera>(front, wire::front); },
    };
    return serviceEntry(0, cameras, 4);
}
