// SPDX-License-Identifier: GPL-2.0-or-later

import Darwin
import Foundation

/// The private connection to one of the guest's host-backed HALs on its vsock
/// port, with the lifecycle `MotionStream` has: frames of one size arrive
/// whole and in order, a frame the receiver cannot read drops the connection,
/// and a connection that fails or drops is tried again after `retryDelay`.
/// Nothing is queued: a write that would block closes the connection, unless
/// the sender says how long the guest may take to read a frame it asked for.
/// No timer runs while connected. A
/// stop closes the connection, and a connection completing after a stop
/// cannot revive it. The opener must bound its connect wait.
public final class GuestFrameStream: @unchecked Sendable {
    private let opener: any GuestStreamOpener
    private let frameSize: Int
    private let retryDelay: DispatchTimeInterval
    private let connectionChanged: @Sendable (Bool) -> Void
    private let received: @Sendable (Data) -> Bool
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "andarium-guest-frame-stream")
    private var running = false
    private var generation: UInt64 = 0
    private var descriptor: Int32 = -1
    private var reader: DispatchSourceRead?
    /// The start of a frame that has not all arrived.
    private var partial = Data()

    /// `received` answers whether it could read the frame. Both callbacks run
    /// in order on a queue of the stream's own.
    public init(
        opener: any GuestStreamOpener, frameSize: Int,
        retryDelay: DispatchTimeInterval = .seconds(1),
        connectionChanged: @escaping @Sendable (Bool) -> Void = { _ in },
        received: @escaping @Sendable (Data) -> Bool
    ) {
        precondition(frameSize > 0)
        self.opener = opener
        self.frameSize = frameSize
        self.retryDelay = retryDelay
        self.connectionChanged = connectionChanged
        self.received = received
    }
    deinit { stop() }

    public func start() {
        let epoch: UInt64? = lock.withLock {
            guard !running else { return nil }
            running = true
            generation &+= 1
            return generation
        }
        guard let epoch else { return }
        queue.async { [self] in connect(epoch: epoch) }
    }

    public func stop() {
        lock.withLock {
            running = false
            generation &+= 1
            partial.removeAll()
            _ = closeStream()
        }
    }

    /// Sends a frame if the guest is connected; a frame for a guest that is
    /// not is dropped. A frame larger than the connection's buffer, which the
    /// guest asked for and reads at once, is given `patience` milliseconds to
    /// be read. The wait holds the stream's lock, so a stop waits with it.
    public func send(_ frame: Data, patience: Int = 0) {
        let dropped = lock.withLock { () -> UInt64? in
            guard running, descriptor >= 0 else { return nil }
            let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(patience) * 1_000_000
            var sent = 0
            while sent < frame.count {
                let count = frame.withUnsafeBytes {
                    Darwin.send(descriptor, $0.baseAddress! + sent, $0.count - sent, MSG_DONTWAIT)
                }
                if count > 0 {
                    sent += count
                    continue
                }
                let now = DispatchTime.now().uptimeNanoseconds
                guard count < 0, errno == EAGAIN || errno == EINTR, now < deadline else { break }
                var writable = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                _ = poll(&writable, 1, Int32(clamping: (deadline - now) / 1_000_000 + 1))
            }
            guard sent != frame.count else { return nil }
            // Closing discards a partial frame and avoids queuing old frames
            // behind a stalled or paused guest.
            return closeStream() ? generation : nil
        }
        if let dropped { queue.async { [self] in lost(epoch: dropped) } }
    }

    // Called only with the lock held. The descriptor is closed by the reader's
    // cancel handler, after it can no longer be sent on, so a stop cannot
    // close a descriptor number that has been reused. Answers whether a
    // connection was closed.
    private func closeStream() -> Bool {
        guard descriptor >= 0 else { return false }
        let closing = descriptor
        descriptor = -1
        if let reader {
            self.reader = nil
            reader.cancel()
        } else {
            Darwin.close(closing)
        }
        return true
    }

    private func connect(epoch: UInt64) {
        let current = lock.withLock { running && generation == epoch && descriptor < 0 }
        guard current else { return }
        let opened = try? opener.openStream()
        let connected = lock.withLock { () -> Bool? in
            guard running, generation == epoch else {
                if let opened { Darwin.close(opened) }
                return nil
            }
            guard let opened else { return false }
            var one: Int32 = 1
            // MSG_DONTWAIT alone does not keep a send to a full buffer from
            // waiting for space.
            guard setsockopt(opened, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0,
                  fcntl(opened, F_SETFL, fcntl(opened, F_GETFL) | O_NONBLOCK) == 0 else {
                Darwin.close(opened)
                return false
            }
            descriptor = opened
            partial.removeAll()
            let source = DispatchSource.makeReadSource(fileDescriptor: opened, queue: queue)
            source.setEventHandler { [weak self] in self?.readFrames(from: opened, epoch: epoch) }
            source.setCancelHandler { Darwin.close(opened) }
            reader = source
            source.resume()
            return true
        }
        guard let connected else { return }
        connectionChanged(connected)
        if !connected { retry(epoch: epoch) }
    }

    /// The connection ended without a stop: report it and connect again.
    private func lost(epoch: UInt64) {
        guard lock.withLock({ running && generation == epoch }) else { return }
        connectionChanged(false)
        retry(epoch: epoch)
    }

    private func retry(epoch: UInt64) {
        queue.asyncAfter(deadline: .now() + retryDelay) { [self] in connect(epoch: epoch) }
    }

    /// The guest's frames. An end of stream or a frame the receiver cannot
    /// read drops the connection.
    private func readFrames(from descriptor: Int32, epoch: UInt64) {
        var buffer = [UInt8](repeating: 0, count: max(frameSize, 64))
        let count = recv(descriptor, &buffer, buffer.count, MSG_DONTWAIT)
        if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
        var frames: [Data] = []
        var dropped = lock.withLock { () -> Bool in
            guard running, generation == epoch, self.descriptor == descriptor else { return false }
            guard count > 0 else { return closeStream() }
            partial.append(contentsOf: buffer.prefix(count))
            while partial.count >= frameSize {
                frames.append(Data(partial.prefix(frameSize)))
                partial.removeFirst(frameSize)
            }
            return false
        }
        for frame in frames where !dropped {
            guard !received(frame) else { continue }
            dropped = lock.withLock {
                running && generation == epoch && self.descriptor == descriptor && closeStream()
            }
        }
        if dropped { lost(epoch: epoch) }
    }
}
