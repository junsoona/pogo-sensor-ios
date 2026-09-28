import Foundation
import Observation
import os
#if canImport(UIKit)
import UIKit
#endif

/// The iPhone's side of the Watch link. Hands the Watch the latest glance with the current settings
/// whenever the app stores one, and answers the Watch's refresh requests (`WatchRelayResponder`),
/// for which iOS may launch the app in the background.
///
/// Nothing is handed over only "when something changes": the first activation, a Watch app that
/// becomes installed, a switch to another Watch and every return to the foreground read the session
/// again, and whatever couldn't be handed over earlier goes then. WatchConnectivity reports "not
/// paired, not installed" until activation completes, so only an activated session's reading counts.
///
/// Does nothing where WatchConnectivity isn't supported (iPad, Mac): the Settings section that shows
/// its state is hidden there too.
@MainActor
@Observable
final class PhoneWatchRelay: NSObject {
    enum WatchState: Equatable, Sendable {
        /// This device can't pair a Watch (iPad, Mac).
        case unsupported
        /// The session isn't activated yet (or is switching to another Watch): nothing is known.
        case activating
        case notPaired
        /// A Watch is paired, but WatchConnectivity doesn't see PogoHome on it.
        case appNotInstalled
        case ready
    }

    /// Whether the current settings reached WatchConnectivity, which delivers them to the Watch app
    /// (the next time it runs, if it isn't running now).
    enum HandOver: Equatable, Sendable {
        /// Waiting for the Watch link; handed over as soon as it is ready.
        case pending
        case handedOver(at: Date)
        /// WatchConnectivity refused; tried again at the next change or return to the foreground.
        case failed
    }

    private(set) var watchState: WatchState = .unsupported
    private(set) var handOver: HandOver = .pending
    /// When the latest glance and settings were handed to WatchConnectivity.
    var lastSentAt: Date? {
        if case let .handedOver(at) = handOver { return at }
        return nil
    }
    /// When the Watch last asked for the current state.
    private(set) var lastRequestAt: Date?

    @ObservationIgnored private let appModel: AppModel
    @ObservationIgnored private let publisher: HomeGlancePublisher
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let transport: SensorAPITransport
    @ObservationIgnored private let session: PhoneWatchSession?
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var lastWakeGlance: HomeGlanceSnapshot?
    @ObservationIgnored private var lastWakeAt: Date?
    @ObservationIgnored private var lastSessionReading: PhoneWatchSessionReading?

    /// Complication updates wake the Watch app and are budgeted (about 50 a day), so only a change
    /// in what a complication states uses one — at most this often, unless Apple Home's values must
    /// disappear.
    static let complicationWakeInterval: TimeInterval = 15 * 60

