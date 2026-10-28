import BackgroundTasks
import CoreLocation
import Foundation
import Network
import Observation
import RoamPairingFFI
import UIKit

enum DeviceSessionPhase: Equatable {
    case idle
    case openingLocalDevVPN
    case discovering
    case connecting
    case active(LocationTarget)
    case stopping
    case failed(String)
}

enum MobileDataGuidance: Equatable {
    case connectionHelp
    case turnOff
    case turnBackOn
}

enum ActiveLocationUpdateResult: Equatable {
    case unavailable
    case updated
    case failed
}

@MainActor
@Observable
final class LocalDeviceSessionCoordinator: NSObject {
    private struct PendingSession {
        let pairingRecord: Data
        let target: LocationTarget
    }

    private struct RemotePairingService: Sendable {
        let port: UInt16
        let identifier: String
        let authTag: String
    }

    private static let localDevVPNPeerAddress = "10.7.0.1"
    private static let enableURL = URL(string: "localdevvpn://enable?scheme=roamcontrol")!
    private static let minimumRestorationDisplayDuration: TimeInterval = 1.2

    private(set) var phase: DeviceSessionPhase = .idle {
        didSet {
            guard phase != oldValue else { return }
            if case .failed(let message) = phase {
                guard !terminalFailureReported else { return }
                terminalFailureReported = true
                let stage = FailureStage.classify(message, fallback: .locationUnknown)
                lastFailureStage = stage
                lastFailureDisposition = .terminal
                onFailure?(failureSnapshot(stage: stage))
            }
            onPhaseChange?(phase)
        }
    }
    private(set) var mobileDataGuidance: MobileDataGuidance? {
        didSet {
            if mobileDataGuidance == .connectionHelp, oldValue != .connectionHelp {
                onConnectionEvent?(.connectionHelpShown)
            }
        }
    }
    let backgroundKeepAlive = BackgroundLocationKeepAlive()
    var onBackgroundEvent: ((UsageAnalyticsEvent, BackgroundSessionTelemetry) -> Void)?
    var backgroundTelemetry: BackgroundSessionTelemetry {
        BackgroundSessionTelemetry(
            status: backgroundKeepAlive.status,
            started: backgroundKeepAlive.started,
            schedulerAvailable: taskRegistrationStatus == .accepted
        )
    }
    var onConnectionEvent: ((UsageAnalyticsEvent) -> Void)?
    private var retryTelemetry = ConnectionRetryTelemetry()
    private var vpnReturnRetryUsed = false
    private var vpnReturnRetryTask: Task<Void, Never>?

    private(set) var restorationStatus = "Not requested"
    private(set) var schedulerFailureReason: SchedulerFailureReason?
    private(set) var taskConfigurationStatus: BackgroundTaskConfigurationStatus = .notChecked
    private(set) var taskRegistrationStatus: BackgroundTaskRegistrationStatus = .notAttempted
    private(set) var lastFailureStage: FailureStage?
    private(set) var lastFailureDisposition: FailureDisposition?
    var onRecoveryNeeded: ((FailureDiagnosticSnapshot) -> Void)?
    private var terminalFailureReported = false
    var onFailure: ((FailureDiagnosticSnapshot) -> Void)?

    private func failureSnapshot(
        stage: FailureStage,
        disposition: FailureDisposition = .terminal
    ) -> FailureDiagnosticSnapshot {
        FailureDiagnosticSnapshot(
            stage: stage,
            disposition: disposition,
            schedulerReason: schedulerFailureReason,
            taskConfigurationStatus: taskConfigurationStatus,
            taskRegistrationStatus: taskRegistrationStatus
        )
    }

    var onPhaseChange: ((DeviceSessionPhase) -> Void)?

    private let browser = NetServiceBrowser()
    private let wifiPathMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let wifiPathMonitorQueue = DispatchQueue(
        label: "com.sean.roamcontrol.wifi-path",
        qos: .utility
    )
    private let serviceProbeQueue = DispatchQueue(
        label: "com.sean.roamcontrol.service-probe",
        qos: .userInitiated
    )
    private var discoveredServices: [NetService] = []
    private var discoveryTimeout: Task<Void, Never>?
    private var automaticDiscoveryTask: Task<Void, Never>?
    private var networkDecisionTask: Task<Void, Never>?
    private var mobileDataDiscoveryLoopTask: Task<Void, Never>?
    private var mobileDataGuidanceDelay: Task<Void, Never>?
    private var localDevVPNProbeTask: Task<Void, Never>?
    private var localDevVPNReturnTimeout: Task<Void, Never>?
    private var pendingSession: PendingSession?
    private var resolvedService: RemotePairingService?
    private var sawNonMatchingService = false
    private var isDiscoveringServices = false
    private var hasRequestedLocalDevVPNThisAttempt = false
    private var wifiPathStatusIsKnown = false
    private var isWiFiPathSatisfied = false
    private var isMobileDataStartupMode = false
    private var serviceProbeConnection: NWConnection?
    private var serviceProbeTimeout: Task<Void, Never>?
    private var serviceProbeRetryTask: Task<Void, Never>?
    private var serviceProbeAttemptCount = 0

