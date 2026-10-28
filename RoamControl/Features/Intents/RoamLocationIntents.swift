import AppIntents
import CoreLocation
import Foundation

// MARK: - Errors

/// Surfaces a readable message in Shortcuts instead of a generic "couldn't run" banner.
enum RoamIntentError: Error, CustomLocalizedStringResourceConvertible {
    case message(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .message(let text):
            return "\(text)"
        }
    }
}

// MARK: - Shared Helpers

@MainActor
enum RoamIntentSupport {
    /// Opens a device session for `target` and waits until the tunnel is active.
    ///
    /// `target` is the map-facing (GCJ-02) coordinate. GCJ-02 → WGS-84 correction happens inside
    /// `LocalDeviceSessionCoordinator`, so callers must not convert beforehand.
    static func startSession(
        for target: LocationTarget,
        enableJitter: Bool
    ) async throws -> LocalDeviceSessionCoordinator {
        guard let pairingRecord = try await SecurePairingService().pairingRecordData() else {
            throw RoamIntentError.message(
                "No pairing record found. Please pair this device in Roam Control first."
            )
        }

        let coordinator = LocalDeviceSessionCoordinator()
        coordinator.start(pairingRecord: pairingRecord, target: target, enableJitter: enableJitter)

        // The background intent cannot bring up LocalDevVPN by itself, so give the tunnel up to
        // 15 seconds before reporting a connection problem.
        do {
            for _ in 0..<60 {
                try await Task.sleep(for: .milliseconds(250))
                switch coordinator.phase {
                case .active:
                    return coordinator
                case .failed(let message):
                    throw RoamIntentError.message(message)
                default:
                    continue
                }
            }
        } catch {
            coordinator.stop()
            throw error
        }

        coordinator.stop()
        throw RoamIntentError.message(
            "Connection timed out. Turn on LocalDevVPN first, then run this shortcut again."
        )
    }

    /// Waits for a stopping session to settle. Returns the failure message, or `nil` on success.
    static func settle(_ coordinator: LocalDeviceSessionCoordinator, timeout: Duration) async -> String? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(150))
            switch coordinator.phase {
            case .idle:
                return nil
            case .failed(let message):
                return message
            default:
                continue
            }
        }
        return "The session did not finish in time."
    }

    static func storedTarget(forKey key: String, in preferences: UserDefaults) -> LocationTarget? {
        guard let data = preferences.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(LocationTarget.self, from: data)
    }

    static func store(_ target: LocationTarget, forKey key: String, in preferences: UserDefaults) {
        if let data = try? JSONEncoder().encode(target) {
            preferences.set(data, forKey: key)
        }
    }
}

// MARK: - App Entity for Saved Places

struct SavedLocationEntity: AppEntity, Identifiable, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Saved Place"
    static let defaultQuery = SavedLocationQuery()

    var id: String
    var name: String
    var subtitle: String
    var latitude: Double
    var longitude: Double

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: subtitle.isEmpty ? "\(latitude), \(longitude)" : "\(subtitle)"
        )
    }
}

struct SavedLocationQuery: EntityQuery, Sendable {
    func entities(for identifiers: [String]) async throws -> [SavedLocationEntity] {
        let all = await suggestedEntities()
        return all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async -> [SavedLocationEntity] {
        let prefs = UserDefaults.standard
        guard
            let data = prefs.data(forKey: "favouriteLocations"),
            let locations = try? JSONDecoder().decode([LocationTarget].self, from: data)
        else {
            return []
        }

        return locations.map {
            SavedLocationEntity(
                id: $0.id,
                name: $0.name,
                subtitle: $0.subtitle,
                latitude: $0.latitude,
                longitude: $0.longitude
            )
        }
    }
}

// MARK: - Simulate Location Intent

struct SimulateLocationIntent: AppIntent {
    static let title: LocalizedStringResource = "Simulate Location"
    static let description = IntentDescription(
        "Simulate a custom GPS location or a saved place with auto GCJ-02 correction, micro-jitter, and silent detachment."
    )
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Saved Place", description: "Select from your saved favourites")
    var savedPlace: SavedLocationEntity?

    @Parameter(title: "Latitude", description: "Target latitude (-90.0 to 90.0)")
    var latitude: Double?

    @Parameter(title: "Longitude", description: "Target longitude (-180.0 to 180.0)")
    var longitude: Double?

    @Parameter(title: "Location Name", default: "Custom Location")
    var locationName: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let prefs = UserDefaults.standard

