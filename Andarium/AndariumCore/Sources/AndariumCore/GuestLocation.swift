// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// A position of the host's location service, as the guest's GNSS HAL takes
/// it on private vsock port 5558. A fix is 88 bytes, little endian: "ANL1"; a
/// uint32 of flags for the values that follow (0x01 latitude and longitude,
/// 0x02 altitude, 0x04 speed, 0x08 bearing, 0x10 horizontal accuracy, 0x20
/// vertical accuracy, 0x40 speed accuracy, 0x80 bearing accuracy); nine IEEE
/// float64 in that order (degrees, degrees, metres above the WGS 84
/// ellipsoid, metres per second, degrees, metres, metres, metres per second,
/// degrees); then the int64 time of the fix in milliseconds since the Unix
/// epoch. A value whose flag is clear is sent as zero and not read. The guest
/// answers on the same connection with `LocationDemand` frames.
public struct LocationFix: Equatable, Sendable {
    public static let port: UInt32 = 5558
    public static let frameSize = 88

    public var latitude: Double
    public var longitude: Double
    public var altitude: Double?
    public var speed: Double?
    public var bearing: Double?
    public var horizontalAccuracy: Double
    public var verticalAccuracy: Double?
    public var speedAccuracy: Double?
    public var bearingAccuracy: Double?
    public var time: Date

    /// From Core Location's values, where a negative accuracy, speed or course
    /// says that the value it belongs to is not known. A location without a
    /// horizontal accuracy has no position, and is no fix.
    public init?(
        latitude: Double, longitude: Double, horizontalAccuracy: Double,
        altitude: Double, verticalAccuracy: Double,
        speed: Double, speedAccuracy: Double,
        course: Double, courseAccuracy: Double, time: Date
    ) {
        guard horizontalAccuracy >= 0 else { return nil }
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        if verticalAccuracy >= 0 {
            self.altitude = altitude
            self.verticalAccuracy = verticalAccuracy
        }
        if speed >= 0 {
            self.speed = speed
            self.speedAccuracy = speedAccuracy >= 0 ? speedAccuracy : nil
        }
        if course >= 0 {
            bearing = course
            bearingAccuracy = courseAccuracy >= 0 ? courseAccuracy : nil
        }
        self.time = time
    }

    /// The frame, or nil for a fix the protocol cannot say: a position off the
    /// globe, a value that is not finite, or a time before the epoch.
    public var encoded: Data? {
        let values = [latitude, longitude, altitude, speed, bearing,
                      horizontalAccuracy, verticalAccuracy, speedAccuracy, bearingAccuracy]
        let flags: [UInt32] = [0x01, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80]
        let milliseconds = (time.timeIntervalSince1970 * 1000).rounded()
        guard abs(latitude) <= 90, abs(longitude) <= 180,
              values.allSatisfy({ $0?.isFinite ?? true }),
              milliseconds >= 1, milliseconds < 9e18 else { return nil }
        var data = Data([0x41, 0x4e, 0x4c, 0x31])
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append(zip(values, flags).reduce(UInt32(0)) { $1.0 == nil ? $0 : $0 | $1.1 })
        for value in values { append((value ?? 0).bitPattern) }
        append(Int64(milliseconds))
        return data
    }
}

/// What the guest's GNSS HAL tells the host over the location connection:
/// whether Android's location framework has it started. The HAL sends one
/// frame when the host connects and another at every change. A frame is 8
/// bytes, little endian: "ANG1", then a uint32 that is 1 while the framework
/// wants fixes and 0 while it does not. Another magic or value is a protocol
/// error.
public enum LocationDemand {
    public static let frameSize = 8

    /// Whether the frame says fixes are wanted; nil for a frame that is not
    /// the protocol.
    public static func wanted(frame: Data) -> Bool? {
        switch [UInt8](frame) {
        case [0x41, 0x4e, 0x47, 0x31, 0, 0, 0, 0]: false
        case [0x41, 0x4e, 0x47, 0x31, 1, 0, 0, 0]: true
        default: nil
        }
    }
}

/// When the host's location service runs for the guest: only while the guest
/// is in front and its GNSS HAL says the framework wants fixes, and then only
/// with the person's permission, which is asked for the first time it is
/// needed. A refusal means no fixes; nothing asks again.
public struct LocationSharing: Equatable, Sendable {
    public enum Authorization: Sendable { case undetermined, allowed, refused }
    public enum Action: Equatable, Sendable { case idle, ask, locate }

    /// The guest runs a normal boot, in front.
    public var foreground = false
    /// What the HAL last said; false without a connection to it.
    public var wanted = false
    public var authorization = Authorization.undetermined

    public init() {}

    public var action: Action {
        guard foreground, wanted else { return .idle }
        return switch authorization {
        case .undetermined: .ask
        case .allowed: .locate
        case .refused: .idle
        }
    }
}
