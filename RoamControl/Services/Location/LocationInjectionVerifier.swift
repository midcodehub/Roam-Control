import CoreLocation
import Foundation

/// Confirms that an injected coordinate has really reached `locationd` by asking CoreLocation
/// where the system now thinks the device is.
///
/// CoreLocation reports WGS-84, so callers must compare against the coordinate that was sent to
/// the device (after any GCJ-02 correction), not against the pin shown on the map.
@MainActor
final class LocationInjectionVerifier: NSObject, CLLocationManagerDelegate {
    enum Outcome: Equatable {
        /// A fresh system fix lies within the tolerance of the target.
        case confirmed(distance: CLLocationDistance)
        /// Fixes arrived but none came within tolerance before the timeout.
        case mismatch(distance: CLLocationDistance)
        /// Location access is not granted or no fix arrived, so nothing could be checked.
        case unavailable
    }

    private let manager = CLLocationManager()
    private var latestFix: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    var canVerify: Bool {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            true
        default:
            false
        }
    }

    /// Polls CoreLocation until a fix lands within `tolerance` of `target`, or `timeout` passes.
    func verify(
        near target: CLLocationCoordinate2D,
        tolerance: CLLocationDistance = 50,
        timeout: Duration = .seconds(3)
    ) async -> Outcome {
        guard canVerify else { return .unavailable }

        latestFix = nil
        manager.startUpdatingLocation()
        defer { manager.stopUpdatingLocation() }

        let reference = CLLocation(latitude: target.latitude, longitude: target.longitude)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var closestDistance: CLLocationDistance?

        while clock.now < deadline {
            if let fix = latestFix {
                let distance = fix.distance(from: reference)
                closestDistance = distance
                if distance <= tolerance {
                    return .confirmed(distance: distance)
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                break
            }
        }

        if let closestDistance {
            return .mismatch(distance: closestDistance)
        }
        return .unavailable
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let fix = locations.last else { return }
        Task { @MainActor [weak self] in
            self?.latestFix = fix
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A transient failure simply leaves the verifier without a fix; the caller falls back.
    }
}