    private var activeSession: OpaquePointer?
    private var activeRunIdentifier: UUID?
    private var schedulerRegistrationAccepted = false
    private var workerIsRunning = false
    private var cancellationRequested = false
    private(set) var isDetachedLocked = false
    private var jitterTask: Task<Void, Never>?
    private var jitterRequested = false
    /// The stable WGS-84 coordinate most recently handed to the device, without jitter.
    private(set) var lastSentDeviceCoordinate: CLLocationCoordinate2D?
    private var pendingFailureMessage: String?
    private var restorationDisplayStartDate: Date?

    override init() {
        super.init()
        backgroundKeepAlive.onChange = { [weak self] in
            guard let self else { return }
            self.onBackgroundEvent?(.backgroundKeepAliveChanged, self.backgroundTelemetry)
        }
        browser.delegate = self
        browser.includesPeerToPeer = true
        wifiPathMonitor.pathUpdateHandler = { [weak self] path in
            let isSatisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.wifiPathStatusIsKnown = true
                self?.isWiFiPathSatisfied = isSatisfied
            }
        }
        wifiPathMonitor.start(queue: wifiPathMonitorQueue)
    }

    var isBusy: Bool {
        switch phase {
        case .openingLocalDevVPN, .discovering, .connecting, .stopping:
            true
        case .idle, .active, .failed:
            false
        }
    }

    /// - Parameter enableJitter: Send a four-frame micro-jitter warm-up after the session opens.
    ///   Only fixed-location sessions should request it; walking and restoration must not.
    func start(pairingRecord: Data, target: LocationTarget, enableJitter: Bool = false) {
        guard !workerIsRunning, !isBusy else { return }
        jitterTask?.cancel()
        jitterTask = nil
        jitterRequested = enableJitter && Self.isJitterPreferenceEnabled
        isDetachedLocked = false
        lastSentDeviceCoordinate = nil
        terminalFailureReported = false
        retryTelemetry.reset()
        schedulerFailureReason = nil
        taskConfigurationStatus = .notChecked
        taskRegistrationStatus = .notAttempted
        lastFailureStage = nil
        lastFailureDisposition = nil
        restorationStatus = "Not requested"
        vpnReturnRetryUsed = false

#if targetEnvironment(simulator)
        phase = .failed("A real iPhone is required to start a location session.")
#else
        cancellationRequested = false
        pendingFailureMessage = nil
        restorationDisplayStartDate = nil
        mobileDataGuidance = nil
        hasRequestedLocalDevVPNThisAttempt = false
        isMobileDataStartupMode = false
        pendingSession = PendingSession(pairingRecord: pairingRecord, target: target)
        resolvedService = nil
        phase = .discovering
        routeStartupForCurrentNetwork()
#endif
    }

    func handleOpenURL(_ url: URL) {
        guard url.scheme?.lowercased() == "roamcontrol" else { return }
        guard pendingSession != nil else { return }
        guard phase == .openingLocalDevVPN || phase == .discovering else { return }

        localDevVPNReturnTimeout?.cancel()
        localDevVPNReturnTimeout = nil
        guard mobileDataGuidance != .turnOff else { return }
        if isMobileDataStartupMode {
            enterMobileDataGuidance()
        } else {
            beginDiscovery(showConnectionHelpIfUnavailable: true)
        }
    }

    /// - Parameters:
    ///   - target: Map coordinate (GCJ-02 inside mainland China). It is corrected to WGS-84
    ///     here, the single place every update path funnels through, while the UI keeps `target`.
    ///   - jitter: Perturb the first frame and follow with the remaining warm-up frames.
    @discardableResult
    func updateLocation(_ target: LocationTarget, jitter: Bool = false) -> ActiveLocationUpdateResult {
        guard
            workerIsRunning,
            case .active = phase,
            let activeSession,
            let pendingSession
        else { return .unavailable }

        // A newer location supersedes any warm-up that is still in flight.
        jitterTask?.cancel()
        jitterTask = nil

        let base = deviceCoordinate(for: target)
        let useJitter = jitter && Self.isJitterPreferenceEnabled
        let first = useJitter ? Self.perturbed(base, amplitude: Self.jitterAmplitude) : base
        guard rc_location_session_update(activeSession, first.latitude, first.longitude) == 0 else {
            fail("Roam Control could not update the active location.")
            return .failed
        }
        lastSentDeviceCoordinate = base

        self.pendingSession = PendingSession(
            pairingRecord: pendingSession.pairingRecord,
            target: target
        )
        phase = .active(target)
        if useJitter {
            startJitterFollowUp(around: base)
        }
        return .updated
    }

    /// Suspends until the micro-jitter warm-up (if any) has written its final frame.
    func waitForJitterToFinish() async {
        while let task = jitterTask {
            await task.value
            if jitterTask == task { jitterTask = nil }
        }
    }

    func openLocalDevVPN() {
#if !targetEnvironment(simulator)
        if pendingSession != nil, !workerIsRunning {
            openLocalDevVPNForPendingSession()
            return
        }

        UIApplication.shared.open(Self.enableURL) { [weak self] opened in
            guard !opened else { return }
            Task { @MainActor in
                self?.fail("Install LocalDevVPN before starting a location session.")
            }
        }
#endif
    }

    func dismissMobileDataGuidance() {
        mobileDataGuidance = nil
    }

    func confirmMobileDataIsOff() {
        guard mobileDataGuidance == .turnOff, pendingSession != nil else { return }
        automaticDiscoveryTask?.cancel()
        mobileDataDiscoveryLoopTask?.cancel()
        mobileDataDiscoveryLoopTask = nil
        automaticDiscoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled, let self else { return }
            self.automaticDiscoveryTask = nil
            self.startMobileDataDiscoveryLoop()
        }
    }

    func useMobileDataGuidance() {
        guard mobileDataGuidance == .connectionHelp, pendingSession != nil else { return }
        isMobileDataStartupMode = true
        enterMobileDataGuidance()
    }

    func retryConnection() {
        guard mobileDataGuidance == .connectionHelp, pendingSession != nil else { return }
        onConnectionEvent?(retryTelemetry.selected())
        mobileDataGuidance = nil
        resolvedService = nil
        beginDiscovery(showConnectionHelpIfUnavailable: true)
    }

    func appDidBecomeActive() {
        if
            phase == .openingLocalDevVPN,
            pendingSession != nil,
            !workerIsRunning
        {
            automaticDiscoveryTask?.cancel()
            automaticDiscoveryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(900))
                guard
                    !Task.isCancelled,
                    let self,
                    self.pendingSession != nil,
                    self.phase == .openingLocalDevVPN,
                    !self.workerIsRunning
                else { return }

                self.automaticDiscoveryTask = nil
                if self.isMobileDataStartupMode {
                    self.enterMobileDataGuidance()
                } else {
                    self.beginDiscovery(showConnectionHelpIfUnavailable: true)
                }
            }
            return
        }

        guard mobileDataGuidance == .turnOff else { return }
        startMobileDataDiscoveryLoop()
    }

    func stop() {
        jitterTask?.cancel()
        jitterTask = nil
        isDetachedLocked = false
        backgroundKeepAlive.stop()
        mobileDataGuidance = nil
        switch phase {
        case .idle:
            return
        case .openingLocalDevVPN, .discovering:
            cancellationRequested = true
            cleanupDiscovery()
            clearPendingSession()
            phase = .idle
        case .connecting:
            cancellationRequested = true
            phase = .stopping
            if let activeSession {
                rc_location_session_cancel(activeSession)
            }
        case .active:
            cancellationRequested = true
            restorationStatus = "Stop requested; awaiting device response"
            restorationDisplayStartDate = .now
            phase = .stopping
            if let activeSession {
                rc_location_session_cancel(activeSession)
            }
        case .stopping:
            break
        case .failed:
            clearPendingSession()
            phase = .idle
        }
    }

    /// Lock & Detach: leave the last injected coordinate in place and drop the tunnel.
    /// Unlike `stop()` this never asks the device to clear the simulation; the native layer
    /// only flushes the newest coordinate and then closes its client-side connection.
    /// - Returns: `false` when no active session exists, in which case nothing was changed.
    @discardableResult
    func detach() -> Bool {
        guard case .active = phase, workerIsRunning, let activeSession else { return false }
        jitterTask?.cancel()
        jitterTask = nil
        isDetachedLocked = true
        backgroundKeepAlive.stop()
        mobileDataGuidance = nil
        cancellationRequested = true
        restorationStatus = "Location locked; tunnel detached"
        phase = .stopping
        rc_location_session_detach(activeSession)
        return true
    }

    func reset() {
        stop()
        if !workerIsRunning {
            clearPendingSession()
            phase = .idle
        }
    }

    // A cold VPN start can briefly expose services before the return to the app settles.
    // Retry once per start; never turn this into an unbounded recovery loop.
    private func showConnectionHelp() {
        guard pendingSession != nil, !workerIsRunning else { return }
        guard hasRequestedLocalDevVPNThisAttempt, !isMobileDataStartupMode,
              !vpnReturnRetryUsed else {
            mobileDataGuidance = .connectionHelp
            return
        }
        vpnReturnRetryUsed = true
        cleanupDiscovery()
        phase = .discovering
        mobileDataGuidance = nil
        vpnReturnRetryTask = Task { @MainActor [weak self] in
            // Bound the foreground wait as well as the retry count.
            for _ in 0..<10 {
                do { try await Task.sleep(for: .milliseconds(300)) }
                catch { return }
                guard let self, self.pendingSession != nil,
                      self.phase == .discovering, !self.workerIsRunning else { return }
                if UIApplication.shared.applicationState == .active {
                    self.vpnReturnRetryTask = nil
                    self.resolvedService = nil
                    self.beginDiscovery(showConnectionHelpIfUnavailable: true)
                    return
                }
            }
            guard let self, self.pendingSession != nil, self.phase == .discovering else { return }
            self.vpnReturnRetryTask = nil
            self.mobileDataGuidance = .connectionHelp
        }
    }

    private func beginDiscovery(
        reportTimeout: Bool = true,
        openLocalDevVPNIfUnavailable: Bool = false,
        showConnectionHelpIfUnavailable: Bool = false
    ) {
        cleanupDiscovery()
        sawNonMatchingService = false
        isDiscoveringServices = true
        phase = .discovering
        browser.delegate = self
        browser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")

        if showConnectionHelpIfUnavailable {
            mobileDataGuidanceDelay = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard
                    !Task.isCancelled,
                    let self,
                    self.pendingSession != nil,
                    self.phase == .discovering,
                    !self.workerIsRunning,
                    self.resolvedService == nil
                else { return }
                self.showConnectionHelp()
            }
        }

        if openLocalDevVPNIfUnavailable {
            localDevVPNProbeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                guard
                    !Task.isCancelled,
                    let self,
                    self.pendingSession != nil,
                    self.phase == .discovering,
                    !self.workerIsRunning,
                    self.resolvedService == nil
                else { return }

                self.localDevVPNProbeTask = nil
                self.openLocalDevVPNForPendingSession()
            }
        }

        if reportTimeout {
            discoveryTimeout = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self, self.phase == .discovering else { return }
                if self.sawNonMatchingService {
                    self.fail(
                        "Roam Control found an outdated device announcement. Toggle LocalDevVPN off and on, then try again."
                    )
                } else {
                    self.fail(
                        "Roam Control could not find this iPhone through LocalDevVPN. Check that the tunnel is enabled and try again."
                    )
                }
            }
        }
    }

    private func resolve(_ service: NetService) {
        service.delegate = self
        service.includesPeerToPeer = true
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: 8)
        discoveredServices.append(service)
    }

    private func useResolvedService(_ service: NetService) {
        guard phase == .discovering else { return }
        guard service.port > 0, service.port <= Int(UInt16.max) else { return }
        guard
            let txtData = service.txtRecordData(),
            let identifierData = NetService.dictionary(fromTXTRecord: txtData)["identifier"],
            let authTagData = NetService.dictionary(fromTXTRecord: txtData)["authTag"]
        else { return }

        let identifier = String(decoding: identifierData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let authTag = String(decoding: authTagData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, !authTag.isEmpty else { return }
        guard let pairingRecord = pendingSession?.pairingRecord else { return }

        let matchesPairedDevice = pairingRecord.withUnsafeBytes { recordBytes in
            guard let recordBaseAddress = recordBytes.bindMemory(to: UInt8.self).baseAddress else {
                return false
            }

            return identifier.withCString { serviceIdentifier in
                authTag.withCString { authTag in
                    rc_pairing_record_matches_service(
                        recordBaseAddress,
                        pairingRecord.count,
                        serviceIdentifier,
                        authTag
                    ) == 1
                }
            }
        }

        guard matchesPairedDevice else {
            sawNonMatchingService = true
            service.startMonitoring()
            return
        }

        guard serviceProbeConnection == nil, serviceProbeRetryTask == nil else { return }
        verifyServiceIsReachable(RemotePairingService(
            port: UInt16(service.port),
            identifier: identifier,
            authTag: authTag
        ))
    }

    private func submitLocationTask() {
        guard pendingSession != nil, resolvedService != nil else {
            fail("Roam Control could not prepare the selected location.")
            return
        }
        phase = .connecting
        observeLocationScheduler()
        // Scheduler observation never owns, delays or cancels the native worker.
        runNativeLocationSession()
    }

    private func observeLocationScheduler() {
        taskConfigurationStatus = BackgroundTaskIdentifier.configurationStatus(for: "location")
        taskRegistrationStatus = .notAttempted
        defer { onBackgroundEvent?(.backgroundSchedulerObserved, backgroundTelemetry) }
        guard taskConfigurationStatus == .permitted,
              let prefix = BackgroundTaskIdentifier.prefix(for: "location") else {
            reportSchedulerObservationFailure()
            return
        }
        // Keep one successful registration per process; repeated sessions must not
        // accumulate handlers or register the same identifier twice.
        if schedulerRegistrationAccepted {
            taskRegistrationStatus = .accepted
            return
        }
        let identifier = "\(prefix).\(UUID().uuidString)"
        let wasRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier, using: .main
        ) { task in
            task.setTaskCompleted(success: true)
        }
        taskRegistrationStatus = wasRegistered ? .accepted : .rejected
        // No request is submitted: this build measures registration availability only.
        schedulerRegistrationAccepted = wasRegistered
        if !wasRegistered { reportSchedulerObservationFailure() }
    }

    private func reportSchedulerObservationFailure() {
        lastFailureStage = .schedulerRegistration
        lastFailureDisposition = .recoverable
        onRecoveryNeeded?(failureSnapshot(stage: .schedulerRegistration, disposition: .recoverable))
    }

    private func runNativeLocationSession() {
        guard let pendingSession, let resolvedService else {
            fail("Roam Control lost the location session details.")
            return
        }
        guard let session = rc_location_session_create() else {
            fail("Roam Control could not start its location engine.")
            return
        }

        let runIdentifier = UUID()
        activeRunIdentifier = runIdentifier
        activeSession = session
        workerIsRunning = true

        let sessionBits = UInt(bitPattern: session)
        let contextBits = UInt(bitPattern: Unmanaged.passRetained(self).toOpaque())
        let pairingRecord = pendingSession.pairingRecord
        let base = deviceCoordinate(for: pendingSession.target)
        lastSentDeviceCoordinate = base
        // With jitter requested the very first frame is already perturbed, so the device
        // never sees a single dead coordinate.
        let initialCoordinate = jitterRequested
            ? Self.perturbed(base, amplitude: Self.jitterAmplitude)
            : base
        let peerAddressString = Self.localDevVPNPeerAddress

        DispatchQueue.global(qos: .userInitiated).async {
            guard
                let session = OpaquePointer(bitPattern: sessionBits),
                let context = UnsafeMutableRawPointer(bitPattern: contextBits)
            else { return }

            var result = RCLocationResult()
            let returnCode = pairingRecord.withUnsafeBytes { recordBytes in
                guard let recordBaseAddress = recordBytes.bindMemory(to: UInt8.self).baseAddress else {
                    return Int32(-1)
                }

                return peerAddressString.withCString { peerAddress in
                    resolvedService.identifier.withCString { serviceIdentifier in
                        resolvedService.authTag.withCString { authTag in
                            rc_location_session_run(
                                session,
                                recordBaseAddress,
                                pairingRecord.count,
                                peerAddress,
                                resolvedService.port,
                                serviceIdentifier,
                                authTag,
                                initialCoordinate.latitude,
                                initialCoordinate.longitude,
                                locationStartedCallback,
                                context,
                                &result
                            )
                        }
                    }
                }
            }

            let outcome = NativeLocationOutcome(result: result, returnCode: returnCode)
            rc_location_result_destroy(&result)

            DispatchQueue.main.async {
                if let session = OpaquePointer(bitPattern: sessionBits) {
                    rc_location_session_destroy(session)
                }
                let coordinator = Unmanaged<LocalDeviceSessionCoordinator>
                    .fromOpaque(context)
                    .takeRetainedValue()
                coordinator.nativeLocationFinished(outcome, runIdentifier: runIdentifier)
            }
        }
    }

    fileprivate func nativeLocationStarted() {
        guard workerIsRunning, !cancellationRequested, let target = pendingSession?.target else { return }
        mobileDataDiscoveryLoopTask?.cancel()
        mobileDataDiscoveryLoopTask = nil
        backgroundKeepAlive.start()
        phase = .active(target)
        if let event = retryTelemetry.becameActive() {
            onConnectionEvent?(event)
        }
        if mobileDataGuidance == .turnOff {
            mobileDataGuidance = .turnBackOn
        }

        if jitterRequested, let base = lastSentDeviceCoordinate {
            startJitterFollowUp(around: base)
        }
    }

    // MARK: - GCJ-02 correction and micro-jitter

    private static let jitterAmplitude = 0.000012
    private static let finalJitterAmplitude = 0.000001
    private static let jitterFrameInterval: Duration = .milliseconds(350)

    private static var isJitterPreferenceEnabled: Bool {
        UserDefaults.standard.object(forKey: RoamPreferenceKeys.enableLocationJitter) as? Bool ?? true
    }

    /// Converts a map coordinate to the WGS-84 value the device expects, honouring the
    /// `autoConvertGCJ02` preference. Every send path in this class goes through here.
    private func deviceCoordinate(for target: LocationTarget) -> CLLocationCoordinate2D {
        let autoConvert = UserDefaults.standard.object(
            forKey: RoamPreferenceKeys.autoConvertGCJ02
        ) as? Bool ?? true
        return CoordinateConverter.convertToWGS84IfNeeded(
            coordinate: target.coordinate,
            autoConvert: autoConvert
        )
    }

    private static func perturbed(
        _ coordinate: CLLocationCoordinate2D,
        amplitude: Double
    ) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: coordinate.latitude + Double.random(in: -amplitude...amplitude),
            longitude: coordinate.longitude + Double.random(in: -amplitude...amplitude)
        )
    }

    /// Frames 2-4 of the warm-up, 0.35 s apart: two further ~1 m perturbations and a final
    /// near-exact frame. Frames go straight to the native layer so the UI phase, recovery
    /// record and auto-detach trigger are not disturbed by each one.
    private func startJitterFollowUp(around base: CLLocationCoordinate2D) {
        jitterTask?.cancel()
        jitterTask = Task { @MainActor [weak self] in
            for frame in 2...4 {
                try? await Task.sleep(for: Self.jitterFrameInterval)
                guard
                    !Task.isCancelled,
                    let self,
                    self.workerIsRunning,
                    case .active = self.phase,
                    let activeSession = self.activeSession
                else { return }
                let amplitude = frame == 4 ? Self.finalJitterAmplitude : Self.jitterAmplitude
                let next = Self.perturbed(base, amplitude: amplitude)
                guard rc_location_session_update(activeSession, next.latitude, next.longitude) == 0 else {
                    return
                }
            }
        }
    }

    private func nativeLocationFinished(
        _ outcome: NativeLocationOutcome,
        runIdentifier: UUID
    ) {
        guard activeRunIdentifier == runIdentifier else { return }

        backgroundKeepAlive.stop()
        jitterTask?.cancel()
        jitterTask = nil
        jitterRequested = false
        activeRunIdentifier = nil
        activeSession = nil
        workerIsRunning = false

        if let pendingFailureMessage {
            self.pendingFailureMessage = nil
            mobileDataGuidance = nil
            clearPendingSession()
            phase = .failed(pendingFailureMessage)
            return
        }

        if cancellationRequested {
            cancellationRequested = false
            if isDetachedLocked {
                if case .failure(let message) = outcome,
                   message != "The location session was stopped." {
                    // The final coordinate could not be flushed, so do not claim a lock.
                    isDetachedLocked = false
                    restorationStatus = "Lock not confirmed; location state unverified"
                    clearPendingSession()
                    phase = .failed(message)
                    return
                }
                restorationStatus = "Location locked; tunnel detached"
                clearPendingSession()
                finishCancelledLocationSession()
                return
            }
            if case .failure(let message) = outcome,
               message != "The location session was stopped." {
                restorationStatus = "Stop not confirmed; real location unverified"
                clearPendingSession()
                phase = .failed(message)
                return
            }
            if restorationDisplayStartDate != nil {
                restorationStatus = "Stop command acknowledged; real location reacquisition unverified"
            }
            clearPendingSession()
            finishCancelledLocationSession()
            return
        }

        switch outcome {
        case .success:
            mobileDataGuidance = nil
            clearPendingSession()
            phase = .idle
        case .failure(let message):
            if isRecoverableTunnelConnectionFailure(message) {
                let stage = FailureStage.classify(message, fallback: .locationUnknown)
                lastFailureStage = stage
                lastFailureDisposition = .recoverable
                onRecoveryNeeded?(failureSnapshot(stage: stage, disposition: .recoverable))
                resolvedService = nil
                if isMobileDataStartupMode {
                    enterMobileDataGuidance()
                } else if hasRequestedLocalDevVPNThisAttempt {
                    phase = .discovering
                    showConnectionHelp()
                } else {
                    openLocalDevVPNForPendingSession()
                }
                return
            }

            mobileDataGuidance = nil
            clearPendingSession()
            phase = .failed(message)
        }
    }

    private func fail(_ message: String) {
        backgroundKeepAlive.stop()
        localDevVPNReturnTimeout?.cancel()
        localDevVPNReturnTimeout = nil
        mobileDataGuidance = nil
        cleanupDiscovery()

        if workerIsRunning, let activeSession {
            pendingFailureMessage = message
            rc_location_session_cancel(activeSession)
        } else {
            clearPendingSession()
        }

        phase = .failed(message)
    }

    private func cleanupDiscovery() {
        vpnReturnRetryTask?.cancel()
        vpnReturnRetryTask = nil
        isDiscoveringServices = false
        cleanupServiceProbe()
        discoveryTimeout?.cancel()
        discoveryTimeout = nil
        mobileDataGuidanceDelay?.cancel()
        mobileDataGuidanceDelay = nil
        localDevVPNProbeTask?.cancel()
        localDevVPNProbeTask = nil
        browser.stop()

        for service in discoveredServices {
            service.stopMonitoring()
            service.stop()
            service.remove(from: .main, forMode: .common)
            service.delegate = nil
        }
        discoveredServices = []
    }

    private func verifyServiceIsReachable(_ service: RemotePairingService) {
        guard
            phase == .discovering,
            pendingSession != nil,
            serviceProbeConnection == nil
        else { return }
        guard let port = NWEndpoint.Port(rawValue: service.port) else {
            handleServiceProbeResult(false, service: service)
            return
        }

        serviceProbeAttemptCount += 1
        let connection = NWConnection(
            host: NWEndpoint.Host(Self.localDevVPNPeerAddress),
            port: port,
            using: .tcp
        )
        serviceProbeConnection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .ready:
                Task { @MainActor [weak self] in
                    self?.finishServiceProbe(connection, service: service, reachable: true)
                }
            case .failed, .cancelled:
                Task { @MainActor [weak self] in
                    self?.finishServiceProbe(connection, service: service, reachable: false)
                }
            case .setup, .waiting, .preparing:
                break
            @unknown default:
                break
            }
        }

        serviceProbeTimeout = Task { @MainActor [weak self, weak connection] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, let self, let connection else { return }
            self.finishServiceProbe(connection, service: service, reachable: false)
        }
        connection.start(queue: serviceProbeQueue)
    }

    private func finishServiceProbe(
        _ connection: NWConnection,
        service: RemotePairingService,
        reachable: Bool
    ) {
        guard serviceProbeConnection === connection else { return }
        serviceProbeConnection = nil
        serviceProbeTimeout?.cancel()
        serviceProbeTimeout = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        handleServiceProbeResult(reachable, service: service)
    }

    private func handleServiceProbeResult(
        _ reachable: Bool,
        service: RemotePairingService
    ) {
        guard phase == .discovering, pendingSession != nil else { return }

        if reachable {
            serviceProbeAttemptCount = 0
            resolvedService = service
            mobileDataDiscoveryLoopTask?.cancel()
            mobileDataDiscoveryLoopTask = nil
            if mobileDataGuidance == .connectionHelp {
                mobileDataGuidance = nil
            }
            cleanupDiscovery()
            submitLocationTask()
            return
        }

        if isMobileDataStartupMode {
            serviceProbeAttemptCount = 0
            return
        }

        if !hasRequestedLocalDevVPNThisAttempt {
            serviceProbeAttemptCount = 0
            openLocalDevVPNForPendingSession()
            return
        }

        guard serviceProbeAttemptCount < 3 else {
            serviceProbeAttemptCount = 0
            showConnectionHelp()
            return
        }

        serviceProbeRetryTask?.cancel()
        serviceProbeRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, let self else { return }
            self.serviceProbeRetryTask = nil
            self.verifyServiceIsReachable(service)
        }
    }

    private func cleanupServiceProbe() {
        serviceProbeTimeout?.cancel()
        serviceProbeTimeout = nil
        serviceProbeRetryTask?.cancel()
        serviceProbeRetryTask = nil
        serviceProbeConnection?.stateUpdateHandler = nil
        serviceProbeConnection?.cancel()
        serviceProbeConnection = nil
        serviceProbeAttemptCount = 0
    }

    private func clearPendingSession() {
        backgroundKeepAlive.stop()
        retryTelemetry.reset()
        automaticDiscoveryTask?.cancel()
        automaticDiscoveryTask = nil
        networkDecisionTask?.cancel()
        networkDecisionTask = nil
        mobileDataDiscoveryLoopTask?.cancel()
        mobileDataDiscoveryLoopTask = nil
        localDevVPNReturnTimeout?.cancel()
        localDevVPNReturnTimeout = nil
        cleanupDiscovery()
        pendingSession = nil
        resolvedService = nil
        hasRequestedLocalDevVPNThisAttempt = false
        isMobileDataStartupMode = false
    }

    private func finishCancelledLocationSession() {
        let elapsed = restorationDisplayStartDate.map { Date.now.timeIntervalSince($0) } ?? .infinity
        restorationDisplayStartDate = nil
        let remaining = max(0, Self.minimumRestorationDisplayDuration - elapsed)

        guard remaining > 0 else {
            phase = .idle
            return
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard let self, !self.workerIsRunning, self.phase == .stopping else { return }
            self.phase = .idle
        }
    }

    private func isRecoverableTunnelConnectionFailure(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("through LocalDevVPN")
            || message.localizedCaseInsensitiveContains("make the iPhone connection available")
            || message.localizedCaseInsensitiveContains("open the secure device tunnel")
    }

    private func routeStartupForCurrentNetwork() {
        networkDecisionTask?.cancel()
        networkDecisionTask = nil
        mobileDataGuidance = nil

        if wifiPathStatusIsKnown {
            if isWiFiPathSatisfied {
                beginDiscovery(openLocalDevVPNIfUnavailable: true)
            } else {
                isMobileDataStartupMode = true
                openLocalDevVPNForPendingSession()
            }
            return
        }

        networkDecisionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard
                !Task.isCancelled,
                let self,
                self.pendingSession != nil,
                !self.workerIsRunning
            else { return }

            self.networkDecisionTask = nil
            if self.wifiPathStatusIsKnown, !self.isWiFiPathSatisfied {
                self.isMobileDataStartupMode = true
                self.openLocalDevVPNForPendingSession()
            } else {
                self.beginDiscovery(openLocalDevVPNIfUnavailable: true)
            }
        }
    }

    private func enterMobileDataGuidance() {
        guard pendingSession != nil, !workerIsRunning else { return }
        cleanupDiscovery()
        phase = .discovering
        mobileDataGuidance = .turnOff
        startMobileDataDiscoveryLoop()
    }

    private func startMobileDataDiscoveryLoop() {
        guard
            isMobileDataStartupMode,
            mobileDataGuidance == .turnOff,
            pendingSession != nil,
            !workerIsRunning
        else { return }

        mobileDataDiscoveryLoopTask?.cancel()
        mobileDataDiscoveryLoopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard
                    let self,
                    self.isMobileDataStartupMode,
                    self.mobileDataGuidance == .turnOff,
                    self.pendingSession != nil,
                    !self.workerIsRunning
                else { return }

                self.resolvedService = nil
                self.beginDiscovery(reportTimeout: false)
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private func openLocalDevVPNForPendingSession() {
#if !targetEnvironment(simulator)
        guard pendingSession != nil, !workerIsRunning else { return }
        cleanupDiscovery()
        mobileDataGuidance = nil
        hasRequestedLocalDevVPNThisAttempt = true
        phase = .openingLocalDevVPN

        UIApplication.shared.open(Self.enableURL) { [weak self] opened in
            guard !opened else { return }
            Task { @MainActor in
                self?.fail("Install LocalDevVPN before starting a location session.")
            }
        }
#endif
    }

}

