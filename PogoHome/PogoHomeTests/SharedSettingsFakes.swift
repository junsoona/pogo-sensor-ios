import Foundation
import XCTest
@testable import PogoHome

/// A hub's settings API in memory, with the rules of the Linux `SettingsStore`/`DeviceAuth`:
/// server-assigned revisions, a first upload only while empty, conflicts carrying the current
/// settings, per-device tokens that can be revoked. Several `SharedSettingsController`s (one per
/// simulated iPhone/iPad/Mac) talk to the same instance.
nonisolated final class FakeSettingsHub: HubSettingsTransport, @unchecked Sendable {
    let hubID: String
    let certificate = String(repeating: "c", count: 64)
    private let lock = NSLock()
    private var settingsID = "0123456789abcdef"
    private var revisionNumber = 0
    private var document: HubSettingsDocument?
    private var tokens: [String: String] = [:] // token -> device id
    private var validCode: String?
    private(set) var putCount = 0
    private(set) var fetchCount = 0
    var isReachable = true
    var failsNextSave = false
    var settingsUnavailable = false
    /// While true, settings fetches wait (a check still under way) until `releaseFetches()`.
    private var holdsFetches = false
    private var heldFetches: [CheckedContinuation<Void, Never>] = []

    init(hubID: String = String(repeating: "a", count: 32)) {
        self.hubID = hubID
    }

    var revision: String? { lock.withLock { document == nil ? nil : "\(settingsID)-\(revisionNumber)" } }
    var currentDocument: HubSettingsDocument? { lock.withLock { document } }

    func createCode() -> String {
        lock.withLock {
            validCode = "7KQM3XWDPA9T"
            return "7kqm-3xwd-pa9t"
        }
    }

    func revokeAll() { lock.withLock { tokens.removeAll() } }

    func holdFetches() { lock.withLock { holdsFetches = true } }

    var heldFetchCount: Int { lock.withLock { heldFetches.count } }

    /// Lets the held fetches answer, with the settings as they are then.
    func releaseFetches() {
        let waiting = lock.withLock {
            holdsFetches = false
            defer { heldFetches.removeAll() }
            return heldFetches
        }
        waiting.forEach { $0.resume() }
    }

    /// Resets the hub's settings (the operator removed settings.json): a new settings id.
    func removeSettings() {
        lock.withLock {
            document = nil
            revisionNumber = 0
            settingsID = "fedcba9876543210"
        }
    }

    private func state() -> HubSettingsState {
        HubSettingsState(
            schemaVersion: 1, hubID: hubID, initialized: document != nil,
            revision: document == nil ? nil : "\(settingsID)-\(revisionNumber)",
            updatedAtUnixMs: 1, settings: document
        )
    }

    private func check(_ credential: HubCredential) throws {
        guard isReachable else { throw HubSettingsError.unreachable("offline") }
        guard credential.certificateSHA256 == certificate else { throw HubSettingsError.certificateMismatch }
        guard tokens[credential.token] != nil else { throw HubSettingsError.unauthorized }
        if settingsUnavailable { throw HubSettingsError.unavailable(reason: "corrupt") }
    }

    func fetchSettings(baseURL: URL, credential: HubCredential) async throws -> HubSettingsState {
        await withCheckedContinuation { continuation in
            let held = lock.withLock {
                if holdsFetches { heldFetches.append(continuation) }
                return holdsFetches
            }
            if !held { continuation.resume() }
        }
        return try lock.withLock {
            fetchCount += 1
            try check(credential)
            return state()
        }
    }

    func putSettings(baseURL: URL, credential: HubCredential, baseRevision: String?, settings: HubSettingsDocument) async throws -> HubSettingsState {
        try lock.withLock {
            try check(credential)
            let current = document == nil ? nil : "\(settingsID)-\(revisionNumber)"
            guard baseRevision == current else { throw HubSettingsError.conflict(current: state()) }
            let roomIDs = Set(settings.rooms.map(\.id))
            for module in settings.modules where module.roomID.map({ !roomIDs.contains($0) }) ?? false {
                throw HubSettingsError.invalid(detail: "unknown_room_id")
            }
            if failsNextSave {
                failsNextSave = false
                throw HubSettingsError.saveFailed
            }
            putCount += 1
            document = settings
            revisionNumber += 1
            return state()
        }
    }

    func pair(baseURL: URL, hubID: String, code: String, deviceName: String) async throws -> HubCredential {
        try lock.withLock {
            guard isReachable else { throw HubSettingsError.unreachable("offline") }
            guard let validCode else { throw HubSettingsError.pairingRejected(reason: "no_active_code") }
            guard code == validCode else { throw HubSettingsError.pairingRejected(reason: "bad_proof") }
            self.validCode = nil
            let token = UUID().uuidString
            let deviceID = String(UUID().uuidString.prefix(16)).lowercased()
            tokens[token] = deviceID
            return HubCredential(hubID: hubID, deviceID: deviceID, token: token, certificateSHA256: certificate, pairedAt: Date())
        }
    }

    func unpair(baseURL: URL, credential: HubCredential) async throws {
        try lock.withLock {
            try check(credential)
            tokens.removeValue(forKey: credential.token)
        }
    }
}

