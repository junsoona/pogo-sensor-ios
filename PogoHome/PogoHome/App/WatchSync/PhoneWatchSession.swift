import Foundation
import os
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// One reading of the iPhone's WatchConnectivity session, in plain values, so `PhoneWatchRelay`'s
/// rules are unit-tested without a paired Watch.
nonisolated struct PhoneWatchSessionReading: Equatable, Sendable, CustomStringConvertible {
    enum Activation: String, Sendable {
        case notActivated
        /// Switching to another Watch.
        case inactive
        case activated
    }

    var activation: Activation
    /// Meaningful only once `activation == .activated`; before that WatchConnectivity reports
    /// `false`, which must not be read as "no Watch" or "not installed".
    var isPaired: Bool
    var isWatchAppInstalled: Bool
    /// The Watch app is running in the foreground.
    var isReachable: Bool

    static let notActivated = PhoneWatchSessionReading(activation: .notActivated, isPaired: false, isWatchAppInstalled: false, isReachable: false)

    var description: String {
        "activation=\(activation.rawValue) paired=\(isPaired) installed=\(isWatchAppInstalled) reachable=\(isReachable)"
    }
}

/// Why `PhoneWatchRelay` reads the session again.
nonisolated enum PhoneWatchSessionEvent: String, Sendable {
    case activationCompleted
    /// Paired Watch, Watch app installed or complication changed.
    case watchStateChanged
    case reachabilityChanged
    /// The user is switching to another Watch.
    case becameInactive
    /// The switch finished; the session activates again for the new Watch.
    case deactivated
    /// The app came to the foreground (or Settings showed the state): a missed callback can't keep
    /// an old reading forever.
    case recheck
    /// The Watch asked for the current state — it is evidently installed and running.
    case watchRequest
}

/// What `PhoneWatchRelay` uses of `WCSession`; a scripted session in tests.
@MainActor
protocol PhoneWatchSession: AnyObject {
    /// Called on the main actor for every session callback.
    var onEvent: (@MainActor (PhoneWatchSessionEvent) -> Void)? { get set }
    /// Answers the Watch's refresh request.
    var onRefreshRequest: (@MainActor () async -> [String: Any])? { get set }
    var reading: PhoneWatchSessionReading { get }
    func activate()
    func updateApplicationContext(_ context: [String: Any]) throws
    /// Queues `userInfo` as a complication update if a complication is on the face and today's
    /// budget allows. Returns whether it was queued.
    func transferComplicationUserInfo(_ userInfo: [String: Any]) -> Bool
}

#if canImport(WatchConnectivity)
/// `WCSession.default`, with its delegate callbacks carried to the main actor. `WCSession` holds
/// its delegate weakly; `PhoneWatchRelay` keeps this object alive for the app's lifetime.
final class WCPhoneWatchSession: NSObject, PhoneWatchSession {
    var onEvent: (@MainActor (PhoneWatchSessionEvent) -> Void)?
    var onRefreshRequest: (@MainActor () async -> [String: Any])?

    private let session: WCSession

    private nonisolated static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.junsoona.PogoHome",
        category: "WatchRelay"
    )

    /// `nil` where WatchConnectivity isn't supported (iPad, Mac).
    static func makeIfSupported() -> WCPhoneWatchSession? {
        WCSession.isSupported() ? WCPhoneWatchSession(session: .default) : nil
    }

    private init(session: WCSession) {
        self.session = session
        super.init()
    }

    var reading: PhoneWatchSessionReading {
        let activation: PhoneWatchSessionReading.Activation
        switch session.activationState {
        case .activated: activation = .activated
        case .inactive: activation = .inactive
        case .notActivated: activation = .notActivated
        @unknown default: activation = .notActivated
        }
        guard activation == .activated else { return PhoneWatchSessionReading(activation: activation, isPaired: false, isWatchAppInstalled: false, isReachable: false) }
        return PhoneWatchSessionReading(
            activation: activation,
            isPaired: session.isPaired,
            isWatchAppInstalled: session.isWatchAppInstalled,
            isReachable: session.isReachable
        )
    }

    func activate() {
        session.delegate = self
        session.activate()
    }

    func updateApplicationContext(_ context: [String: Any]) throws {
        try session.updateApplicationContext(context)
    }

    func transferComplicationUserInfo(_ userInfo: [String: Any]) -> Bool {
        guard session.isComplicationEnabled, session.remainingComplicationUserInfoTransfers > 0 else { return false }
        session.transferCurrentComplicationUserInfo(userInfo)
        return true
    }

    private nonisolated func post(_ event: PhoneWatchSessionEvent) {
        Task { @MainActor in self.onEvent?(event) }
    }
}

extension WCPhoneWatchSession: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error {
            Self.logger.error("watch session activation failed: \(String(describing: error), privacy: .public)")
        }
        post(.activationCompleted)
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        post(.watchStateChanged)
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        post(.reachabilityChanged)
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        post(.becameInactive)
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // The user switched to another Watch: start over with it.
        session.activate()
        post(.deactivated)
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let reply = WatchReplyHandler(replyHandler)
        guard WatchSyncCoding.isRefreshRequest(message) else {
            reply.send([:])
            return
        }
        Task { @MainActor in
            self.onEvent?(.watchRequest)
            reply.send(await self.onRefreshRequest?() ?? [:])
        }
    }
}

/// WatchConnectivity's reply handler, carried to the main actor. It is called exactly once.
private nonisolated final class WatchReplyHandler: @unchecked Sendable {
    private let handler: ([String: Any]) -> Void

    init(_ handler: @escaping ([String: Any]) -> Void) {
        self.handler = handler
    }

    func send(_ message: [String: Any]) {
        handler(message)
    }
}
#endif