        // 1. Resolve the map-facing (GCJ-02) target: saved place > explicit coordinate > last used.
        let requested: LocationTarget
        if let saved = savedPlace {
            requested = LocationTarget(
                name: saved.name,
                subtitle: saved.subtitle,
                latitude: saved.latitude,
                longitude: saved.longitude
            )
        } else if let lat = latitude, let lon = longitude {
            requested = LocationTarget(
                name: locationName,
                subtitle: "Simulated via Shortcut",
                latitude: lat,
                longitude: lon
            )
        } else if let last = RoamIntentSupport.storedTarget(
            forKey: RoamPreferenceKeys.lastUsedLocation,
            in: prefs
        ) {
            requested = last
        } else {
            throw RoamIntentError.message(
                "Please choose a saved place or enter both latitude and longitude."
            )
        }

        guard requested.latitude.isFinite, requested.longitude.isFinite,
              (-90.0...90.0).contains(requested.latitude),
              (-180.0...180.0).contains(requested.longitude)
        else {
            throw RoamIntentError.message(
                "Invalid coordinates (\(requested.latitude), \(requested.longitude))."
            )
        }

        // 2. Connect. The coordinator applies GCJ-02 → WGS-84 correction and the jitter frames.
        let jitter = prefs.object(forKey: RoamPreferenceKeys.enableLocationJitter) as? Bool ?? true
        let coordinator = try await RoamIntentSupport.startSession(for: requested, enableJitter: jitter)

        // 3. Let the micro-jitter warm-up write its final frame.
        await coordinator.waitForJitterToFinish()

        // 4. Confirm with CoreLocation against the WGS-84 value that was really sent.
        if let sent = coordinator.lastSentDeviceCoordinate {
            let verifier = LocationInjectionVerifier()
            switch await verifier.verify(near: sent) {
            case .confirmed:
                break
            case .mismatch(let distance):
                coordinator.stop()
                throw RoamIntentError.message(
                    "The system location is still \(Int(distance)) m away from the target, so the lock was cancelled."
                )
            case .unavailable:
                // Location access is off, so give locationd a moment instead.
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }

        // 5. Lock & Detach. This never sends a clear/stop command.
        guard coordinator.detach() else {
            coordinator.stop()
            throw RoamIntentError.message("The session ended before the location could be locked.")
        }
        if let failure = await RoamIntentSupport.settle(coordinator, timeout: .seconds(6)) {
            throw RoamIntentError.message(failure)
        }

        // 6. Persist for the app UI, the next shortcut run and the restore intent.
        prefs.set(true, forKey: RoamPreferenceKeys.isLocationLockedAndDetached)
        RoamIntentSupport.store(requested, forKey: RoamPreferenceKeys.lastLockedLocation, in: prefs)
        RoamIntentSupport.store(requested, forKey: RoamPreferenceKeys.lastUsedLocation, in: prefs)

        return .result(
            dialog: IntentDialog("Location locked at \(requested.name). It is safe to turn off LocalDevVPN now.")
        )
    }
}

// MARK: - Stop Simulation Intent

struct StopLocationSimulationIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Location Simulation"
    static let description = IntentDescription(
        "Stop location simulation and restore this iPhone's real GPS position."
    )
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let prefs = UserDefaults.standard

        // A detached lock can only be cleared by reconnecting, so reconnect at the held location
        // (no jitter) and immediately ask the device to clear it.
        guard let anchor = RoamIntentSupport.storedTarget(
            forKey: RoamPreferenceKeys.lastLockedLocation,
            in: prefs
        ) ?? RoamIntentSupport.storedTarget(forKey: RoamPreferenceKeys.lastUsedLocation, in: prefs) else {
            throw RoamIntentError.message("No simulated location is recorded, so there is nothing to restore.")
        }

        let coordinator = try await RoamIntentSupport.startSession(for: anchor, enableJitter: false)
        coordinator.stop()

        // Keep the lock flag until the device really confirmed the clear.
        if let failure = await RoamIntentSupport.settle(coordinator, timeout: .seconds(10)) {
            throw RoamIntentError.message(failure)
        }
        prefs.set(false, forKey: RoamPreferenceKeys.isLocationLockedAndDetached)

        return .result(
            dialog: IntentDialog("Location simulation stopped. The real location will be restored shortly.")
        )
    }
}

// MARK: - Shortcuts Provider

struct RoamShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SimulateLocationIntent(),
            phrases: [
                "Simulate location with \(.applicationName)",
                "Lock location with \(.applicationName)"
            ],
            shortTitle: "Simulate Location",
            systemImageName: "location.fill"
        )
        AppShortcut(
            intent: StopLocationSimulationIntent(),
            phrases: [
                "Stop simulation with \(.applicationName)",
                "Restore real location with \(.applicationName)"
            ],
            shortTitle: "Restore Real Location",
            systemImageName: "lock.slash.fill"
        )
    }
}
