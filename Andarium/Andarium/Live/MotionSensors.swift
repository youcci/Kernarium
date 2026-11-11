// SPDX-License-Identifier: GPL-2.0-or-later

import AndariumCore
import CoreMotion
import Foundation

private nonisolated struct MotionConnector: GuestStreamOpener {
    func openStream() throws -> Int32 {
        let descriptor = kernarium_runtime_loader_connect_vsock(MotionStream.port, 250)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: -descriptor) ?? .EIO) }
        return descriptor
    }
}

/// The device's accelerometer, gyroscope, compass and barometer. Core Motion
/// needs no iOS permission for the first three; iOS asks for Motion & Fitness
/// access the first time the barometer is read, and without it the barometer
/// delivers nothing.
private final class CoreMotionDevice: MotionDevice, @unchecked Sendable {
    private let manager = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "andarium-motion"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    var hasAccelerometer: Bool { manager.isAccelerometerAvailable }
    var hasGyroscope: Bool { manager.isGyroAvailable }
    /// The calibrated magnetic field comes with device motion in a frame
    /// that uses the compass.
    var hasMagnetometer: Bool {
        manager.isDeviceMotionAvailable
            && CMMotionManager.availableAttitudeReferenceFrames().contains(.xMagneticNorthZVertical)
    }
    var hasBarometer: Bool { CMAltimeter.isRelativeAltitudeAvailable() }

    func start(
        _ sensor: MotionSample.Sensor, interval: TimeInterval,
        handler: @escaping @Sendable (Double, Double, Double) -> Void,
        failure: @escaping @Sendable () -> Void
    ) {
        stop(sensor)
        switch sensor {
        case .accelerometer:
            guard manager.isAccelerometerAvailable else { return }
            manager.accelerometerUpdateInterval = interval
            manager.startAccelerometerUpdates(to: queue) { data, error in
                if error != nil { failure() }
                guard let a = data?.acceleration else { return }
                handler(a.x, a.y, a.z)
            }
        case .gyroscope:
            guard manager.isGyroAvailable else { return }
            manager.gyroUpdateInterval = interval
            manager.startGyroUpdates(to: queue) { data, error in
                if error != nil { failure() }
                guard let g = data?.rotationRate else { return }
                handler(g.x, g.y, g.z)
            }
        case .magnetometer:
            guard hasMagnetometer else { return }
            manager.deviceMotionUpdateInterval = interval
            manager.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: queue) { motion, _ in
                // Until the compass is calibrated the field is not known.
                guard let field = motion?.magneticField, field.accuracy != .uncalibrated else { return }
                handler(field.field.x, field.field.y, field.field.z)
            }
        case .barometer:
            // The altimeter reports about once a second, at no rate it can be set to.
            guard hasBarometer else { return }
            altimeter.startRelativeAltitudeUpdates(to: queue) { data, _ in
                // Core Motion reports kilopascals; Android's unit is the hectopascal.
                guard let pressure = data?.pressure.doubleValue else { return }
                handler(pressure * 10, 0, 0)
            }
        }
    }

    func stop(_ sensor: MotionSample.Sensor) {
        switch sensor {
        case .accelerometer: manager.stopAccelerometerUpdates()
        case .gyroscope: manager.stopGyroUpdates()
        case .magnetometer: manager.stopDeviceMotionUpdates()
        case .barometer: altimeter.stopRelativeAltitudeUpdates()
        }
    }
}

/// The device's motion, compass and barometer for the running guest. Core
/// Motion runs only for an enabled, booted, foreground guest, and then only
/// for the sensors an
/// application in the guest has active (`MotionSession`). The axes are set
/// when a run begins and never change per sample (`MotionMount` decides when
/// they move). No samples are retained across backgrounding, power-off, or a
/// guest restart.
@MainActor
final class MotionSensors {
    private let device = CoreMotionDevice()
    private lazy var session = MotionSession(opener: MotionConnector(), device: device) { [weak self] problem in
        let text: String? = switch problem {
        case nil: nil
        case .guestUnavailable?:
            "The guest’s motion sensor service is unavailable. Use a system image with motion sensor support."
        case .deviceFailed?:
            "The device’s motion sensors could not be read. Turn Gyroscope off and on to try again."
        }
        Task { @MainActor [weak self] in self?.problem?(text) }
    }
    var problem: ((String?) -> Void)?
    private var axes = MotionSample.Axes.portrait

    var available: Bool { device.hasAccelerometer || device.hasGyroscope }

    /// What is wanted now: the person's switch, the guest being in front, and
    /// the axes the sensors are mounted to.
    func update(enabled: Bool, foreground: Bool, axes: MotionSample.Axes) {
        self.axes = axes
        session.update(enabled: enabled, foreground: foreground, axes: axes)
    }

    /// The period the readings belong to is over (the mount or the rotation
    /// policy changed); the next update begins a new run.
    func restart() { session.restart() }

    func stop() { session.update(enabled: false, foreground: false, axes: axes) }
}
