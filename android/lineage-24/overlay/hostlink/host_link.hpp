// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <android-base/unique_fd.h>
#include <linux/vm_sockets.h>
#include <log/log.h>
#include <poll.h>
#include <sys/eventfd.h>
#include <sys/socket.h>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <functional>
#include <mutex>
#include <span>
#include <stop_token>
#include <thread>
#include <vector>

namespace andarium {
// A HAL's private connection to the host, like the motion sub-HAL's: the HAL
// listens on a vsock port and serves one connection at a time, from the host
// (CID 2) alone. The host sends frames of one size, which `received` gets
// whole on the link's thread; it answers false for a frame it cannot read,
// and the connection is dropped (as it is for any byte when frame_size is 0).
// `attached` runs on that thread when the host has connected. Declare the
// link after the state its callbacks use.
class HostLink {
public:
    using Frame = std::span<const uint8_t>;
    HostLink(const char* name, uint32_t port, size_t frame_size, std::function<void()> attached,
             std::function<bool(Frame)> received)
        : name_(name), port_(port), frame_size_(frame_size), attached_(std::move(attached)),
          received_(std::move(received)), wake_(eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK)),
          worker_([this](std::stop_token stop) { serve(stop); }) {}

    // Sends a frame to the host if it is connected, without blocking. A frame
    // that cannot be sent whole would leave the host with a stale picture, so
    // the connection is shut down and the host connects again.
    bool send(Frame frame) {
        std::lock_guard lock(mutex_);
        if (peer_ < 0) return false;
        const auto sent = ::send(peer_, frame.data(), frame.size(), MSG_DONTWAIT | MSG_NOSIGNAL);
        if (sent == static_cast<ssize_t>(frame.size())) return true;
        ALOGW("%s: frame not sent (%zd): %s", name_, sent, strerror(errno));
        shutdown(peer_, SHUT_RDWR);
        return false;
    }

private:
    void setPeer(int fd) {
        std::lock_guard lock(mutex_);
        peer_ = fd;
    }
    // Blocks until fd is readable, with no timeout: the service runs whether
    // or not a host ever connects, so it must not wake to poll. Answers false
    // when the descriptor failed or a stop was requested; nothing drains the
    // wake descriptor, so every later call answers false at once.
    bool readable(int fd) const {
        for (;;) {
            pollfd descriptors[] = {{fd, POLLIN, 0}, {wake_.get(), POLLIN, 0}};
            const auto result = poll(descriptors, 2, -1);
            if (result < 0 && errno == EINTR) continue;
            if (result < 0 || descriptors[1].revents != 0) return false;
            return (descriptors[0].revents & POLLIN) != 0;
        }
    }
    void receive(int fd) {
        std::vector<uint8_t> frame(frame_size_ == 0 ? 1 : frame_size_);
        size_t used = 0;
        while (readable(fd)) {
            const auto count = recv(fd, frame.data() + used, frame.size() - used, MSG_DONTWAIT);
            if (count < 0 && (errno == EINTR || errno == EAGAIN)) continue;
            if (count <= 0 || frame_size_ == 0) return;
            used += count;
            if (used != frame.size()) continue;
            if (!received_(frame)) return;
            used = 0;
        }
    }
    void serve(std::stop_token stop) {
        if (wake_ < 0) {
            ALOGE("%s: cannot create the wake descriptor: %s", name_, strerror(errno));
            return;
        }
        // A stop request wakes whichever poll the thread is blocked in.
        const std::stop_callback wake_on_stop(stop, [this] { eventfd_write(wake_.get(), 1); });
        android::base::unique_fd listener(
                socket(AF_VSOCK, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0));
        sockaddr_vm address{};
        address.svm_family = AF_VSOCK;
        address.svm_cid = VMADDR_CID_ANY;
        address.svm_port = port_;
        if (listener < 0 ||
            bind(listener.get(), reinterpret_cast<sockaddr*>(&address), sizeof(address)) ||
            listen(listener.get(), 1)) {
            ALOGE("%s: cannot listen on vsock: %s", name_, strerror(errno));
            return;
        }
        while (readable(listener.get())) {
            sockaddr_vm peer{};
            socklen_t length = sizeof(peer);
            android::base::unique_fd stream(accept4(
                    listener.get(), reinterpret_cast<sockaddr*>(&peer), &length,
                    SOCK_CLOEXEC | SOCK_NONBLOCK));
            // Only the private host channel may reach the HAL.
            if (stream < 0 || peer.svm_cid != VMADDR_CID_HOST) continue;
            setPeer(stream.get());
            attached_();
            receive(stream.get());
            // Cleared before the descriptor closes.
            setPeer(-1);
        }
    }
    const char* const name_;
    const uint32_t port_;
    const size_t frame_size_;
    const std::function<void()> attached_;
    const std::function<bool(Frame)> received_;
    std::mutex mutex_;
    int peer_ = -1;
    // Declared before the worker, so it outlives the join in the worker's
    // destructor, which requests a stop and so writes to it.
    android::base::unique_fd wake_;
    std::jthread worker_;
};
} // namespace andarium
