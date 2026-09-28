import Foundation
@testable import PogoHome

/// Test doubles for hub discovery: a Bonjour browser the test feeds by hand, a resolver and a
/// `/health` transport answering per endpoint/URL. No real Bonjour or networking — what these
/// tests prove is the app's rules, not that a hub is found on a real network.
nonisolated enum HubFixtures {
    static let hubA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    static let hubB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    static let urlA = URL(string: "http://192.168.50.129:8787")!
    static let urlA2 = URL(string: "http://192.168.50.140:8787")!
    static let urlB = URL(string: "http://192.168.50.200:8787")!

    static func txt(hubID: String?, api: String? = "1", path: String? = "/api/v1") -> [String: String] {
        var txt: [String: String] = ["txtvers": "1"]
        txt["hub_id"] = hubID
        txt["api"] = api
        txt["path"] = path
        return txt
    }

    static func result(_ name: String, hubID: String?, key: String? = nil, api: String? = "1", path: String? = "/api/v1") -> HubBrowseResult {
        HubBrowseResult(
            serviceName: name,
            domain: "local.",
            txt: txt(hubID: hubID, api: api, path: path),
            endpoint: HubServiceEndpoint(key: key ?? name)
        )
    }

    static func health(hubID: String?, service: String = "pogohome", schema: Int = 1) -> Data {
        var fields = ["\"schema_version\":\(schema)", "\"service\":\"\(service)\"", "\"registry_generation\":3", "\"module_count\":1"]
        if let hubID { fields.append("\"hub_id\":\"\(hubID)\"") }
        return Data(("{" + fields.joined(separator: ",") + "}").utf8)
    }

    static func selection(_ hubID: String = hubA, url: URL = urlA, name: String = "Jogakbo Hub (pogo)") -> SelectedHub {
        SelectedHub(hubID: hubID, serviceName: name, baseURL: url.absoluteString, verifiedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }
}

/// Every `browse()` opens a session the test feeds with `send(_:)`; `activeSessions` counts the
/// ones whose consumer hasn't stopped.
nonisolated final class FakeHubBrowser: HubBrowsing, @unchecked Sendable {
    private final class Session: @unchecked Sendable {
        let continuation: AsyncStream<HubBrowseEvent>.Continuation
        var terminated = false
        init(_ continuation: AsyncStream<HubBrowseEvent>.Continuation) { self.continuation = continuation }
    }

    private let lock = NSLock()
    private var sessions: [Session] = []

    var browseCount: Int { lock.withLock { sessions.count } }
    var activeSessions: Int { lock.withLock { sessions.filter { !$0.terminated }.count } }

    func browse() -> AsyncStream<HubBrowseEvent> {
        AsyncStream { continuation in
            let session = Session(continuation)
            continuation.onTermination = { [weak self, session] _ in
                self?.lock.withLock { session.terminated = true }
            }
            lock.withLock { sessions.append(session) }
        }
    }

    /// To the newest session, or to session `index` (0-based, in `browse()` order).
    func send(_ event: HubBrowseEvent, session index: Int? = nil) {
        let target = lock.withLock { index.map { sessions[$0] } ?? sessions.last }
        target?.continuation.yield(event)
    }
}

/// Holds callers until `open()`.
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

nonisolated final class FakeHubResolver: HubServiceResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: Result<URL, HubVerificationError>]
    private var _resolveCount = 0
    let gate: AsyncGate?

    init(_ answers: [String: Result<URL, HubVerificationError>], gate: AsyncGate? = nil) {
        self.answers = answers
        self.gate = gate
    }

    var resolveCount: Int { lock.withLock { _resolveCount } }

    func set(_ key: String, _ answer: Result<URL, HubVerificationError>) {
        lock.withLock { answers[key] = answer }
    }

    func resolveBaseURL(_ endpoint: HubServiceEndpoint) async throws -> URL {
        lock.withLock { _resolveCount += 1 }
        if let gate { await gate.wait() }
        let answer = lock.withLock { answers[endpoint.key] }
        guard let answer else { throw HubVerificationError.resolveFailed("gone") }
        return try answer.get()
    }
}

/// Answers `GET <base>/api/v1/health` per base URL.
actor FakeHealthTransport: HubHealthFetching {
    private var bodies: [String: Data]
    private(set) var fetchedURLs: [URL] = []

    init(_ bodies: [URL: Data]) {
        self.bodies = Dictionary(uniqueKeysWithValues: bodies.map { ($0.key.absoluteString, $0.value) })
    }

    var fetchCount: Int { fetchedURLs.count }

    func fetchHealth(from url: URL) async throws -> Data {
        fetchedURLs.append(url)
        let base = url.absoluteString.replacingOccurrences(of: "/api/v1/health", with: "")
        guard let body = bodies[base] else { throw URLError(.cannotConnectToHost) }
        return body
    }
}
