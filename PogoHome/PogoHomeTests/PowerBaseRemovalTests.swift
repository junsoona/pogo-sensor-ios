import XCTest
@testable import PogoHome

/// A hub's removal routes in memory: scripted answers, every request recorded, optionally held so
/// an answer can arrive late.
nonisolated final class FakeRemovalHub: PowerBaseRemovalTransport, @unchecked Sendable {
    enum Call: Equatable {
        case request(hubID: String, token: String, pin: String, base: String)
        case list(hubID: String)
        case cancel(hubID: String, removalID: String)
        case receipt(hubID: String, token: String, pin: String, receiptHex: String)
        case forget(hubID: String, token: String, pin: String, base: String, record: String, requestID: String)
    }

    /// One removal request as it was sent: what it names and its own id.
    struct SentRequest: Equatable {
        let base: String
        let binding: PowerBaseRemovalBinding
        let requestID: String
    }

    private let lock = NSLock()
    private var calls: [Call] = []
    private var sent: [SentRequest] = []
    private var requestReplies: [Result<PowerBaseRemoval, PowerBaseRemovalError>] = []
    private var listReplies: [Result<[PowerBaseRemoval], PowerBaseRemovalError>] = []
    private var cancelReplies: [Result<PowerBaseRemoval, PowerBaseRemovalError>] = []
    private var receiptReplies: [Result<PowerBaseRemoval, PowerBaseRemovalError>] = []
    /// What the hub answers to a list removal: given the request, so that the answer can carry
    /// the request's own id, as the real hub's does.
    private var forgetReplies: [@Sendable (_ base: String, _ record: String, _ requestID: String) -> Result<PowerBaseForget, PowerBaseForgetError>] = []
    private var holds = false
    private var held: [CheckedContinuation<Void, Never>] = []

    var recorded: [Call] { lock.withLock { calls } }
    /// Every removal request, in the order it was sent, with the registration and the id it carried.
    var sentRequests: [SentRequest] { lock.withLock { sent } }
    func scriptRequest(_ reply: Result<PowerBaseRemoval, PowerBaseRemovalError>) { lock.withLock { requestReplies.append(reply) } }
    func scriptList(_ reply: Result<[PowerBaseRemoval], PowerBaseRemovalError>) { lock.withLock { listReplies.append(reply) } }
    func scriptCancel(_ reply: Result<PowerBaseRemoval, PowerBaseRemovalError>) { lock.withLock { cancelReplies.append(reply) } }
    func scriptReceipt(_ reply: Result<PowerBaseRemoval, PowerBaseRemovalError>) { lock.withLock { receiptReplies.append(reply) } }
    var receipts: [Call] { recorded.filter { if case .receipt = $0 { true } else { false } } }
    func scriptForget(_ reply: @escaping @Sendable (_ base: String, _ record: String, _ requestID: String) -> Result<PowerBaseForget, PowerBaseForgetError>) {
        lock.withLock { forgetReplies.append(reply) }
    }
    func scriptForget(_ reply: Result<PowerBaseForget, PowerBaseForgetError>) { scriptForget { _, _, _ in reply } }
    var forgets: [Call] { recorded.filter { if case .forget = $0 { true } else { false } } }
    func hold() { lock.withLock { holds = true } }
    var heldCount: Int { lock.withLock { held.count } }

    func release() {
        let waiting = lock.withLock {
            holds = false
            defer { held.removeAll() }
            return held
        }
        waiting.forEach { $0.resume() }
    }

    fileprivate func recordForgetCall(_ call: Call) { lock.withLock { calls.append(call) } }
    fileprivate func nextForgetReply() -> (@Sendable (String, String, String) -> Result<PowerBaseForget, PowerBaseForgetError>)? {
        lock.withLock { forgetReplies.isEmpty ? nil : forgetReplies.removeFirst() }
    }
    fileprivate func waitIfHeldForForget() async { await waitIfHeld() }

    private func waitIfHeld() async {
        await withCheckedContinuation { continuation in
            let isHeld = lock.withLock {
                if holds { held.append(continuation) }
                return holds
            }
            if !isHeld { continuation.resume() }
        }
    }

    func request(
        baseURL: URL, credential: HubCredential, powerBaseIdentifier: String, binding: PowerBaseRemovalBinding, requestID: String
    ) async throws -> PowerBaseRemoval {
        lock.withLock {
            calls.append(.request(hubID: credential.hubID, token: credential.token, pin: credential.certificateSHA256, base: powerBaseIdentifier))
            sent.append(SentRequest(base: powerBaseIdentifier, binding: binding, requestID: requestID))
        }
        await waitIfHeld()
        let reply = lock.withLock { requestReplies.isEmpty ? nil : requestReplies.removeFirst() }
        guard let reply else { throw PowerBaseRemovalError.unreachable("unscripted") }
        return try reply.get()
    }

    func list(baseURL: URL, credential: HubCredential) async throws -> [PowerBaseRemoval] {
        lock.withLock { calls.append(.list(hubID: credential.hubID)) }
        let reply = lock.withLock { listReplies.isEmpty ? nil : listReplies.removeFirst() }
        guard let reply else { throw PowerBaseRemovalError.unreachable("unscripted") }
        return try reply.get()
    }

    func cancel(baseURL: URL, credential: HubCredential, removalID: String) async throws -> PowerBaseRemoval {
        lock.withLock { calls.append(.cancel(hubID: credential.hubID, removalID: removalID)) }
        let reply = lock.withLock { cancelReplies.isEmpty ? nil : cancelReplies.removeFirst() }
        guard let reply else { throw PowerBaseRemovalError.unreachable("unscripted") }
        return try reply.get()
    }

    func submitReceipt(baseURL: URL, credential: HubCredential, receiptHex: String) async throws -> PowerBaseRemoval {
        lock.withLock { calls.append(.receipt(hubID: credential.hubID, token: credential.token, pin: credential.certificateSHA256, receiptHex: receiptHex)) }
        await waitIfHeld()
        let reply = lock.withLock { receiptReplies.isEmpty ? nil : receiptReplies.removeFirst() }
        guard let reply else { throw PowerBaseRemovalError.unreachable("unscripted") }
        return try reply.get()
    }
}

