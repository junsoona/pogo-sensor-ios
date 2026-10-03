#if DEBUG
import Foundation
import XCTest
@testable import PogoHome

/// A hub's enrollment routes in memory: scripted answers, every request recorded (address, token,
/// certificate pin, session id, body values), and optionally held so a test can deliver an answer
/// late — after the screen was left or the source changed.
nonisolated final class FakeEnrollmentHub: PowerBaseEnrollmentTransport, @unchecked Sendable {
    struct Call: Equatable {
        enum Method: String { case start = "POST", status = "GET", cancel = "DELETE" }
        let method: Method
        let baseURL: URL
        let hubID: String
        let token: String
        let pinnedCertificate: String
        let sessionID: String?
        let eui64: String?
        let pskd: String?
    }

    private let lock = NSLock()
    private var calls: [Call] = []
    private var startReplies: [Result<PowerBaseEnrollmentSession, PowerBaseEnrollmentError>] = []
    /// Each GET takes the next one; the last one repeats.
    private var statusReplies: [Result<PowerBaseEnrollmentSession, PowerBaseEnrollmentError>] = []
    private var cancelReplies: [Result<PowerBaseEnrollmentSession, PowerBaseEnrollmentError>] = []
    private var holdsStarts = false
    private var holdsStatus = false
    private var held: [CheckedContinuation<Void, Never>] = []

    func scriptStart(_ reply: Result<PowerBaseEnrollmentSession, PowerBaseEnrollmentError>) {
        lock.withLock { startReplies.append(reply) }
    }

    func scriptStatus(_ replies: Result<PowerBaseEnrollmentSession, PowerBaseEnrollmentError>...) {
        lock.withLock { statusReplies.append(contentsOf: replies) }
    }

    /// From now on every GET answers `reply`, whatever was scripted before.
    func replaceStatus(_ reply: Result<PowerBaseEnrollmentSession, PowerBaseEnrollmentError>) {
        lock.withLock { statusReplies = [reply] }
    }

    func scriptCancel(_ reply: Result<PowerBaseEnrollmentSession, PowerBaseEnrollmentError>) {
        lock.withLock { cancelReplies.append(reply) }
    }

    func holdStarts() { lock.withLock { holdsStarts = true } }
    func holdStatus() { lock.withLock { holdsStatus = true } }

    var heldCount: Int { lock.withLock { held.count } }

    func releaseHeld() {
        let waiting = lock.withLock {
            holdsStarts = false
            holdsStatus = false
            defer { held.removeAll() }
            return held
        }
        waiting.forEach { $0.resume() }
    }

    var recorded: [Call] { lock.withLock { calls } }

    func recorded(_ method: Call.Method) -> [Call] { recorded.filter { $0.method == method } }

    private func record(_ call: Call) { lock.withLock { calls.append(call) } }

    private func waitIfHeld(_ holds: @escaping () -> Bool) async {
        await withCheckedContinuation { continuation in
            let isHeld = lock.withLock {
                if holds() { held.append(continuation) }
                return holds()
            }
            if !isHeld { continuation.resume() }
        }
    }

    func start(baseURL: URL, credential: HubCredential, eui64: String, pskd: String) async throws -> PowerBaseEnrollmentSession {
        record(Call(method: .start, baseURL: baseURL, hubID: credential.hubID, token: credential.token, pinnedCertificate: credential.certificateSHA256, sessionID: nil, eui64: eui64, pskd: pskd))
        await waitIfHeld { self.holdsStarts }
        let reply = lock.withLock { startReplies.isEmpty ? nil : startReplies.removeFirst() }
        guard let reply else { throw PowerBaseEnrollmentError.unreachable("unscripted") }
        return try reply.get()
    }

    func status(baseURL: URL, credential: HubCredential, sessionID: String) async throws -> PowerBaseEnrollmentSession {
        record(Call(method: .status, baseURL: baseURL, hubID: credential.hubID, token: credential.token, pinnedCertificate: credential.certificateSHA256, sessionID: sessionID, eui64: nil, pskd: nil))
        await waitIfHeld { self.holdsStatus }
        let reply = lock.withLock { () -> Result<PowerBaseEnrollmentSession, PowerBaseEnrollmentError>? in
            guard let first = statusReplies.first else { return nil }
            if statusReplies.count > 1 { statusReplies.removeFirst() }
            return first
        }
        guard let reply else { throw PowerBaseEnrollmentError.unreachable("unscripted") }
        return try reply.get()
    }

    func cancel(baseURL: URL, credential: HubCredential, sessionID: String) async throws -> PowerBaseEnrollmentSession {
        record(Call(method: .cancel, baseURL: baseURL, hubID: credential.hubID, token: credential.token, pinnedCertificate: credential.certificateSHA256, sessionID: sessionID, eui64: nil, pskd: nil))
        let reply = lock.withLock { cancelReplies.isEmpty ? nil : cancelReplies.removeFirst() }
        guard let reply else { throw PowerBaseEnrollmentError.unreachable("unscripted") }
        return try reply.get()
    }
}