extension LocalDeviceSessionCoordinator: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        MainActor.assumeIsolated {
            resolve(service)
        }
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        MainActor.assumeIsolated {
            fail("Local Network access is required to find this iPhone.")
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        MainActor.assumeIsolated {
            useResolvedService(sender)
        }
    }

    nonisolated func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        MainActor.assumeIsolated {
            useResolvedService(sender)
        }
    }
}

private enum NativeLocationOutcome: Sendable {
    case success
    case failure(String)

    init(result: RCLocationResult, returnCode: Int32) {
        guard returnCode != 0 else {
            self = .success
            return
        }

        let message: String
        if let errorMessage = result.error_message {
            message = String(cString: errorMessage)
        } else {
            message = ""
        }
        self = .failure(message.isEmpty ? "The iPhone could not start the location session." : message)
    }
}

private let locationStartedCallback: RCLocationStartedCallback = { context in
    guard let context else { return }
    let contextBits = UInt(bitPattern: context)

    DispatchQueue.main.async {
        guard let context = UnsafeMutableRawPointer(bitPattern: contextBits) else { return }
        let coordinator = Unmanaged<LocalDeviceSessionCoordinator>
            .fromOpaque(context)
            .takeUnretainedValue()
        coordinator.nativeLocationStarted()
    }
}