extension FakeRemovalHub {
    func forget(baseURL: URL, credential: HubCredential, powerBaseIdentifier: String, record: String, requestID: String) async throws -> PowerBaseForget {
        recordForgetCall(.forget(hubID: credential.hubID, token: credential.token, pin: credential.certificateSHA256, base: powerBaseIdentifier, record: record, requestID: requestID))
        await waitIfHeldForForget()
        guard let reply = nextForgetReply() else { throw PowerBaseForgetError.unreachable("unscripted") }
        return try reply(powerBaseIdentifier, record, requestID).get()
    }
}

extension PowerBaseRemovalController {
    /// A removal as the user confirms it in most tests: for the registration the fixtures' hub
    /// lists (`RemovalFixtures.binding`). Tests about the registration itself pass their own.
    func requestRemoval(of powerBaseIdentifier: String) {
        requestRemoval(of: powerBaseIdentifier, binding: RemovalFixtures.binding)
    }
}

enum RemovalFixtures {
    /// The registration every fixture snapshot and job is about (`json`'s `generation`), with no
    /// removal asked of it yet.
    static let record = String(repeating: "7e", count: 16)
    static let binding = PowerBaseRemovalBinding(record: record, serial: 0)
    static let hubA = String(repeating: "a", count: 32)
    static let hubB = String(repeating: "b", count: 32)
    static let url = URL(string: "http://192.168.1.10:8787")!
    /// Made-up EUI-64s.
    static let base = "00124b0001a2b3c4"
    static let otherBase = "00124b0001a2b3c5"
    static let removalID = "9f0c1d2e3f405162738495a6b7c8d9e0"
    static let otherRemovalID = "8f0c1d2e3f405162738495a6b7c8d9e1"

    static func credential(hubID: String = hubA) -> HubCredential {
        HubCredential(hubID: hubID, deviceID: "0123456789abcdef", token: "token-" + String(hubID.prefix(1)), certificateSHA256: String(repeating: "c", count: 64), pairedAt: Date(timeIntervalSince1970: 0))
    }

    static func target(hubID: String = hubA, isPaired: Bool = true, isSimulated: Bool = false) -> PowerBaseHubTarget {
        PowerBaseHubTarget(hubID: hubID, baseURL: url, isSimulated: isSimulated, isPaired: isPaired)
    }

    static func removal(
        _ state: PowerBaseRemoval.State, id: String = removalID, base: String = base, resultUnknown: Bool = false,
        affected: Int = 2, updatedAt: Date = Date(timeIntervalSince1970: 1_790_000_100)
    ) -> PowerBaseRemoval {
        PowerBaseRemoval(
            id: id, powerBaseIdentifier: base, state: state, resultUnknown: resultUnknown, cancellable: state == .pending,
            affectedModuleCount: affected, createdAt: Date(timeIntervalSince1970: 1_790_000_000), updatedAt: updatedAt
        )
    }

    static func json(_ state: String, id: String = removalID, base: String = base, extra: String = "") -> String {
        """
        {"removal_id":"\(id)","power_base_uuid":"\(base)","generation":"\(String(repeating: "7e", count: 16))","state":"\(state)","result_unknown":false,"cancellable":\(state == "pending"),"created_at_unix_ms":1790000000000,"updated_at_unix_ms":1790000100000,"affected_module_count":2\(extra)}
        """
    }

    static func snapshotJSON(bases: [String], removals: String?) -> Data {
        let removalsField = removals.map { ",\"power_base_removals\":[\($0)]" } ?? ""
        return Data("""
        {"schema_version":1,"generated_at_unix_ms":1790000200000,"registry_generation":9,"power_bases":[\(bases.joined(separator: ","))],"modules":[]\(removalsField)}
        """.utf8)
    }
}

// MARK: - Wire format

final class PowerBaseRemovalWireTests: XCTestCase {
    typealias Transport = URLSessionPowerBaseRemovalTransport