struct ConditionTimeout: Error {}

/// Waits until `condition` holds; fails the test (and throws, ending it) when it doesn't within
/// `timeout`. Unlike the `Bool`-returning `waitUntil(_:)` overload, a timeout can't go unnoticed.
@MainActor
func eventually(timeout: Duration = .seconds(3), file: StaticString = #filePath, line: UInt = #line, _ condition: @MainActor () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    guard condition() else {
        XCTFail("condition not met within \(timeout)", file: file, line: line)
        throw ConditionTimeout()
    }
}

@MainActor
final class FakeEnrollmentClipboard: PowerBaseEnrollmentClipboard {
    private(set) var copied: [String] = []
    private(set) var clearCount = 0
    var current: String?

    func copySecret(_ value: String, expiresAt: Date?) {
        copied.append(value)
        current = value
    }

    func clearSecretIfUnchanged() {
        clearCount += 1
        current = nil
    }
}

enum EnrollmentFixtures {
    static let hubA = String(repeating: "a", count: 32)
    static let hubB = String(repeating: "b", count: 32)
    static let urlA = URL(string: "http://192.168.1.10:8787")!
    static let urlAMoved = URL(string: "http://192.168.1.77:8787")!
    static let urlB = URL(string: "http://192.168.1.20:8787")!
    static let deviceID = "0123456789abcdef"
    /// A made-up EUI-64; the real spare board's value is typed by the tester, never written down.
    static let eui64 = "00124b0001a2b3c4"
    static let sessionID = "5f0c1d2e3f405162738495a6b7c8d9e0"
    static let otherSessionID = "0f1e2d3c4b5a69788796a5b4c3d2e1f0"

    static func credential(hubID: String = hubA, token: String = "token-A", certificate: String = String(repeating: "c", count: 64)) -> HubCredential {
        HubCredential(hubID: hubID, deviceID: deviceID, token: token, certificateSHA256: certificate, pairedAt: Date(timeIntervalSince1970: 0))
    }

    static func session(
        _ state: PowerBaseEnrollmentSession.State, id: String = sessionID, expiresInMs: Int64 = 118_250,
        error: String? = nil, joinerEntry: String = "allowed"
    ) -> PowerBaseEnrollmentSession {
        PowerBaseEnrollmentSession(
            sessionID: id, eui64: eui64, state: state, finished: state.isFinal, joinerEntry: joinerEntry, error: error,
            windowSeconds: 120, createdAtUnixMs: 1_790_000_000_000, expiresAtUnixMs: 1_790_000_120_000,
            expiresInMs: state.isFinal ? 0 : expiresInMs,
            heartbeatReceivedAtUnixMs: state == .heartbeatReceived ? 1_790_000_030_000 : nil,
            startedByDeviceID: deviceID
        )
    }

    static func pairedTarget(hubID: String = hubA, url: URL = urlA) -> PowerBaseEnrollmentController.Target {
        .init(hubID: hubID, baseURL: url, isSimulated: false, isPaired: true)
    }
}
#endif
