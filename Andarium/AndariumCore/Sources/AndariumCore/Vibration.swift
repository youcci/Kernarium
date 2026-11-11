// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// What the guest's vibrator HAL tells the host on private vsock port 5557,
/// on the connection the host made, whenever what the vibrator does changes.
/// A frame is 12 bytes, little endian: "ANV1", the uint32 time in
/// milliseconds the vibrator stays on from now (0 turns it off), then the
/// IEEE float32 amplitude in (0, 1]. A later frame replaces an earlier one. A
/// frame with another magic or amplitude is a protocol error.
public struct VibrationCommand: Equatable, Sendable {
    public static let port: UInt32 = 5557
    public static let frameSize = 12
    /// A vibration shorter than this is one tap of the haptic engine: a
    /// continuous event of a few milliseconds is too weak to feel.
    public static let tapBelowMilliseconds: UInt32 = 40
    /// The longest continuous event Core Haptics plays.
    public static let longestPlay: TimeInterval = 30

    public let milliseconds: UInt32
    public let amplitude: Float

    public init?(frame: Data) {
        guard frame.count == Self.frameSize else { return nil }
        let bytes = [UInt8](frame)
        guard bytes[0] == 0x41, bytes[1] == 0x4e, bytes[2] == 0x56, bytes[3] == 0x31 else { return nil }
        func word(_ offset: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << UInt32(8 * $1) }
        }
        let amplitude = Float(bitPattern: word(8))
        guard amplitude > 0, amplitude <= 1 else { return nil }
        milliseconds = word(4)
        self.amplitude = amplitude
    }

    /// What the haptic engine plays for the command.
    public enum Play: Equatable, Sendable {
        case stop
        case tap
        /// A continuous vibration of this many seconds.
        case hold(TimeInterval)
    }

    public var play: Play {
        if milliseconds == 0 { return .stop }
        if milliseconds < Self.tapBelowMilliseconds { return .tap }
        return .hold(min(Double(milliseconds) / 1000, Self.longestPlay))
    }
}