    /// The body is exactly the four members the hub asks for (firmware repository,
    /// `test_removal_api.cpp` posts the same text): the Base, the registration that was confirmed,
    /// that registration's removal serial and the id of the confirmation. Never the Base alone.
    func testTheRequestBodyNamesTheRegistrationItWasConfirmedFor() throws {
        let binding = PowerBaseRemovalBinding(record: RemovalFixtures.record, serial: 3)
        let body = try Transport.requestBody(powerBaseIdentifier: RemovalFixtures.base, binding: binding, requestID: String(repeating: "5a", count: 16))
        XCTAssertEqual(
            String(decoding: body, as: UTF8.self),
            #"{"power_base_uuid":"00124b0001a2b3c4","record":"7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e","removal_serial":3,"request_id":"5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a"}"#
        )
    }

    func testOnlyAWellFormedIdentifierLeavesTheDevice() {
        XCTAssertTrue(Transport.isValidPowerBaseIdentifier(RemovalFixtures.base))
        for bad in ["", "00124B0001A2B3C4", "00124b0001a2b3c", "00124b0001a2b3c4a", "0000000000000000", "00124b0001a2b3cg", "00124b0001a2b3c4\n"] {
            XCTAssertFalse(Transport.isValidPowerBaseIdentifier(bad), bad)
        }
    }

    func testDecodesEveryStateTheHubDocuments() throws {
        for (word, state) in [("pending", PowerBaseRemoval.State.pending), ("sent", .sent), ("accepted", .accepted), ("released", .released), ("completed", .completed), ("cancelled", .cancelled), ("superseded", .superseded)] {
            let removal = try Transport.decodeRemoval(Data(RemovalFixtures.json(word).utf8))
            XCTAssertEqual(removal.state, state)
            XCTAssertEqual(removal.id, RemovalFixtures.removalID)
            XCTAssertEqual(removal.powerBaseIdentifier, RemovalFixtures.base)
            XCTAssertEqual(removal.affectedModuleCount, 2)
            XCTAssertEqual(removal.cancellable, state == .pending, "only a waiting job can be cancelled")
        }
    }

    func testAJobTheAppCannotReadIsNotShownAsSomethingElse() {
        XCTAssertThrowsError(try Transport.decodeRemoval(Data(RemovalFixtures.json("erasing").utf8)), "a state from a newer hub")
        XCTAssertThrowsError(try Transport.decodeRemoval(Data(RemovalFixtures.json("pending", id: "xyz").utf8)))
        XCTAssertThrowsError(try Transport.decodeRemoval(Data(RemovalFixtures.json("pending", base: "not-a-base").utf8)))
        XCTAssertThrowsError(try Transport.decodeRemoval(Data("{}".utf8)))
    }

    func testTheHubNotTheStateDecidesWhatCanBeCancelled() throws {
        // A hub that calls a `sent` job cancellable is not believed; one that calls a `pending`
        // job not cancellable is.
        let sent = RemovalFixtures.json("sent").replacingOccurrences(of: "\"cancellable\":false", with: "\"cancellable\":true")
        XCTAssertFalse(try Transport.decodeRemoval(Data(sent.utf8)).cancellable)
        let pending = RemovalFixtures.json("pending").replacingOccurrences(of: "\"cancellable\":true", with: "\"cancellable\":false")
        XCTAssertFalse(try Transport.decodeRemoval(Data(pending.utf8)).cancellable)
    }

