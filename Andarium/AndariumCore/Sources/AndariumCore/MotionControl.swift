// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// What the guest's sensor service tells the host over the motion connection:
/// which of the sensors an application has active, and the sampling period
/// each asked for. The service sends one frame when the host connects and
/// another at every change; the host reads only the frame and never replies.
///
/// A frame is 16 bytes, little endian: "ANC2", a uint32 mask of the active
/// sensors (bit 0 accelerometer, bit 1 gyroscope, bit 2 magnetometer, bit 3
/// barometer), then each sensor's sampling period as a uint16 in units of 100
/// microseconds, in that order. The service of an earlier image sends "ANC1":
/// the first two sensors alone, with uint32 periods in microseconds. A period
/// outside 10 ms to 1 s is brought into it, and the period of a sensor that is
/// not active is not read. A frame with another magic or a reserved mask bit
/// is a protocol error.
public struct MotionDemand: Equatable, Sendable {
    public static let frameSize = 16
    public static let minimumPeriod: UInt32 = 10_000
    public static let maximumPeriod: UInt32 = 1_000_000

    /// The requested sampling period of each sensor an application has
    /// active, in microseconds; nil for a sensor nobody uses.
    public var accelerometer: UInt32?
    public var gyroscope: UInt32?
    public var magnetometer: UInt32?
    public var barometer: UInt32?

    public init(
        accelerometer: UInt32? = nil, gyroscope: UInt32? = nil,
        magnetometer: UInt32? = nil, barometer: UInt32? = nil
    ) {
        self.accelerometer = accelerometer.map(Self.clamped)
        self.gyroscope = gyroscope.map(Self.clamped)
        self.magnetometer = magnetometer.map(Self.clamped)
        self.barometer = barometer.map(Self.clamped)
    }

    /// Nothing asks for a sensor.
    public var isIdle: Bool { MotionSample.Sensor.allCases.allSatisfy { period(of: $0) == nil } }

    public func period(of sensor: MotionSample.Sensor) -> UInt32? {
        switch sensor {
        case .accelerometer: accelerometer
        case .gyroscope: gyroscope
        case .magnetometer: magnetometer
        case .barometer: barometer
        }
    }

    public init?(frame: Data) {
        guard frame.count == Self.frameSize else { return nil }
        let bytes = [UInt8](frame)
        guard bytes[0] == 0x41, bytes[1] == 0x4e, bytes[2] == 0x43 else { return nil }
        func word(_ offset: Int, bytes count: Int = 4) -> UInt32 {
            (0..<count).reduce(0) { $0 | UInt32(bytes[offset + $1]) << UInt32(8 * $1) }
        }
        let mask = word(4)
        switch bytes[3] {
        case 0x31:
            guard mask & ~0b11 == 0 else { return nil }
            self.init(
                accelerometer: mask & 1 != 0 ? word(8) : nil,
                gyroscope: mask & 2 != 0 ? word(12) : nil
            )
        case 0x32:
            guard mask & ~0b1111 == 0 else { return nil }
            func period(_ index: Int) -> UInt32? {
                mask & (1 << UInt32(index)) != 0 ? word(8 + index * 2, bytes: 2) * 100 : nil
            }
            self.init(
                accelerometer: period(0), gyroscope: period(1),
                magnetometer: period(2), barometer: period(3)
            )
        default:
            return nil
        }
    }

    private static func clamped(_ period: UInt32) -> UInt32 {
        min(max(period, minimumPeriod), maximumPeriod)
    }
}

/// How often each sensor of the device is read, in seconds; nil leaves it off.
public struct MotionPlan: Equatable, Sendable {
    public var accelerometer: TimeInterval?
    public var gyroscope: TimeInterval?
    public var magnetometer: TimeInterval?
    public var barometer: TimeInterval?

    public init(
        accelerometer: TimeInterval? = nil, gyroscope: TimeInterval? = nil,
        magnetometer: TimeInterval? = nil, barometer: TimeInterval? = nil
    ) {
        self.accelerometer = accelerometer
        self.gyroscope = gyroscope
        self.magnetometer = magnetometer
        self.barometer = barometer
    }

    public static let off = MotionPlan()

    public func interval(of sensor: MotionSample.Sensor) -> TimeInterval? {
        switch sensor {
        case .accelerometer: accelerometer
        case .gyroscope: gyroscope
        case .magnetometer: magnetometer
        case .barometer: barometer
        }
    }

    public mutating func set(_ interval: TimeInterval?, of sensor: MotionSample.Sensor) {
        switch sensor {
        case .accelerometer: accelerometer = interval
        case .gyroscope: gyroscope = interval
        case .magnetometer: magnetometer = interval
        case .barometer: barometer = interval
        }
    }
}

/// When the device's sensors are read, and how often.
///
/// The host reads a sensor only while the person's switch is on, the guest is
/// in the foreground, the guest's sensor service is connected and an
/// application in the guest has the sensor active. The connection itself is
/// held while the first two are true, even when nothing is active, because
/// the guest says what it needs over it.
///
/// A guest image whose service never sends a frame (the one before the
/// service learned to) is served as it always was: until a frame arrives,
/// the accelerometer and the gyroscope, the two sensors it has, are read
/// continuously at 100 Hz. A lost connection forgets what the last service
/// said, since the next connection may be to another.
public struct MotionSampling: Equatable, Sendable {
    /// The continuous rate of a service that does not say what it needs.
    public static let legacyInterval: TimeInterval = 0.01
    /// The host reads a sensor this many times per requested period, so the
    /// guest's own pacing, not the timing of the host's readings, sets the
    /// rate applications see.
    public static let oversample = 2.0

    /// The person's switch is on and the device has the sensors.
    public var enabled = false
    /// The guest runs a normal boot, in front, and has settled its rotation.
    public var foreground = false
    public private(set) var connected = false
    /// What the service last said; nil until it says anything.
    public private(set) var demand: MotionDemand?

    public init() {}

    /// The connection to the service is wanted.
    public var wantsConnection: Bool { enabled && foreground }

    public mutating func connectionChanged(_ connected: Bool) {
        self.connected = connected
        demand = nil
    }

    public mutating func received(_ demand: MotionDemand) {
        self.demand = demand
    }

    public var plan: MotionPlan {
        guard wantsConnection, connected else { return .off }
        guard let demand else {
            return MotionPlan(accelerometer: Self.legacyInterval, gyroscope: Self.legacyInterval)
        }
        return MotionPlan(
            accelerometer: demand.accelerometer.map(Self.interval(forPeriod:)),
            gyroscope: demand.gyroscope.map(Self.interval(forPeriod:)),
            magnetometer: demand.magnetometer.map(Self.interval(forPeriod:)),
            barometer: demand.barometer.map(Self.interval(forPeriod:))
        )
    }

    /// The reading interval for a requested period in microseconds.
    public static func interval(forPeriod microseconds: UInt32) -> TimeInterval {
        max(legacyInterval, Double(microseconds) / 1_000_000 / oversample)
    }
}
