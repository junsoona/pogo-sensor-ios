import Foundation
import os
import WatchConnectivity
import WidgetKit

/// Reads the POGO bridge directly (`GET /api/v1/snapshot`). Only works where the Watch reaches the
/// bridge's address — on the bridge's Wi‑Fi, or through a nearby iPhone that is on it. Short time
/// limits: a Watch screen shouldn't wait long for an answer that isn't coming.
@MainActor
final class WatchHubClient: WatchHubFetching {
    private let transport: SensorAPITransport

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        configuration.waitsForConnectivity = false
        transport = URLSessionSensorAPITransport(session: URLSession(configuration: configuration))
    }

    func fetchSnapshot(from baseURL: URL) async throws -> HomeSnapshot {
        let data = try await transport.fetchSnapshotData(from: PogoAPIEndpoint(baseURL: baseURL).snapshotURL)
        return try PogoSnapshotMapper.decodeSnapshot(from: data)
    }
}

@MainActor
final class WatchWidgetReloader: WatchWidgetReloading {
    func reloadWidgets() {
        for kind in WatchWidgetKind.all {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
    }
}

/// The Watch's side of the iPhone link: receives the iPhone's hand-overs and asks it for the
/// current state. iOS launches the iPhone app in the background for a request if needed; the
/// answer carries new values only if the iPhone itself reaches the bridge.
@MainActor
final class WatchPhoneLink: NSObject, WatchPhoneRelaying {
    /// How long a request waits for the iPhone (which may have to launch and fetch first).
    static let replyTimeout: TimeInterval = 12

    var onPayload: (@MainActor (WatchSyncPayload) -> Void)?
    /// Called on activation and whenever reachability or the iPhone app's installation changes.
    var onLinkChange: (@MainActor (WatchPhoneLinkStatus) -> Void)?

    private let session: WCSession?
    private var pendingContentWaiters: [CheckedContinuation<Void, Never>] = []

    nonisolated private static let logger = Logger(subsystem: "com.junsoona.PogoHome", category: "WatchPhoneLink")

    override init() {
        session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
    }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    var isPhoneReachable: Bool {
        guard let session, session.activationState == .activated else { return false }
        return session.isReachable
    }

    var linkStatus: WatchPhoneLinkStatus {
        guard let session, session.activationState == .activated else { return .activating }
        if !session.isCompanionAppInstalled { return .companionNotInstalled }
        return session.isReachable ? .reachable : .unreachable
    }

    fileprivate func linkChanged(_ event: String) {
        let status = linkStatus
        Self.logger.notice("session \(event, privacy: .public): link=\(status.rawValue, privacy: .public)")
        onLinkChange?(status)
    }

    func requestRefresh() async throws -> WatchRelayReply {
        guard let session, session.activationState == .activated, session.isReachable else {
            throw WatchPhoneRelayError.unreachable
        }
        let gate = ReplyGate()
        return try await withCheckedThrowingContinuation { continuation in
            gate.set(continuation)
            session.sendMessage(
                WatchSyncCoding.refreshRequestMessage,
                replyHandler: { message in
                    if let reply = WatchSyncCoding.reply(from: message) {
                        gate.resume(.success(reply))
                    } else {
                        gate.resume(.failure(WatchPhoneRelayError.invalidReply))
                    }
                },
                errorHandler: { error in
                    let code = (error as? WCError)?.code
                    gate.resume(.failure(code == .messageReplyTimedOut ? WatchPhoneRelayError.timedOut : WatchPhoneRelayError.unreachable))
                }
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.replyTimeout) {
                gate.resume(.failure(WatchPhoneRelayError.timedOut))
            }
        }
    }

    /// For the WatchConnectivity background task: returns once the session has handed over what
    /// was waiting (or after a few seconds).
    func waitForPendingContent() async {
        guard let session, session.activationState == .activated, session.hasContentPending else { return }
        await withCheckedContinuation { continuation in
            pendingContentWaiters.append(continuation)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.resumePendingContentWaiters() }
        }
    }

    fileprivate func deliver(_ payload: WatchSyncPayload) {
        onPayload?(payload)
        if session?.hasContentPending == false { resumePendingContentWaiters() }
    }

    fileprivate func resumePendingContentWaiters() {
        let waiters = pendingContentWaiters
        pendingContentWaiters = []
        waiters.forEach { $0.resume() }
    }
}

extension WatchPhoneLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error {
            Self.logger.error("session activation failed: \(String(describing: error), privacy: .public)")
        }
        Self.logger.notice("session: activation=\(activationState.rawValue, privacy: .public) reachable=\(session.isReachable, privacy: .public) companionInstalled=\(session.isCompanionAppInstalled, privacy: .public)")
        // The newest context may have arrived while the app wasn't running.
        let received = session.receivedApplicationContext
        let payload = WatchSyncCoding.payload(from: received)
        Self.logger.notice("stored application context: \(received.isEmpty ? "none" : (payload == nil ? "unreadable" : "settings"), privacy: .public)")
        Task { @MainActor in
            if let payload { self.deliver(payload) } else { self.resumePendingContentWaiters() }
            self.linkChanged("activated")
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.linkChanged("reachability") }
    }

    nonisolated func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
        Task { @MainActor in self.linkChanged("companion installed") }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let payload = WatchSyncCoding.payload(from: applicationContext) else {
            Self.logger.error("unreadable application context ignored")
            return
        }
        Self.logger.notice("application context received")
        Task { @MainActor in self.deliver(payload) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let payload = WatchSyncCoding.payload(from: userInfo) else { return }
        Task { @MainActor in self.deliver(payload) }
    }
}

/// Resumes a continuation with the first result only (reply, error or time-out).
private nonisolated final class ReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<WatchRelayReply, Error>?

    func set(_ continuation: CheckedContinuation<WatchRelayReply, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func resume(_ result: Result<WatchRelayReply, Error>) {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(with: result)
    }
}