    func testReleasedIsNotCompletedAndTheSettingsCleanupIsAThirdThing() throws {
        let released = try Transport.decodeRemoval(Data(RemovalFixtures.json("released").utf8))
        XCTAssertEqual(released.state, .released)
        XCTAssertFalse(released.state.isFinal, "a released job is not over: the erase is not confirmed")
        XCTAssertEqual(released.presentation, .awaitingEraseConfirmation)
        XCTAssertNotEqual(released.presentation, .completed)
        XCTAssertFalse(released.cancellable)
        XCTAssertFalse(released.settingsCleanupPending, "a hub that does not say so owes no clean-up")

        let owing = try Transport.decodeRemoval(Data(RemovalFixtures.json("released", extra: #","settings_cleanup_pending":true"#).utf8))
        XCTAssertEqual(owing.state, .released, "the clean-up changes nothing about the removal's own state")
        XCTAssertTrue(owing.settingsCleanupPending)
        let completedOwing = try Transport.decodeRemoval(Data(RemovalFixtures.json("completed", extra: #","settings_cleanup_pending":true"#).utf8))
        XCTAssertEqual(completedOwing.presentation, .completed)
        XCTAssertTrue(completedOwing.settingsCleanupPending, "completed and clean-up pending can both be true")
    }

    func testAReceiptIsRelayedAsExactlyItsHexDigits() throws {
        let hex = String(repeating: "0a", count: 96)
        XCTAssertEqual(String(decoding: try Transport.receiptBody(receiptHex: hex), as: UTF8.self), #"{"receipt":""# + hex + #""}"#)
        XCTAssertTrue(Transport.isValidReceiptHex(hex))
        for bad in ["", String(repeating: "0a", count: 95), String(repeating: "0a", count: 97), String(repeating: "0A", count: 96), String(repeating: "0g", count: 96)] {
            XCTAssertFalse(Transport.isValidReceiptHex(bad), "\(bad.count) characters")
        }
    }

    func testResultUnknownIsNotAStateOfItsOwn() throws {
        let json = RemovalFixtures.json("sent").replacingOccurrences(of: "\"result_unknown\":false", with: "\"result_unknown\":true")
        let removal = try Transport.decodeRemoval(Data(json.utf8))
        XCTAssertEqual(removal.state, .sent)
        XCTAssertEqual(removal.presentation, .resultUnknown)
        XCTAssertFalse(removal.state.isFinal, "a late proof still completes it")
    }

    func testEveryDocumentedErrorAnswerHasItsOwnMeaning() {
        func error(_ status: Int, _ body: String) -> PowerBaseRemovalError { Transport.error(status: status, data: Data(body.utf8)) }
        XCTAssertEqual(error(401, #"{"error":"unauthorized"}"#), .unauthorized)
        XCTAssertEqual(error(403, #"{"error":"tls_required"}"#), .forbidden("tls_required"))
        XCTAssertEqual(error(404, #"{"error":"removal_disabled"}"#), .notSupported)
        XCTAssertEqual(error(404, #"{"error":"not_found"}"#), .notSupported, "a hub older than the routes")
        XCTAssertEqual(error(404, "<html>"), .notSupported)
        XCTAssertEqual(error(404, #"{"error":"unknown_power_base"}"#), .unknownPowerBase)
        XCTAssertEqual(error(404, #"{"error":"removal_not_found"}"#), .removalNotFound)
        XCTAssertEqual(error(409, #"{"error":"power_base_management_unsupported"}"#), .managementUnsupported)
        XCTAssertEqual(error(409, #"{"error":"enrollment_in_progress"}"#), .enrollmentInProgress)
        XCTAssertEqual(error(409, #"{"error":"removal_capacity_full","limit":"64"}"#), .capacityFull)
        XCTAssertEqual(error(409, #"{"error":"receipt_rejected"}"#), .receiptRejected)
        XCTAssertEqual(error(422, #"{"error":"invalid_receipt"}"#), .rejected("invalid_receipt"))
        XCTAssertFalse(PowerBaseRemovalError.capacityFull.isTransient, "asking again later does not help")
        XCTAssertFalse(PowerBaseRemovalError.receiptRejected.isTransient)
        XCTAssertEqual(error(422, #"{"error":"invalid_power_base_uuid"}"#), .rejected("invalid_power_base_uuid"))
        XCTAssertEqual(error(503, #"{"error":"too_many_removals"}"#), .unavailable("too_many_removals"))
        XCTAssertEqual(error(503, #"{"error":"removal_unavailable","reason":"storage"}"#), .unavailable("storage"))
        XCTAssertEqual(error(500, "{}"), .badResponse("HTTP 500"))
        XCTAssertEqual(error(409, "{}"), .badResponse("HTTP 409"), "never a guess")

        let refused = error(409, #"{"error":"removal_not_cancellable","removal":\#(RemovalFixtures.json("accepted"))}"#)
        guard case let .notCancellable(current?) = refused else { return XCTFail("\(refused)") }
        XCTAssertEqual(current.state, .accepted, "the refusal carries what the job is now")
    }
}

// MARK: - Snapshot

@MainActor
final class PowerBaseRemovalSnapshotTests: XCTestCase {
    private func base(_ uuid: String, online: Bool = true, management: String? = nil) -> String {
        // A Base the hub can remove says which registration it lists and how many removals were
        // asked of it (Linux bridge 0.5.0).
        let binding = management == "supported" ? ",\"record\":\"\(RemovalFixtures.record)\",\"removal_serial\":0" : ""
        let field = (management.map { ",\"management\":\"\($0)\"" } ?? "") + binding
        return "{\"uuid\":\"\(uuid)\",\"online\":\(online),\"module_count\":0,\"online_module_count\":0\(field)}"
    }

    func testAHubWithoutManagementSaysNothingAndTheAppDoesNotAssumeIt() throws {
        let snapshot = try PogoSnapshotMapper.decodeSnapshot(from: RemovalFixtures.snapshotJSON(bases: [base(RemovalFixtures.base)], removals: nil))
        XCTAssertFalse(snapshot.reportsPowerBaseManagement)
        XCTAssertEqual(snapshot.powerBases.first?.management, .unknown)
        XCTAssertTrue(snapshot.powerBaseRemovals.isEmpty)
        let availability = PowerBaseManagementPresentation.availability(base: snapshot.powerBases.first, snapshot: snapshot, target: RemovalFixtures.target(), removal: nil)
        XCTAssertEqual(availability, .hubUnsupported, "no removal is offered through a hub that cannot do it")
    }

    func testManagementSupportIsReadPerBase() throws {
        let snapshot = try PogoSnapshotMapper.decodeSnapshot(from: RemovalFixtures.snapshotJSON(
            bases: [base(RemovalFixtures.base, management: "supported"), base(RemovalFixtures.otherBase, management: "unsupported"), base("00124b0001a2b3c6", management: "later-word")],
            removals: ""
        ))
        XCTAssertTrue(snapshot.reportsPowerBaseManagement, "an empty list is still a hub with management")
        XCTAssertEqual(snapshot.powerBases.map(\.management), [.supported, .unsupported, .unknown])
        let target = RemovalFixtures.target()
        XCTAssertEqual(PowerBaseManagementPresentation.availability(base: snapshot.powerBases[0], snapshot: snapshot, target: target, removal: nil), .available)
        XCTAssertEqual(PowerBaseManagementPresentation.availability(base: snapshot.powerBases[1], snapshot: snapshot, target: target, removal: nil), .powerBaseUnsupported)
        XCTAssertEqual(PowerBaseManagementPresentation.availability(base: snapshot.powerBases[2], snapshot: snapshot, target: target, removal: nil), .powerBaseUnsupported,
                       "a word the app does not know is not taken for support")
    }

    func testTheSnapshotsJobsAreShownPerBaseAndUnreadableOnesAreLeftOut() throws {
        let removals = [
            RemovalFixtures.json("pending"),
            RemovalFixtures.json("erasing", id: RemovalFixtures.otherRemovalID, base: RemovalFixtures.otherBase),
        ].joined(separator: ",")
        let snapshot = try PogoSnapshotMapper.decodeSnapshot(from: RemovalFixtures.snapshotJSON(
            bases: [base(RemovalFixtures.base, online: false, management: "supported"), base(RemovalFixtures.otherBase, management: "supported")], removals: removals
        ))
        XCTAssertEqual(snapshot.powerBaseRemovals.count, 1, "the rest of the snapshot is still read")
        XCTAssertEqual(snapshot.removal(forPowerBase: RemovalFixtures.base)?.presentation, .waitingForPowerBase)
        XCTAssertNil(snapshot.removal(forPowerBase: RemovalFixtures.otherBase))
        XCTAssertEqual(snapshot.powerBases.first?.isOnline, false, "a Base waiting for its removal is still listed, offline")
    }

    func testTheOpenJobOfABaseWinsOverAnEarlierFinishedOne() {
        let old = RemovalFixtures.removal(.cancelled, id: RemovalFixtures.otherRemovalID, updatedAt: Date(timeIntervalSince1970: 1_790_000_900))
        let open = RemovalFixtures.removal(.pending, updatedAt: Date(timeIntervalSince1970: 1_790_000_100))
        let snapshot = HomeSnapshot(timestamp: Date(timeIntervalSince1970: 1_790_001_000), rooms: [], modules: [], powerBaseRemovals: [old, open], reportsPowerBaseManagement: true)
        XCTAssertEqual(snapshot.removal(forPowerBase: RemovalFixtures.base)?.id, RemovalFixtures.removalID)
        XCTAssertEqual(PowerBaseRemovalController.byPowerBase([old, open])[RemovalFixtures.base]?.id, RemovalFixtures.removalID)
        XCTAssertEqual(PowerBaseRemovalController.byPowerBase([open, old])[RemovalFixtures.base]?.id, RemovalFixtures.removalID)
    }

    func testJobsOfBasesTheHubNoLongerListsStayVisibleWhileTheyMatter() {
        let now = Date(timeIntervalSince1970: 1_790_010_000)
        func snapshot(_ removals: [PowerBaseRemoval], bases: [PowerBase] = []) -> HomeSnapshot {
            HomeSnapshot(timestamp: now, rooms: [], modules: [], powerBases: bases, reportsPowerBases: true, powerBaseRemovals: removals, reportsPowerBaseManagement: true)
        }
        typealias P = PowerBaseManagementPresentation
        // Open jobs: always.
        for state in [PowerBaseRemoval.State.pending, .sent, .accepted, .released] {
            XCTAssertEqual(P.openRemovalsWithoutPowerBase(in: snapshot([RemovalFixtures.removal(state, updatedAt: now.addingTimeInterval(-90_000))])).count, 1, "\(state)")
        }
        // A released Base is gone from the hub's list for good; its job is how the user gets to
        // "삭제 확인", however long ago it was released.
        XCTAssertEqual(P.openRemovalsWithoutPowerBase(in: snapshot([RemovalFixtures.removal(.released, updatedAt: now.addingTimeInterval(-90 * 86_400))])).count, 1)
        // A completed one is over: it is not listed, however recent (the user is told once, when it ends).
        XCTAssertTrue(P.openRemovalsWithoutPowerBase(in: snapshot([RemovalFixtures.removal(.completed, updatedAt: now.addingTimeInterval(-60))])).isEmpty)
        XCTAssertTrue(P.openRemovalsWithoutPowerBase(in: snapshot([RemovalFixtures.removal(.completed, updatedAt: now.addingTimeInterval(-7200))])).isEmpty)
        // Ended without changing anything: nothing to list.
        XCTAssertTrue(P.openRemovalsWithoutPowerBase(in: snapshot([RemovalFixtures.removal(.cancelled, updatedAt: now), RemovalFixtures.removal(.superseded, base: RemovalFixtures.otherBase, updatedAt: now)])).isEmpty)
        // A Base that is listed shows its job in its own row instead.
        let listed = PowerBase(hardwareIdentifier: RemovalFixtures.base, isOnline: false, moduleCount: 0, onlineModuleCount: 0, management: .supported, record: RemovalFixtures.record, removalSerial: 0)
        XCTAssertTrue(P.openRemovalsWithoutPowerBase(in: snapshot([RemovalFixtures.removal(.pending)], bases: [listed])).isEmpty)
    }
}

// MARK: - Controller

@MainActor
final class PowerBaseRemovalControllerTests: XCTestCase {
    private var hub: FakeRemovalHub!
    private var credentials: InMemoryHubCredentialStore!
    private let base = RemovalFixtures.base

    override func setUp() async throws {
        hub = FakeRemovalHub()
        credentials = InMemoryHubCredentialStore([RemovalFixtures.credential(hubID: RemovalFixtures.hubA), RemovalFixtures.credential(hubID: RemovalFixtures.hubB)])
    }

    private func makeController(target: PowerBaseHubTarget = RemovalFixtures.target()) -> PowerBaseRemovalController {
        let controller = PowerBaseRemovalController(transport: hub, credentials: credentials)
        controller.targetDidChange(target)
        return controller
    }

    private var empty: HomeSnapshot { HomeSnapshot(timestamp: Date(timeIntervalSince1970: 0), rooms: [], modules: []) }

    func testARequestUsesThisDevicesCredentialAndShowsWhatTheHubAnswered() async throws {
        hub.scriptRequest(.success(RemovalFixtures.removal(.pending)))
        let controller = makeController()
        controller.requestRemoval(of: base)
        XCTAssertEqual(controller.action(for: base), .requesting)
        try await waitUntil { controller.action(for: self.base) == nil }
        XCTAssertEqual(hub.recorded, [.request(hubID: RemovalFixtures.hubA, token: "token-a", pin: String(repeating: "c", count: 64), base: base)])
        XCTAssertEqual(controller.removal(for: base, in: empty)?.presentation, .waitingForPowerBase,
                       "an accepted request for an offline Base is a waiting job, not a removed Base")
    }

    func testASecondTapWhileTheRequestIsUnderWaySendsNothing() async throws {
        hub.hold()
        hub.scriptRequest(.success(RemovalFixtures.removal(.pending)))
        let controller = makeController()
        controller.requestRemoval(of: base)
        controller.requestRemoval(of: base)
        try await waitUntil { self.hub.heldCount == 1 }
        XCTAssertEqual(hub.recorded.count, 1)
        hub.release()
        try await waitUntil { controller.action(for: self.base) == nil }
    }

    func testNothingIsSentUnlessTheSourceIsAPairedHub() {
        for (target, reason) in [
            (RemovalFixtures.target(isSimulated: true), PowerBaseHubIneligibility.simulatedData),
            (RemovalFixtures.target(isPaired: false), .notPaired),
            (PowerBaseHubTarget.none, .noAddress),
        ] {
            let controller = makeController(target: target)
            controller.requestRemoval(of: base)
            XCTAssertEqual(controller.action(for: base), .failed(.notEligible(target.ineligibility ?? reason)))
        }
        XCTAssertTrue(hub.recorded.isEmpty)
    }

    func testAFullHubIsARefusalThatIsShownAndHidesNothing() async throws {
        hub.scriptRequest(.failure(.capacityFull))
        let controller = makeController()
        controller.requestRemoval(of: base)
        try await waitUntil { controller.action(for: self.base) != .requesting }
        XCTAssertEqual(controller.action(for: base), .failed(.request(.capacityFull)))
        XCTAssertNil(controller.removal(for: base, in: empty), "no job exists, and none is made up locally")
        XCTAssertFalse(PowerBaseManagementText.requestFailureMessage(.capacityFull).isEmpty)
        XCTAssertNotEqual(PowerBaseManagementText.requestFailureMessage(.capacityFull), PowerBaseManagementText.requestFailureMessage(.unavailable("x")),
                          "it is not worded as 'try again in a moment'")
    }

    func testAHubWithoutACredentialIsNotAsked() {
        credentials = InMemoryHubCredentialStore([])
        let controller = makeController()
        controller.requestRemoval(of: base)
        XCTAssertEqual(controller.action(for: base), .failed(.credentialUnavailable))
        XCTAssertTrue(hub.recorded.isEmpty)
    }

    func testARefusalHidesNothingAndIsShownUntilRead() async throws {
        hub.scriptRequest(.failure(.managementUnsupported))
        let controller = makeController()
        controller.requestRemoval(of: base)
        try await waitUntil { controller.action(for: self.base) != .requesting }
        XCTAssertEqual(controller.action(for: base), .failed(.request(.managementUnsupported)))
        XCTAssertNil(controller.removal(for: base, in: empty), "no job, and no local stand-in for one")
        controller.dismissFailure(for: base)
        XCTAssertNil(controller.action(for: base))
    }

    func testALostAnswerIsNotANoAndTheHubsListSaysWhatHappened() async throws {
        hub.scriptRequest(.failure(.unreachable("timeout")))
        let controller = makeController()
        controller.requestRemoval(of: base)
        try await waitUntil { controller.action(for: self.base) != .requesting }
        XCTAssertEqual(controller.action(for: base), .resultUnknown, "no answer is not a refusal: the request is kept, to be sent again")

        // The hub did take it.
        hub.scriptList(.success([RemovalFixtures.removal(.sent)]))
        await controller.refresh()
        XCTAssertEqual(controller.removal(for: base, in: empty)?.presentation, .inProgress)

        // Asking again is safe because it is the SAME request: the registration, the serial and
        // the id it carried the first time -- which the hub answers with the job it made.
        hub.scriptRequest(.success(RemovalFixtures.removal(.sent)))
        controller.retryRemoval(of: base)
        try await waitUntil { controller.action(for: self.base) == nil }
        XCTAssertEqual(controller.removal(for: base, in: empty)?.id, RemovalFixtures.removalID)
        let sent = hub.sentRequests
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.first, sent.last, "sent again exactly as it was")
        XCTAssertEqual(sent.first?.binding, RemovalFixtures.binding, "for the registration that was confirmed")
    }

    func testCancelIsTheHubsDecision() async throws {
        let controller = makeController()
        // A waiting job is cancelled.
        hub.scriptCancel(.success(RemovalFixtures.removal(.cancelled)))
        controller.cancelRemoval(RemovalFixtures.removal(.pending))
        XCTAssertEqual(controller.action(for: base), .cancelling)
        try await waitUntil { controller.action(for: self.base) == nil }
        XCTAssertEqual(controller.removal(for: base, in: empty)?.presentation, .cancelled)

        // One whose command may have reached the board is not, and the job is shown as it is now.
        let current = RemovalFixtures.removal(.accepted)
        hub.scriptCancel(.failure(.notCancellable(current)))
        controller.cancelRemoval(RemovalFixtures.removal(.pending))
        try await waitUntil { controller.action(for: self.base) != .cancelling }
        XCTAssertEqual(controller.action(for: base), .failed(.request(.notCancellable(current))))
        XCTAssertEqual(controller.removal(for: base, in: empty)?.presentation, .inProgress, "never shown as cancelled")
    }

    func testTheSnapshotsJobWinsOverAnOlderAnswer() async throws {
        hub.scriptRequest(.success(RemovalFixtures.removal(.pending)))
        let controller = makeController()
        controller.requestRemoval(of: base)
        try await waitUntil { controller.action(for: self.base) == nil }
        let snapshot = HomeSnapshot(timestamp: Date(), rooms: [], modules: [], powerBaseRemovals: [RemovalFixtures.removal(.completed)], reportsPowerBaseManagement: true)
        XCTAssertEqual(controller.removal(for: base, in: snapshot)?.presentation, .completed)
    }

    func testAnotherHubDropsEveryJobAndEveryLateAnswer() async throws {
        hub.hold()
        hub.scriptRequest(.success(RemovalFixtures.removal(.pending)))
        let controller = makeController()
        controller.requestRemoval(of: base)
        try await waitUntil { self.hub.heldCount == 1 }

        controller.targetDidChange(RemovalFixtures.target(hubID: RemovalFixtures.hubB))
        XCTAssertNil(controller.action(for: base))
        hub.release()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(controller.removal(for: base, in: empty), "an answer of the previous hub is not this hub's job")
        XCTAssertNil(controller.action(for: base))
    }

    func testAnUnreadableListIsAHintAndAHubWithoutTheRoutesIsNot() async {
        let controller = makeController()
        hub.scriptList(.failure(.unreachable("timeout")))
        await controller.refresh()
        XCTAssertEqual(controller.refreshProblem, .unreachable("timeout"))
        hub.scriptList(.failure(.notSupported))
        await controller.refresh()
        XCTAssertNil(controller.refreshProblem)
        hub.scriptList(.success([]))
        await controller.refresh()
        XCTAssertNil(controller.refreshProblem)
    }
}

// MARK: - Presentation

@MainActor
final class PowerBaseManagementPresentationTests: XCTestCase {
    typealias P = PowerBaseManagementPresentation
    private let supported = PowerBase(hardwareIdentifier: RemovalFixtures.base, isOnline: true, moduleCount: 2, onlineModuleCount: 2, management: .supported, record: RemovalFixtures.record, removalSerial: 0)

    private func snapshot(bases: [PowerBase], removals: [PowerBaseRemoval] = [], management: Bool = true) -> HomeSnapshot {
        HomeSnapshot(timestamp: Date(timeIntervalSince1970: 1_790_000_200), rooms: [], modules: [], powerBases: bases, reportsPowerBases: true, powerBaseRemovals: removals, reportsPowerBaseManagement: management)
    }

    func testOnlyCompletedIsCalledRemoved() {
        let completed = PowerBaseManagementText.removalTitle(.completed)
        for state in [PowerBaseRemoval.State.pending, .sent, .accepted, .released, .cancelled, .superseded] {
            XCTAssertNotEqual(PowerBaseManagementText.removalTitle(RemovalFixtures.removal(state).presentation), completed, "\(state)")
            XCTAssertNotEqual(PowerBaseManagementText.removalMessage(RemovalFixtures.removal(state).presentation),
                              PowerBaseManagementText.removalMessage(.completed), "\(state)")
        }
        XCTAssertEqual(RemovalFixtures.removal(.released).presentation, .awaitingEraseConfirmation,
                       "released has a state of its own on screen: out of the lists, erase not confirmed")
        XCTAssertNotEqual(PowerBaseManagementText.removalTitle(RemovalFixtures.removal(.sent, resultUnknown: true).presentation), completed)
        XCTAssertEqual(RemovalFixtures.removal(.completed).presentation, .completed)
    }

    func testAnOpenOrCompletedJobLeavesNothingToRequest() {
        let target = RemovalFixtures.target()
        for removal in [RemovalFixtures.removal(.pending), RemovalFixtures.removal(.sent), RemovalFixtures.removal(.accepted, resultUnknown: true), RemovalFixtures.removal(.released), RemovalFixtures.removal(.completed)] {
            XCTAssertEqual(P.availability(base: supported, snapshot: snapshot(bases: [supported]), target: target, removal: removal), .removalExists, "\(removal.state)")
        }
        // A job that ended without changing the Base can be asked again.
        for removal in [RemovalFixtures.removal(.cancelled), RemovalFixtures.removal(.superseded)] {
            XCTAssertEqual(P.availability(base: supported, snapshot: snapshot(bases: [supported]), target: target, removal: removal), .available, "\(removal.state)")
        }
    }

    func testWhyARemovalCannotBeRequestedIsSaidNotWorkedAround() {
        let target = RemovalFixtures.target()
        XCTAssertEqual(P.availability(base: supported, snapshot: snapshot(bases: [supported], management: false), target: target, removal: nil), .hubUnsupported)
        XCTAssertEqual(P.availability(base: nil, snapshot: snapshot(bases: []), target: target, removal: nil), .gone)
        XCTAssertEqual(P.availability(base: supported, snapshot: snapshot(bases: [supported]), target: RemovalFixtures.target(isPaired: false), removal: nil), .hubNotEligible(.notPaired))
        XCTAssertEqual(P.availability(base: supported, snapshot: snapshot(bases: [supported]), target: RemovalFixtures.target(isSimulated: true), removal: nil), .hubNotEligible(.simulatedData))
        for availability in [P.Availability.hubUnsupported, .powerBaseUnsupported, .gone, .hubNotEligible(.notPaired), .hubNotEligible(.simulatedData), .hubNotEligible(.noAddress)] {
            XCTAssertFalse((PowerBaseManagementText.unavailableMessage(availability) ?? "").isEmpty, "\(availability)")
        }
        XCTAssertNil(PowerBaseManagementText.unavailableMessage(.available))
    }

    func testTheStateCountsTheSensorsTheHubLists() {
        let state = P.state(identifier: RemovalFixtures.base, snapshot: snapshot(bases: [supported]), target: RemovalFixtures.target(), removal: RemovalFixtures.removal(.pending, affected: 3), action: nil, isCurrentStateVerified: true)
        XCTAssertEqual(state.label, "Power Base ··b3c4")
        XCTAssertEqual(state.sensorCount, 0)
        XCTAssertEqual(state.affectedSensorCount, 3, "what the hub counted when it created the job")
        XCTAssertEqual(state.availability, .removalExists)
    }

    func testTheListBadgeShowsJobsThatMatter() {
        XCTAssertEqual(P.badge(for: RemovalFixtures.removal(.pending)), .waitingForPowerBase)
        XCTAssertEqual(P.badge(for: RemovalFixtures.removal(.accepted)), .inProgress)
        XCTAssertEqual(P.badge(for: RemovalFixtures.removal(.sent, resultUnknown: true)), .resultUnknown)
        XCTAssertEqual(P.badge(for: RemovalFixtures.removal(.released)), .awaitingEraseConfirmation)
        XCTAssertNil(P.badge(for: RemovalFixtures.removal(.cancelled)))
        XCTAssertNil(P.badge(for: nil))
    }

    func testEveryFailureHasWording() {
        let errors: [PowerBaseRemovalError] = [
            .unauthorized, .forbidden("tls_required"), .notSupported, .unknownPowerBase, .removalNotFound, .managementUnsupported, .enrollmentInProgress,
            .notCancellable(nil), .rejected("x"), .unavailable("storage"), .certificateMismatch, .unreachable("timeout"), .badResponse("x"),
            .capacityFull, .receiptRejected,
        ]
        for error in errors {
            XCTAssertFalse(PowerBaseManagementText.requestFailureMessage(error).isEmpty, "\(error)")
        }
        XCTAssertFalse(PowerBaseManagementText.failureMessage(.credentialUnavailable).isEmpty)
        XCTAssertFalse(PowerBaseManagementText.failureMessage(.notEligible(.notPaired)).isEmpty)
    }
}