    private nonisolated static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.junsoona.PogoHome",
        category: "WatchRelay"
    )

    /// `session` is WatchConnectivity's where supported, `nil` elsewhere (and a scripted one in tests).
    init(
        appModel: AppModel,
        publisher: HomeGlancePublisher,
        defaults: UserDefaults = .standard,
        session: PhoneWatchSession? = PhoneWatchRelay.defaultSession(),
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.appModel = appModel
        self.publisher = publisher
        self.defaults = defaults
        self.session = session
        self.now = now
        // A fetch for the Watch must answer well before the Watch stops waiting.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        self.transport = URLSessionSensorAPITransport(session: URLSession(configuration: configuration))
        super.init()
    }

    static func defaultSession() -> PhoneWatchSession? {
        #if canImport(WatchConnectivity)
        return WCPhoneWatchSession.makeIfSupported()
        #else
        return nil
        #endif
    }

    /// Starts the session; call once at launch — also a background launch for a Watch request.
    func activate() {
        guard let session else { return }
        watchState = .activating
        session.onEvent = { [weak self] event in self?.sessionChanged(event) }
        session.onRefreshRequest = { [weak self] in await self?.answerRefreshRequest() ?? [:] }
        Self.logger.notice("watch session activating")
        session.activate()
    }

    var isSupported: Bool { watchState != .unsupported }

    /// Reads the session again: the app came to the foreground, or Settings is showing the state.
    /// A callback missed while the app was suspended can't leave an old reading in place.
    func recheck() {
        guard session != nil, watchState != .unsupported else { return }
        sessionChanged(.recheck)
    }

    // MARK: - Session state

    /// What a session reading means. Before activation completes nothing is known.
    nonisolated static func state(for reading: PhoneWatchSessionReading) -> WatchState {
        guard reading.activation == .activated else { return .activating }
        if !reading.isPaired { return .notPaired }
        if !reading.isWatchAppInstalled { return .appNotInstalled }
        return .ready
    }

    func sessionChanged(_ event: PhoneWatchSessionEvent) {
        guard let session else { return }
        if event == .becameInactive || event == .deactivated {
            // Another Watch: it has none of this iPhone's settings yet.
            handOver = .pending
        }
        let reading = session.reading
        let wasReady = watchState == .ready
        watchState = Self.state(for: reading)
        if reading != lastSessionReading || event != .recheck {
            Self.logger.notice("watch session \(event.rawValue, privacy: .public): \(reading.description, privacy: .public) -> \(String(describing: self.watchState), privacy: .public)")
        }
        lastSessionReading = reading
        guard watchState == .ready else { return }
        // First activation, a newly installed Watch app, another Watch, or an earlier hand-over
        // that couldn't happen: give it the current state.
        if !wasReady || lastSentAt == nil {
            send(glance: publisher.latestSnapshot(), wakesComplication: false, reason: event.rawValue)
        }
    }

    // MARK: - Handing over

    /// The publisher stored a new glance (the iPhone widgets will show it too).
    func glanceWasStored(_ glance: HomeGlanceSnapshot) {
        send(glance: glance, wakesComplication: shouldWakeComplication(for: glance), reason: "glance")
    }

    /// Something the Watch settings are made of changed (bridge address, mode, selected values).
    func settingsDidChange() {
        send(glance: publisher.latestSnapshot(), wakesComplication: false, reason: "settings")
    }

    private func shouldWakeComplication(for glance: HomeGlanceSnapshot) -> Bool {
        let change = HomeGlanceRefreshPolicy.classify(from: lastWakeGlance, to: glance)
        if change == .privacy { return true }
        guard change >= .state else { return false }
        return lastWakeAt.map { now().timeIntervalSince($0) >= Self.complicationWakeInterval } ?? true
    }

    private func settings(now: Date) -> WatchSettings {
        PhoneWatchSettings.make(defaults: defaults, snapshot: appModel.snapshot, now: now)
    }

    private func send(glance: HomeGlanceSnapshot?, wakesComplication: Bool, reason: String) {
        guard let session else { return }
        // Read now, not from the last callback: the reading may have changed since.
        let reading = session.reading
        let state = Self.state(for: reading)
        if state != watchState, watchState != .unsupported {
            Self.logger.notice("watch session \(reason, privacy: .public): \(reading.description, privacy: .public) -> \(String(describing: state), privacy: .public)")
            watchState = state
            lastSessionReading = reading
        }
        guard state == .ready else {
            if handOver != .pending {
                Self.logger.notice("watch hand-over waits (\(reason, privacy: .public)): \(String(describing: state), privacy: .public)")
            }
            // Handed over when the link becomes ready (activation, install, foreground).
            handOver = .pending
            return
        }
        let now = now()
        let settings = settings(now: now)
        let payload = WatchSyncPayload(sentAt: now, glance: glance, settings: settings)
        do {
            let message = try WatchSyncCoding.message(for: payload)
            try session.updateApplicationContext(message)
            handOver = .handedOver(at: now)
            if reason != "glance" {
                Self.logger.notice("watch hand-over (\(reason, privacy: .public)): mode=\(settings.dataSourceMode.rawValue, privacy: .public) hub=\(settings.hubBaseURL != nil, privacy: .public) selected=\(settings.selectedValueIDs.count, privacy: .public) glance=\(glance != nil, privacy: .public)")
            }
            if wakesComplication, let glance, session.transferComplicationUserInfo(message) {
                lastWakeGlance = glance
                lastWakeAt = now
            }
        } catch {
            handOver = .failed
            Self.logger.error("watch hand-over failed (\(reason, privacy: .public)): \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Answering

    var responder: WatchRelayResponder {
        WatchRelayResponder(
            settings: { [unowned self] in self.settings(now: Date()) },
            liveGlance: { [unowned self] in
                guard self.publisher.isFollowingModels, self.appModel.health.isCurrentStateVerified else { return nil }
                return self.publisher.latestSnapshot()
            },
            lastGlance: { [unowned self] in self.publisher.latestSnapshot() },
            applyConfiguration: { [unowned self] in self.appModel.applyingConfiguration(to: $0) },
            homeName: { [unowned self] in self.appModel.homeName },
            fetchSnapshot: { [transport] url in
                let data = try await transport.fetchSnapshotData(from: PogoAPIEndpoint(baseURL: url).snapshotURL)
                return try PogoSnapshotMapper.decodeSnapshot(from: data)
            },
            now: { Date() }
        )
    }

    private func answerRefreshRequest() async -> [String: Any] {
        lastRequestAt = now()
        #if canImport(UIKit) && !os(watchOS)
        // Launched in the background for this: finish the fetch before iOS suspends the app.
        let task = UIApplication.shared.beginBackgroundTask(withName: "PogoHome Watch refresh")
        defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
        #endif
        let reply = await responder.reply()
        Self.logger.notice("answered watch refresh: \(reply.outcome.rawValue, privacy: .public) selected=\(reply.payload.settings.selectedValueIDs.count, privacy: .public) glance=\(reply.payload.glance != nil, privacy: .public)")
        return (try? WatchSyncCoding.message(for: reply)) ?? [:]
    }
}
