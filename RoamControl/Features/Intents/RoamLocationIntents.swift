import AppIntents
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

/// Shortcuts drive the app's own `AppModel.shared` session instead of opening a private one.
///
/// The DVT location-simulation service only holds the simulated position while its connection
/// stays open, so a shortcut cannot inject a location and then drop the tunnel. Both intents
/// therefore open Roam Control: the session starts in the foreground exactly like the Start
/// button, and the app's background keep-alive holds it after the user switches away.
@MainActor
enum RoamIntentSupport {
    /// Covers the 3 s tunnel pre-check plus a LocalDevVPN round trip when no tunnel is up yet.
    static let sessionTimeout: Duration = .seconds(30)

    /// Loads the pairing status if the app was launched by the shortcut and has not read it yet.
    static func ensurePaired(_ appModel: AppModel) async throws {
        if case .paired = appModel.pairingStatus { return }
        await appModel.restorePairingStatus()
        guard case .paired = appModel.pairingStatus else {
            throw RoamIntentError.message(
                "No pairing record found. Please pair this device in Roam Control first."
            )
        }
    }

    static func isTransitioning(_ phase: DeviceSessionPhase) -> Bool {
        switch phase {
        case .openingLocalDevVPN, .discovering, .connecting, .stopping:
            return true
        case .idle, .active, .failed:
            return false
        }
    }

    /// Polls `condition` until it returns a value or `timeout` passes. Returns `nil` on timeout.
    static func wait<T>(
        timeout: Duration,
        until condition: () throws -> T?
    ) async throws -> T? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let value = try condition() {
                return value
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        return try condition()
    }

    static func storedTarget(forKey key: String, in preferences: UserDefaults) -> LocationTarget? {
        guard let data = preferences.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(LocationTarget.self, from: data)
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
        "Opens Roam Control and simulates a custom GPS location or a saved place, with auto GCJ-02 correction. Keep Roam Control running in the background to hold the location."
    )
    // The session has to start in the foreground so the app can keep it open in the background.
    static let openAppWhenRun: Bool = true

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

        let appModel = AppModel.shared
        let session = appModel.deviceSession
        try await RoamIntentSupport.ensurePaired(appModel)

        // 2. Let a start or stop that is already under way settle; a busy coordinator ignores
        //    a new start, which would otherwise report the previous target as this one.
        _ = try await RoamIntentSupport.wait(timeout: .seconds(15)) {
            RoamIntentSupport.isTransitioning(session.phase) ? nil : true
        }

        // 3. Same path as the Start button: an active session is moved to the new target,
        //    otherwise a new one is opened. Starting also clears any earlier Lock & Detach state.
        //    GCJ-02 → WGS-84 correction and the jitter warm-up happen in the coordinator.
        await appModel.startLocationSession(at: requested)

        let outcome = try await RoamIntentSupport.wait(timeout: RoamIntentSupport.sessionTimeout) {
            () -> Result<Void, RoamIntentError>? in
            switch session.phase {
            case .active:
                return .success(())
            case .failed(let message):
                return .failure(.message(message))
            case .idle:
                // Starting never returns to idle on its own, so this means it was cancelled.
                return .failure(.message("The location session was cancelled."))
            case .openingLocalDevVPN, .discovering, .connecting, .stopping:
                return nil
            }
        }

        switch outcome {
        case .success:
            break
        case .failure(let error):
            throw error
        case nil:
            throw RoamIntentError.message(
                "Connection timed out. Turn on LocalDevVPN (or a proxy app that reflects 10.7.0.1) first, then run this shortcut again."
            )
        }

        // 4. Let the micro-jitter warm-up write its final frame before reporting success.
        await session.waitForJitterToFinish()

        return .result(
            dialog: IntentDialog(
                "Simulating \(requested.name). Keep Roam Control running in the background; closing it from the app switcher restores the real location."
            )
        )
    }
}

// MARK: - Stop Simulation Intent

struct StopLocationSimulationIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Location Simulation"
    static let description = IntentDescription(
        "Opens Roam Control, stops location simulation and restores this iPhone's real GPS position."
    )
    // Restoring an earlier Lock & Detach needs a fresh session, which must start in the foreground.
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let appModel = AppModel.shared
        let session = appModel.deviceSession
        try await RoamIntentSupport.ensurePaired(appModel)

        if case .idle = session.phase, !appModel.isLocationLockedAndDetached {
            return .result(dialog: IntentDialog("No location simulation is running."))
        }

        // Same path as the Stop button: an open session asks the device to clear the simulation;
        // an earlier Lock & Detach (no open session) reconnects first and then clears it.
        let noticeBeforeStop = appModel.detachNotice
        appModel.stopLocationSession()

        let outcome = try await RoamIntentSupport.wait(timeout: RoamIntentSupport.sessionTimeout) {
            () -> Result<Void, RoamIntentError>? in
            if case .failed(let message) = session.phase {
                return .failure(.message(message))
            }
            if appModel.isLocationLockedAndDetached,
               let notice = appModel.detachNotice, notice != noticeBeforeStop {
                // Restoring a lock failed before a session could start (for example no pairing).
                return .failure(.message(notice))
            }
            if case .idle = session.phase, !appModel.isLocationLockedAndDetached {
                return .success(())
            }
            return nil
        }

        switch outcome {
        case .success:
            return .result(
                dialog: IntentDialog("Location simulation stopped. The real location will be restored shortly.")
            )
        case .failure(let error):
            throw error
        case nil:
            throw RoamIntentError.message(
                "Restoring the real location did not finish in time. Open Roam Control to check its status."
            )
        }
    }
}

// MARK: - Shortcuts Provider

struct RoamShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SimulateLocationIntent(),
            phrases: [
                "Simulate location with \(.applicationName)",
                "Start location with \(.applicationName)"
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
            systemImageName: "location.slash.fill"
        )
    }
}