/// A data source the test pushes snapshots through, like SSE events.
@MainActor
final class PushedSnapshotSource: SensorDataSource {
    private var continuation: AsyncStream<HomeSnapshot>.Continuation?
    private var pending: [HomeSnapshot] = []

    func currentSnapshot() async throws -> HomeSnapshot {
        pending.last ?? HomeSnapshot(timestamp: Date(), rooms: [], modules: [])
    }

    func updates() -> AsyncStream<HomeSnapshot> {
        AsyncStream { continuation in
            self.continuation = continuation
            for snapshot in pending { continuation.yield(snapshot) }
            pending.removeAll()
        }
    }

    func push(_ snapshot: HomeSnapshot) {
        if let continuation {
            continuation.yield(snapshot)
        } else {
            pending.append(snapshot)
        }
    }
}

enum SharedSettingsFixtures {
    static let gasSensor = "744dbdfffe65d357"
    static let dustSensor = "744dbdfffe65d07a"
    static let otherHubSensor = "0011223344556677"
    static let hubURL = URL(string: "http://192.168.50.129:8787")!

    /// A hub snapshot through the real decoder, with the additive settings fields.
    static func snapshot(modules: [String], settingsRevision: String?, settingsState: String = "ready") -> HomeSnapshot {
        let moduleJSON = modules.map { raw in
            """
            {"uuid":"\(raw)","power_base_uuid":"744dbdfffe650a00","parent_uuid":"744dbdfffe650a00","online":true,"depth":1,"role":"leaf","sensor_bitmap":6,"generation":1,"last_seq":1,"readings":[{"kind":"temperature","raw_value":23400,"scale":1,"value":23.4,"unit":"celsius","status":"ok","sample_seq":1}]}
            """
        }.joined(separator: ",")
        let revision = settingsRevision.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"schema_version":1,"generated_at_unix_ms":1790000000000,"registry_generation":1,"power_bases":[{"uuid":"744dbdfffe650a00","online":true,"module_count":\(modules.count),"online_module_count":\(modules.count)}],"modules":[\(moduleJSON)],"settings_api":1,"settings_state":"\(settingsState)","settings_revision":\(revision)}
        """
        return try! PogoSnapshotMapper.decodeSnapshot(from: Data(json.utf8))
    }

    static func moduleID(_ raw: String) -> UUID {
        ModuleIdentity.stableUUID(forRawIdentifier: raw)
    }
}

/// One simulated iPhone/iPad/Mac: its own on-device store, Keychain and cache, sharing one hub.
@MainActor
struct SimulatedDevice {
    let model: AppModel
    let source: PushedSnapshotSource
    let localStore: InMemoryHomeConfigurationStore
    let credentials: InMemoryHubCredentialStore
    let cache: InMemorySharedSettingsCache

    init(
        hub: FakeSettingsHub,
        localStore: InMemoryHomeConfigurationStore = InMemoryHomeConfigurationStore(language: .korean),
        credentials: InMemoryHubCredentialStore = InMemoryHubCredentialStore(),
        cache: InMemorySharedSettingsCache = InMemorySharedSettingsCache(),
        initial: HomeSnapshot? = nil
    ) {
        let source = PushedSnapshotSource()
        let controller = SharedSettingsController(transport: hub, credentials: credentials, cache: cache, language: .korean, retryInterval: .zero)
        let initialSnapshot = initial ?? SharedSettingsFixtures.snapshot(modules: [SharedSettingsFixtures.gasSensor, SharedSettingsFixtures.dustSensor], settingsRevision: hub.revision)
        source.push(initialSnapshot)
        self.model = AppModel(
            dataSource: source,
            sourceIdentity: .hub(id: hub.hubID),
            sourceAddress: SharedSettingsFixtures.hubURL,
            initialSnapshot: initialSnapshot,
            configurationStore: localStore,
            sharedSettings: controller,
            language: .korean
        )
        self.source = source
        self.localStore = localStore
        self.credentials = credentials
        self.cache = cache
    }

    var controller: SharedSettingsController { model.sharedSettings }

    /// Sends a snapshot carrying the hub's current revision, as the hub's SSE does after a change.
    func receiveSnapshot(from hub: FakeSettingsHub, modules: [String] = [SharedSettingsFixtures.gasSensor, SharedSettingsFixtures.dustSensor]) {
        source.push(SharedSettingsFixtures.snapshot(modules: modules, settingsRevision: hub.revision))
    }
}

@MainActor
func waitUntil(_ description: String, timeout: Duration = .seconds(3), file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            XCTFail("timed out waiting for: \(description)", file: file, line: line)
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}
