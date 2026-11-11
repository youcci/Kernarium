// SPDX-License-Identifier: GPL-2.0-or-later

import Darwin
import Foundation
import Testing
@testable import AndariumCore

struct VibrationTests {
    /// Independent wire fixture: on for 250 ms at half amplitude.
    private let frame = Data([0x41, 0x4e, 0x56, 0x31, 0xfa, 0, 0, 0, 0, 0, 0, 0x3f])

    @Test func aFrameSaysHowLongAndHowStrong() throws {
        let command = try #require(VibrationCommand(frame: frame))
        #expect(command.milliseconds == 250 && command.amplitude == 0.5)
        #expect(command.play == .hold(0.25))
    }

    @Test func aFrameThatIsNotTheProtocolIsRefused() {
        #expect(VibrationCommand(frame: frame.prefix(11)) == nil)
        var other = frame
        other[3] = 0x32
        #expect(VibrationCommand(frame: other) == nil)
        // Amplitudes of 0, above 1 and NaN are never sent.
        for amplitude in [Float(0), 1.5, .nan, -0.5] {
            var bad = frame
            withUnsafeBytes(of: amplitude.bitPattern.littleEndian) { bad.replaceSubrange(8..<12, with: $0) }
            #expect(VibrationCommand(frame: bad) == nil)
        }
    }

    @Test func theEnginePlaysAStopATapOrABoundedHold() throws {
        func play(_ milliseconds: UInt32) throws -> VibrationCommand.Play {
            var data = frame
            withUnsafeBytes(of: milliseconds.littleEndian) { data.replaceSubrange(4..<8, with: $0) }
            return try #require(VibrationCommand(frame: data)).play
        }
        #expect(try play(0) == .stop)
        #expect(try play(10) == .tap)
        #expect(try play(40) == .hold(0.04))
        #expect(try play(120_000) == .hold(30))
    }
}

/// `GuestFrameStream` against a socket pair standing in for the guest.
struct GuestFrameStreamTests {
    private final class Opener: GuestStreamOpener, @unchecked Sendable {
        private let lock = NSLock()
        private var descriptors: [Int32]
        init(_ descriptors: [Int32]) { self.descriptors = descriptors }
        func openStream() throws -> Int32 {
            try lock.withLock {
                guard !descriptors.isEmpty else { throw POSIXError(.ECONNREFUSED) }
                return descriptors.removeFirst()
            }
        }
    }

    private final class Log: @unchecked Sendable {
        private let condition = NSCondition()
        private var frames: [Data] = []
        private var connections: [Bool] = []
        func add(_ frame: Data) { condition.withLock { frames.append(frame); condition.broadcast() } }
        func add(_ connected: Bool) { condition.withLock { connections.append(connected); condition.broadcast() } }
        func wait(frames count: Int) -> [Data] {
            condition.withLock {
                let deadline = Date().addingTimeInterval(3)
                while frames.count < count, condition.wait(until: deadline) {}
                return frames
            }
        }
        func wait(connections count: Int) -> [Bool] {
            condition.withLock {
                let deadline = Date().addingTimeInterval(3)
                while connections.count < count, condition.wait(until: deadline) {}
                return connections
            }
        }
    }

    private func pair() throws -> [Int32] {
        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else { throw POSIXError(.EIO) }
        return sockets
    }

    @Test func framesArriveWholeAndABadOneReconnects() throws {
        let first = try pair(), second = try pair()
        defer { close(first[1]); close(second[1]) }
        let log = Log()
        let stream = GuestFrameStream(
            opener: Opener([first[0], second[0]]), frameSize: 4, retryDelay: .milliseconds(10),
            connectionChanged: { log.add($0) },
            received: { frame in
                log.add(frame)
                return frame != Data("bad!".utf8)
            })
        stream.start()
        defer { stream.stop() }
        #expect(log.wait(connections: 1) == [true])
        // One frame split over two writes, then one and a half more.
        _ = Data("ab".utf8).withUnsafeBytes { write(first[1], $0.baseAddress, $0.count) }
        _ = Data("cdefghij".utf8).withUnsafeBytes { write(first[1], $0.baseAddress, $0.count) }
        #expect(log.wait(frames: 2) == [Data("abcd".utf8), Data("efgh".utf8)])
        // A frame the receiver cannot read drops the connection; the next
        // starts with no remainder of the old one.
        _ = Data("klbad!".utf8).withUnsafeBytes { write(first[1], $0.baseAddress, $0.count) }
        #expect(log.wait(connections: 3) == [true, false, true])
        _ = Data("wxyz".utf8).withUnsafeBytes { write(second[1], $0.baseAddress, $0.count) }
        #expect(log.wait(frames: 5).last == Data("wxyz".utf8))
        // And the host's frames reach the guest on the live connection.
        stream.send(Data("pong".utf8))
        var answer = [UInt8](repeating: 0, count: 4)
        var descriptor = pollfd(fd: second[1], events: Int16(POLLIN), revents: 0)
        #expect(poll(&descriptor, 1, 2000) > 0)
        #expect(recv(second[1], &answer, 4, MSG_DONTWAIT) == 4 && answer == Array("pong".utf8))
    }

    @Test func aFrameLargerThanTheBufferWaitsForAGuestThatReads() throws {
        let first = try pair(), second = try pair()
        defer { close(first[1]); close(second[1]) }
        let log = Log()
        let stream = GuestFrameStream(
            opener: Opener([first[0], second[0]]), frameSize: 4, retryDelay: .milliseconds(10),
            connectionChanged: { log.add($0) }, received: { _ in true })
        stream.start()
        defer { stream.stop() }
        #expect(log.wait(connections: 1) == [true])
        let large = Data((0..<1_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        // A guest that reads gets all of it within the sender's patience.
        let guest = first[1]
        let reader = Thread {
            var taken = Data(), buffer = [UInt8](repeating: 0, count: 65536)
            while taken.count < large.count {
                let count = read(guest, &buffer, buffer.count)
                guard count > 0 else { break }
                taken.append(contentsOf: buffer.prefix(count))
            }
            log.add(taken)
        }
        reader.start()
        stream.send(large, patience: 3000)
        #expect(log.wait(frames: 1) == [large])
        #expect(log.wait(connections: 1) == [true])
        // Without patience, what the buffer does not take at once ends the
        // connection.
        stream.send(large)
        #expect(log.wait(connections: 3) == [true, false, true])
    }

    @Test func aStopClosesTheConnectionAndSendsNothingAfter() throws {
        let sockets = try pair()
        defer { close(sockets[1]) }
        let log = Log()
        let stream = GuestFrameStream(
            opener: Opener([sockets[0]]), frameSize: 4,
            connectionChanged: { log.add($0) }, received: { _ in true })
        stream.start()
        #expect(log.wait(connections: 1) == [true])
        stream.stop()
        stream.send(Data("late".utf8))
        var descriptor = pollfd(fd: sockets[1], events: Int16(POLLIN), revents: 0)
        #expect(poll(&descriptor, 1, 2000) > 0)
        var byte: UInt8 = 0
        #expect(recv(sockets[1], &byte, 1, MSG_DONTWAIT) == 0)
    }
}
