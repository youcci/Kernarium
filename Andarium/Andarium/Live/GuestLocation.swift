// SPDX-License-Identifier: GPL-2.0-or-later

import AndariumCore
import CoreLocation
import Foundation

private nonisolated struct LocationConnector: GuestStreamOpener {
    func openStream() throws -> Int32 {
        let descriptor = kernarium_runtime_loader_connect_vsock(LocationFix.port, 250)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: -descriptor) ?? .EIO) }
        return descriptor
    }
}

/// The device's location for the running guest. The connection to the
/// guest's GNSS HAL is held while the guest is booted and in front; Core
/// Location runs only while the HAL says Android's location framework wants
/// fixes (`LocationSharing`), and iOS asks the person the first time that
/// happens. Without permission the guest gets no fixes.
@MainActor
final class GuestLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var sharing = LocationSharing()
    private var locating = false
    private lazy var stream = GuestFrameStream(
        // An image without the HAL is asked again at this pace for as long as
        // it is in front.
        opener: LocationConnector(), frameSize: LocationDemand.frameSize, retryDelay: .seconds(5),
        connectionChanged: { [weak self] connected in
            // The next connection starts from what the HAL says on it.
            if !connected { DispatchQueue.main.async { self?.demand(false) } }
        },
        received: { [weak self] frame in
            guard let wanted = LocationDemand.wanted(frame: frame) else { return false }
            // The main queue keeps the frames in the order they arrived.
            DispatchQueue.main.async { self?.demand(wanted) }
            return true
        })

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        sharing.authorization = Self.authorization(manager.authorizationStatus)
    }

    func update(foreground: Bool) {
        sharing.foreground = foreground
        if foreground {
            stream.start()
        } else {
            stream.stop()
            sharing.wanted = false
        }
        reconcile()
    }

    private func demand(_ wanted: Bool) {
        sharing.wanted = wanted && sharing.foreground
        reconcile()
    }

    private func reconcile() {
        let action = sharing.action
        if action == .ask { manager.requestWhenInUseAuthorization() }
        guard (action == .locate) != locating else { return }
        locating = action == .locate
        if locating { manager.startUpdatingLocation() } else { manager.stopUpdatingLocation() }
    }

    private static func authorization(_ status: CLAuthorizationStatus) -> LocationSharing.Authorization {
        switch status {
        case .notDetermined: .undetermined
        case .authorizedAlways, .authorizedWhenInUse: .allowed
        default: .refused
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        sharing.authorization = Self.authorization(manager.authorizationStatus)
        reconcile()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard locating else { return }
        for location in locations {
            let fix = LocationFix(
                latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                horizontalAccuracy: location.horizontalAccuracy,
                // Android's altitude is the height above the WGS 84 ellipsoid.
                altitude: location.ellipsoidalAltitude, verticalAccuracy: location.verticalAccuracy,
                speed: location.speed, speedAccuracy: location.speedAccuracy,
                course: location.course, courseAccuracy: location.courseAccuracy,
                time: location.timestamp)
            if let frame = fix?.encoded { stream.send(frame) }
        }
    }

    /// Core Location keeps trying after a failure to locate, and a refusal
    /// arrives as a change of authorization.
    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {}
}
