import XCTest
@testable import PogoHome

/// "허브 목록에서 제거": taking an offline Power Base out of the hub's list (firmware repository,
/// docs/power-base-management.md, section 13). Not a removal -- nothing here may show it as one.
///
/// The JSON in these tests is the hub's own (`ForgetRecordJson()` and `BuildSnapshotJson()`, field
/// for field). The hub's side of every rule -- offline only, the registration named, one request
/// one effect -- is tested there with the real hub code; here: what leaves this device, what the
/// app makes of every answer, and what reaches the screen.
enum ForgetFixtures {
    static let base = RemovalFixtures.base
    static let otherBase = RemovalFixtures.otherBase
    /// A registration's record (a generation), and a later registration's.
    static let record = String(repeating: "7e", count: 16)
    static let laterRecord = String(repeating: "8f", count: 16)
    static let forgetID = "5a0c1d2e3f405162738495a6b7c8d9e5"
    static let requestID = "6b0c1d2e3f405162738495a6b7c8d9e6"

    static func forget(
        id: String = forgetID, requestID: String = requestID, base: String = base, record: String = record,
        cancelled: String? = nil, kept: String? = nil, cleanupPending: Bool = false
    ) -> PowerBaseForget {
        PowerBaseForget(
            id: id, requestID: requestID, powerBaseIdentifier: base, record: record, wasManaged: true,
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), affectedModuleCount: 2,
            cancelledRemovalID: cancelled, keptRemovalID: kept, settingsCleanupPending: cleanupPending
        )
    }

    /// One record exactly as the hub writes it.
    static func json(
        id: String = forgetID, requestID: String = requestID, base: String = base, record: String = record,
        state: String = "removed_from_hub", cancelled: String? = nil, kept: String? = nil
    ) -> String {
        func idOrNull(_ value: String?) -> String { value.map { "\"\($0)\"" } ?? "null" }
        return """
        {"forget_id":"\(id)","request_id":"\(requestID)","power_base_uuid":"\(base)","record":"\(record)","state":"\(state)","managed":true,"created_at_unix_ms":1790000000000,"requested_by_device_id":"0123456789abcdef","affected_module_count":2,"cancelled_removal_id":\(idOrNull(cancelled)),"kept_removal_id":\(idOrNull(kept)),"settings_cleanup_pending":false}
        """
    }

    static func baseJSON(_ uuid: String = base, online: Bool = false, moduleCount: Int = 0, management: String? = "supported", record: String? = record) -> String {
        let managementField = management.map { ",\"management\":\"\($0)\"" + ($0 == "supported" ? ",\"erase_confirmation\":\"automatic\"" : "") } ?? ""
        // With its registration, a Base the hub can remove also says how many removals were asked
        // of it (Linux bridge 0.5.0).
        let recordField = record.map { ",\"record\":\"\($0)\"" + (management == "supported" ? ",\"removal_serial\":0" : "") } ?? ""
        return """
        {"uuid":"\(uuid)","online":\(online),"module_count":\(moduleCount),"online_module_count":\(online ? moduleCount : 0)\(managementField)\(recordField)}
        """
    }

    static func moduleJSON(_ uuid: String, base: String, online: Bool = false) -> String {
        """
        {"uuid":"\(uuid)","power_base_uuid":"\(base)","parent_uuid":"\(base)","online":\(online),"depth":1,"role":"leaf","sensor_bitmap":6,"generation":1,"last_seq":1,"readings":[{"kind":"temperature","raw_value":23400,"scale":1,"value":23.4,"unit":"celsius","status":"ok","sample_seq":1}]}
        """
    }

    nonisolated(unsafe) private static var sequence: Int64 = 0

    /// `forgets == nil`: a hub that cannot take a Base out of its list (the field is absent).
    static func snapshot(bases: [String], modules: [String] = [], removals: [String]? = [], forgets: [String]? = []) -> Data {
        sequence += 1
        let generatedAt = Int64(Date().timeIntervalSince1970 * 1000) + sequence
        let removalsField = removals.map { ",\"power_base_removals\":[\($0.joined(separator: ","))]" } ?? ""
        let forgetsField = forgets.map { ",\"power_base_forgets\":[\($0.joined(separator: ","))]" } ?? ""
        return Data("""
        {"schema_version":1,"generated_at_unix_ms":\(generatedAt),"registry_generation":\(sequence),"power_bases":[\(bases.joined(separator: ","))],"modules":[\(modules.joined(separator: ","))]\(removalsField)\(forgetsField)}
        """.utf8)
    }
}

// MARK: - Wire format

final class PowerBaseForgetWireTests: XCTestCase {
    private typealias Transport = URLSessionPowerBaseRemovalTransport
    private typealias F = ForgetFixtures

    func testTheRequestBodyIsExactlyTheBaseTheRecordAndTheRequestID() throws {
        let body = try Transport.forgetBody(powerBaseIdentifier: F.base, record: F.record, requestID: F.requestID)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"power_base_uuid":"\#(F.base)","record":"\#(F.record)","request_id":"\#(F.requestID)"}"#)
    }

    func testARequestIDIsThirtyTwoLowercaseHexDigitsAndNeverTheSameTwice() {
        let ids = (0..<200).map { _ in PowerBaseForgetRequestID.make() }
        XCTAssertTrue(ids.allSatisfy(PowerBaseRemovalID.isValid))
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testDecodesTheHubsRecord() throws {
        let dto = try JSONDecoder().decode(PowerBaseForgetDTO.self, from: Data(F.json(cancelled: RemovalFixtures.removalID).utf8))
        let forget = try XCTUnwrap(dto.forget)
        XCTAssertEqual(forget.id, F.forgetID)
        XCTAssertEqual(forget.requestID, F.requestID)
        XCTAssertEqual(forget.powerBaseIdentifier, F.base)
        XCTAssertEqual(forget.record, F.record)
        XCTAssertTrue(forget.wasManaged)
        XCTAssertEqual(forget.affectedModuleCount, 2)
        XCTAssertEqual(forget.cancelledRemovalID, RemovalFixtures.removalID)
        XCTAssertNil(forget.keptRemovalID)
        XCTAssertEqual(forget.createdAt, Date(timeIntervalSince1970: 1_790_000_000))
    }

    func testARecordTheAppCannotReadIsNotShownAsSomethingElse() throws {
        func forget(_ json: String) throws -> PowerBaseForget? { try JSONDecoder().decode(PowerBaseForgetDTO.self, from: Data(json.utf8)).forget }
        // A newer hub's word for what happened is not taken for the one this app knows.
        XCTAssertNil(try forget(F.json(state: "completed")))
        XCTAssertNil(try forget(F.json(state: "erased")))
        XCTAssertNil(try forget(F.json(id: "xyz")))
        XCTAssertNil(try forget(F.json(requestID: "1234")))
        XCTAssertNil(try forget(F.json(base: "not-a-base")))
        XCTAssertNil(try forget(F.json(record: "ABCDEF")))
        XCTAssertNotNil(try forget(F.json()))
    }

    func testEveryDocumentedErrorAnswerHasItsOwnMeaning() {
        func error(_ status: Int, _ body: String) -> PowerBaseForgetError { Transport.forgetError(status: status, data: Data(body.utf8)) }
        XCTAssertEqual(error(401, #"{"error":"unauthorized"}"#), .unauthorized)
        XCTAssertEqual(error(403, #"{"error":"tls_required"}"#), .forbidden("tls_required"))
        XCTAssertEqual(error(404, #"{"error":"unknown_power_base"}"#), .notListed)
        XCTAssertEqual(error(404, #"{"error":"forget_disabled"}"#), .notSupported)
        XCTAssertEqual(error(404, "<html>not found</html>"), .notSupported, "a hub older than the routes")
        XCTAssertEqual(error(405, ""), .notSupported)
        XCTAssertEqual(error(409, #"{"error":"power_base_online"}"#), .online)
        XCTAssertEqual(error(409, #"{"error":"stale_record"}"#), .staleRecord)
        XCTAssertEqual(error(409, #"{"error":"enrollment_in_progress"}"#), .enrollmentInProgress)
        XCTAssertEqual(error(409, #"{"error":"request_id_conflict"}"#), .requestConflict)
        XCTAssertEqual(error(409, #"{"error":"forget_capacity_full","limit":"64"}"#), .capacityFull)
        XCTAssertEqual(error(409, #"{"error":"something_new"}"#), .badResponse("HTTP 409"))
        XCTAssertEqual(error(422, #"{"error":"invalid_record"}"#), .rejected("invalid_record"))
        XCTAssertEqual(error(503, #"{"error":"forget_unavailable","reason":"storage"}"#), .unavailable("storage"))
        XCTAssertEqual(error(503, #"{"error":"too_many_forgets"}"#), .unavailable("too_many_forgets"))
        XCTAssertEqual(error(500, ""), .badResponse("HTTP 500"))
        // Only a missing word of the hub leaves the outcome open; every refusal is a "no".
        XCTAssertTrue(PowerBaseForgetError.unreachable("x").leavesOutcomeUnknown)
        XCTAssertTrue(PowerBaseForgetError.badResponse("x").leavesOutcomeUnknown)
        for refusal in [PowerBaseForgetError.online, .staleRecord, .notListed, .capacityFull, .unavailable("x"), .unauthorized, .notSupported, .rejected("x"), .requestConflict, .enrollmentInProgress] {
            XCTAssertFalse(refusal.leavesOutcomeUnknown, "\(refusal)")
        }
    }

    func testNothingMalformedLeavesTheDevice() async {
        let transport = Transport()
        let credential = RemovalFixtures.credential()
        func attempt(base: String, record: String, requestID: String) async -> PowerBaseForgetError? {
            do {
                _ = try await transport.forget(baseURL: RemovalFixtures.url, credential: credential, powerBaseIdentifier: base, record: record, requestID: requestID)
                return nil
            } catch {
                return error as? PowerBaseForgetError
            }
        }
        let invalidBase = await attempt(base: "ZZ", record: F.record, requestID: F.requestID)
        let invalidRecord = await attempt(base: F.base, record: "short", requestID: F.requestID)
        let invalidRequest = await attempt(base: F.base, record: F.record, requestID: "UPPERCASE")
        XCTAssertEqual(invalidBase, .rejected("invalid_power_base_uuid"))
        XCTAssertEqual(invalidRecord, .rejected("invalid_record"))
        XCTAssertEqual(invalidRequest, .rejected("invalid_request_id"))
    }
}

// MARK: - The snapshot

final class PowerBaseForgetSnapshotTests: XCTestCase {
    private typealias F = ForgetFixtures

    func testAHubThatDoesNotSayItCanIsNotAssumedTo() throws {
        // The snapshot of a hub with management but without list removal: 1.2.x's hub.
        let snapshot = try PogoSnapshotMapper.decodeSnapshot(from: F.snapshot(bases: [F.baseJSON(record: nil)], forgets: nil))
        XCTAssertTrue(snapshot.reportsPowerBaseManagement)
        XCTAssertFalse(snapshot.reportsPowerBaseForget)
        XCTAssertNil(snapshot.powerBases.first?.record)
        XCTAssertTrue(snapshot.powerBaseForgets.isEmpty)
    }

    func testTheRecordIsReadPerBaseAndOnlyWhenWellFormed() throws {
        let snapshot = try PogoSnapshotMapper.decodeSnapshot(from: F.snapshot(bases: [
            F.baseJSON(F.base, record: F.record),
            F.baseJSON(F.otherBase, management: "unsupported", record: F.laterRecord),
            F.baseJSON("00124b0001a2b3c6", record: "not-a-record"),
            F.baseJSON("00124b0001a2b3c7", record: nil),
        ]))
        XCTAssertTrue(snapshot.reportsPowerBaseForget)
        XCTAssertEqual(snapshot.powerBases.map(\.record), [F.record, F.laterRecord, nil, nil])
        XCTAssertEqual(snapshot.powerBases.map(\.management), [.supported, .unsupported, .supported, .supported], "the record is no word about management")
    }

    func testTheHubsListRemovalsAreReadAndUnreadableOnesLeftOut() throws {
        let snapshot = try PogoSnapshotMapper.decodeSnapshot(from: F.snapshot(bases: [], forgets: [
            F.json(), F.json(id: "8c0c1d2e3f405162738495a6b7c8d9e8", state: "something_newer"),
        ]))
        XCTAssertEqual(snapshot.powerBaseForgets.map(\.id), [F.forgetID])
        XCTAssertTrue(snapshot.powerBaseRemovals.isEmpty, "a list removal is not a removal job")
    }
}

// MARK: - The rule that tells a Base that left from a list being rebuilt

final class PowerBaseForgetEvidenceTests: XCTestCase {
    private typealias F = ForgetFixtures

    /// `records`: the registration the hub lists for a Base. A hub that can take a Base out of
    /// its list gives one to every Base it lists (the first registration's, unless said).
    private func listed(_ bases: [String], forgets: [PowerBaseForget] = [], records: [String: String?] = [:]) -> HomeSnapshot {
        HomeSnapshot(
            timestamp: Date(timeIntervalSince1970: 0), rooms: [], modules: [],
            powerBases: bases.map {
                PowerBase(
                    hardwareIdentifier: $0, isOnline: false, moduleCount: 0, onlineModuleCount: 0, management: .supported,
                    record: records[$0] ?? F.record
                )
            },
            reportsPowerBases: true, reportsPowerBaseManagement: true, powerBaseForgets: forgets, reportsPowerBaseForget: true
        )
    }

    func testABaseTheHubTookOutOfItsListIsGoneLikeAReleasedOne() {
        var evidence = PowerBaseReleaseEvidence()
        XCTAssertEqual(evidence.observe(listed([F.base, F.otherBase])), [])
        XCTAssertEqual(evidence.observe(listed([F.otherBase], forgets: [F.forget()])), [F.base])
        XCTAssertEqual(evidence.observe(listed([], forgets: [F.forget()])), [F.base], "and stays the reason; the other Base's absence is not explained by it")
    }

    func testAnEmptyListWithoutTheHubsRecordExplainsNothing() {
        var evidence = PowerBaseReleaseEvidence()
        XCTAssertEqual(evidence.observe(listed([F.base])), [])
        XCTAssertEqual(evidence.observe(listed([])), [], "silence is not a list removal")
    }

    func testARecordSeenWhileTheBaseIsListedAgainIsAboutAnEarlierRegistration() {
        var evidence = PowerBaseReleaseEvidence()
        XCTAssertEqual(evidence.observe(listed([F.base])), [])
        XCTAssertEqual(evidence.observe(listed([], forgets: [F.forget()])), [F.base])
        // Registered again: the hub lists it under its new registration, and still lists the
        // record of the earlier one for a while.
        XCTAssertEqual(evidence.observe(listed([F.base], forgets: [F.forget()], records: [F.base: F.laterRecord])), [])
        // The hub lists nothing for a moment: the old record does not explain that.
        XCTAssertEqual(evidence.observe(listed([], forgets: [F.forget()])), [], "a spent record never counts again")
        // A new list removal of the new registration does.
        let second = F.forget(id: "9d0c1d2e3f405162738495a6b7c8d9e9", requestID: "ae0c1d2e3f405162738495a6b7c8d9ea", record: F.laterRecord)
        XCTAssertEqual(evidence.observe(listed([], forgets: [F.forget(), second])), [F.base])
    }

    func testARecordFirstSeenTogetherWithItsBaseListedIsNoEvidenceLater() {
        // An app started after the Base was registered again.
        var evidence = PowerBaseReleaseEvidence()
        XCTAssertEqual(evidence.observe(listed([F.base], forgets: [F.forget()], records: [F.base: F.laterRecord])), [])
        XCTAssertEqual(evidence.observe(listed([], forgets: [F.forget()])), [])
    }

    // MARK: A list that is behind the hub's records (the 2026-10-10 review, finding 1)

    func testARecordSeenWithItsOwnRegistrationStillListedIsNotSpent() {
        // The hub copied its list of Bases, took the Base out of the list for another device, and
        // then read its records: one snapshot with the Base AND the record that removed it. A hub
        // before 0.4.1 lists that Base without a registration (it has none any more).
        var evidence = PowerBaseReleaseEvidence()
        XCTAssertEqual(evidence.observe(listed([F.base])), [])
        XCTAssertEqual(evidence.observe(listed([F.base], forgets: [F.forget()], records: [F.base: nil])), [],
                       "the Base is still in this list: nothing has left yet")
        XCTAssertEqual(evidence.observe(listed([], forgets: [F.forget()])), [F.base],
                       "when the list catches up, that record is why the Base is gone")
        XCTAssertEqual(evidence.observe(listed([], forgets: [F.forget()])), [F.base], "and stays the reason")
    }

    func testTheSameWhenTheBaseIsStillListedUnderTheVeryRegistrationThatWasTakenOut() {
        var evidence = PowerBaseReleaseEvidence()
        XCTAssertEqual(evidence.observe(listed([F.base])), [])
        XCTAssertEqual(evidence.observe(listed([F.base], forgets: [F.forget()], records: [F.base: F.record])), [])
        XCTAssertEqual(evidence.observe(listed([], forgets: [F.forget()])), [F.base])
    }

    func testTheSameForTheFirstSnapshotThisAppEverSees() {
        // The first connection: nothing was seen before the snapshot that is behind.
        var evidence = PowerBaseReleaseEvidence()
        XCTAssertEqual(evidence.observe(listed([F.base], forgets: [F.forget()], records: [F.base: nil])), [])
        XCTAssertEqual(evidence.observe(listed([], forgets: [F.forget()])), [F.base])
    }

    func testOnlyAnotherRegistrationSpendsARecordHoweverOftenTheListIsBehind() {
        var evidence = PowerBaseReleaseEvidence()
        for _ in 0..<3 {
            XCTAssertEqual(evidence.observe(listed([F.base], forgets: [F.forget()], records: [F.base: nil])), [])
        }
        XCTAssertEqual(evidence.observe(listed([], forgets: [F.forget()])), [F.base])
        // Registered again: now it is spent, for good.
        XCTAssertEqual(evidence.observe(listed([F.base], forgets: [F.forget()], records: [F.base: F.laterRecord])), [])
        XCTAssertEqual(evidence.observe(listed([], forgets: [F.forget()])), [], "the sensors of the new registration are not taken away by the earlier record")
        // And a list that is behind while the NEW registration is taken out spends nothing of that.
        let second = F.forget(id: "9d0c1d2e3f405162738495a6b7c8d9e9", requestID: "ae0c1d2e3f405162738495a6b7c8d9ea", record: F.laterRecord)
        XCTAssertEqual(evidence.observe(listed([F.base], forgets: [F.forget(), second], records: [F.base: nil])), [])
        XCTAssertEqual(evidence.observe(listed([], forgets: [F.forget(), second])), [F.base])
    }

    func testAnotherBasesRecordSaysNothingOfThisOne() {
        var evidence = PowerBaseReleaseEvidence()
        XCTAssertEqual(evidence.observe(listed([F.base, F.otherBase])), [])
        let others = F.forget(base: F.otherBase)
        XCTAssertEqual(evidence.observe(listed([F.base, F.otherBase], forgets: [others], records: [F.otherBase: nil])), [])
        XCTAssertEqual(evidence.observe(listed([], forgets: [others])), [F.otherBase], "only the Base the record names")
    }

    // MARK: The same judgement for removal jobs, from a hub that names registrations

    private func jobs(_ bases: [String], _ removals: [PowerBaseRemoval], records: [String: String?] = [:]) -> HomeSnapshot {
        HomeSnapshot(
            timestamp: Date(timeIntervalSince1970: 0), rooms: [], modules: [],
            powerBases: bases.map {
                PowerBase(hardwareIdentifier: $0, isOnline: false, moduleCount: 0, onlineModuleCount: 0, management: .supported, record: records[$0] ?? F.record, removalSerial: 0)
            },
            reportsPowerBases: true, powerBaseRemovals: removals, reportsPowerBaseManagement: true, reportsPowerBaseForget: true
        )
    }

    private func job(_ state: PowerBaseRemoval.State, record: String? = ForgetFixtures.record) -> PowerBaseRemoval {
        var removal = RemovalFixtures.removal(state)
        removal.record = record
        return removal
    }

    func testAJobThatEndedWhileItsOwnRegistrationIsStillListedIsNotSpent() {
        // The receipt completed a job the notice never reached the hub for: the hub stores
        // "completed" and takes the Base out of its list in one step -- and a list copied before
        // that step is shown with the job after it.
        var evidence = PowerBaseReleaseEvidence()
        XCTAssertEqual(evidence.observe(jobs([F.base], [job(.accepted)])), [])
        XCTAssertEqual(evidence.observe(jobs([F.base], [job(.completed)], records: [F.base: nil])), [])
        XCTAssertEqual(evidence.observe(jobs([], [job(.completed)])), [F.base], "the job of that registration is why it is gone")
        // The same when the list still names the registration.
        var named = PowerBaseReleaseEvidence()
        XCTAssertEqual(named.observe(jobs([F.base], [job(.completed)])), [])
        XCTAssertEqual(named.observe(jobs([], [job(.completed)])), [F.base])
    }

    func testAJobOfAnEarlierRegistrationIsSpentAlsoWhenItIsTheFirstThingSeen() {
        var evidence = PowerBaseReleaseEvidence()
        XCTAssertEqual(evidence.observe(jobs([F.base], [job(.released)], records: [F.base: F.laterRecord])), [])
        XCTAssertEqual(evidence.observe(jobs([], [job(.released)])), [], "the new registration's absence is not explained by the earlier job")
    }

    func testAHubThatDoesNotNameRegistrationsIsJudgedAsBefore() {
        // No `record` on the job (a hub before 0.4.0 has none on its Bases either): the history
        // of what was seen decides, exactly as it did.
        var evidence = PowerBaseReleaseEvidence()
        XCTAssertEqual(evidence.observe(jobs([F.base], [job(.completed, record: nil)])), [])
        XCTAssertEqual(evidence.observe(jobs([], [job(.completed, record: nil)])), [], "seen completed with its Base listed: spent")
    }
}

// MARK: - The controller

@MainActor
final class PowerBaseForgetControllerTests: XCTestCase {
    private typealias F = ForgetFixtures

    private var hub: FakeRemovalHub!
    private var credentials: InMemoryHubCredentialStore!
    private let base = ForgetFixtures.base
    private let source = SensorSourceIdentity.hub(id: RemovalFixtures.hubA)

    override func setUp() async throws {
        hub = FakeRemovalHub()
        credentials = InMemoryHubCredentialStore([RemovalFixtures.credential(hubID: RemovalFixtures.hubA), RemovalFixtures.credential(hubID: RemovalFixtures.hubB)])
    }

    private func makeController(target: PowerBaseHubTarget = RemovalFixtures.target()) -> PowerBaseRemovalController {
        let controller = PowerBaseRemovalController(transport: hub, credentials: credentials)
        controller.targetDidChange(target)
        return controller
    }

    /// The hub carries the request out and answers with its record (the request's own id in it).
    private func scriptCarriedOut(id: String = ForgetFixtures.forgetID) {
        hub.scriptForget { base, record, requestID in .success(ForgetFixtures.forget(id: id, requestID: requestID, base: base, record: record)) }
    }

    private func requestIDs() -> [String] {
        hub.forgets.compactMap { if case let .forget(_, _, _, _, _, requestID) = $0 { requestID } else { nil } }
    }

    func testARequestNamesTheRegistrationAndUsesThisDevicesCredential() async throws {
        scriptCarriedOut()
        let controller = makeController()
        controller.forgetPowerBase(base, record: F.record)
        XCTAssertEqual(controller.forgetAction(for: base), .requesting)
        try await waitUntil { controller.forgetAction(for: self.base) == nil }
        XCTAssertEqual(hub.recorded.count, 1)
        guard case let .forget(hubID, token, pin, sentBase, record, requestID) = try XCTUnwrap(hub.recorded.first) else { return XCTFail("not a list removal") }
        XCTAssertEqual(hubID, RemovalFixtures.hubA)
        XCTAssertEqual(token, "token-a")
        XCTAssertEqual(pin, String(repeating: "c", count: 64))
        XCTAssertEqual(sentBase, base)
        XCTAssertEqual(record, F.record, "the registration the user was shown, and nothing newer")
        XCTAssertTrue(PowerBaseRemovalID.isValid(requestID))
        // Told once, as what it is: never as a completed removal.
        XCTAssertEqual(controller.completionEvents.map(\.completion.kind), [.removedFromHubList])
        XCTAssertEqual(controller.notices.waiting.map(\.kind), [.removedFromHubList])
        XCTAssertNil(controller.removal(for: base, in: HomeSnapshot(timestamp: Date(), rooms: [], modules: [])), "no removal job comes of it")
        XCTAssertNil(controller.action(for: base))
    }

    func testASecondTapWhileTheRequestIsUnderWaySendsNothing() async throws {
        hub.hold()
        scriptCarriedOut()
        let controller = makeController()
        controller.forgetPowerBase(base, record: F.record)
        controller.forgetPowerBase(base, record: F.record)
        controller.forgetPowerBase(base, record: F.laterRecord)
        try await waitUntil { self.hub.heldCount == 1 }
        XCTAssertEqual(hub.forgets.count, 1)
        hub.release()
        try await waitUntil { controller.forgetAction(for: self.base) == nil }
        XCTAssertEqual(hub.forgets.count, 1)
        XCTAssertEqual(controller.completionEvents.count, 1)
    }

    func testNothingIsSentUnlessTheSourceIsAPairedHubWithACredential() {
        for (target, reason) in [
            (RemovalFixtures.target(isPaired: false), PowerBaseHubIneligibility.notPaired),
            (RemovalFixtures.target(isSimulated: true), .simulatedData),
            (PowerBaseHubTarget(hubID: nil, baseURL: RemovalFixtures.url, isSimulated: false, isPaired: false), .typedAddress),
        ] {
            let controller = makeController(target: target)
            controller.forgetPowerBase(base, record: F.record)
            XCTAssertEqual(controller.forgetAction(for: base), .failed(.notEligible(reason)))
        }
        credentials = InMemoryHubCredentialStore()
        let controller = makeController()
        controller.forgetPowerBase(base, record: F.record)
        XCTAssertEqual(controller.forgetAction(for: base), .failed(.credentialUnavailable))
        XCTAssertTrue(hub.recorded.isEmpty)
    }

    func testEveryRefusalIsShownUntilReadAndTellsNothing() async throws {
        for refusal in [PowerBaseForgetError.online, .staleRecord, .notListed, .enrollmentInProgress, .capacityFull, .unavailable("storage"), .unauthorized, .notSupported] {
            hub.scriptForget(.failure(refusal))
            let controller = makeController()
            controller.forgetPowerBase(base, record: F.record)
            try await waitUntil { controller.forgetAction(for: self.base) != .requesting }
            XCTAssertEqual(controller.forgetAction(for: base), .failed(.request(refusal)), "\(refusal)")
            XCTAssertTrue(controller.completionEvents.isEmpty, "a refusal is never told as done: \(refusal)")
            XCTAssertTrue(controller.notices.waiting.isEmpty)
            controller.retryForget(of: base)
            XCTAssertEqual(controller.forgetAction(for: base), .failed(.request(refusal)), "a refusal is not sent again by itself")
            controller.dismissForgetFailure(for: base)
            XCTAssertNil(controller.forgetAction(for: base))
        }
    }

    func testAfterARefusalANewConfirmationIsANewRequest() async throws {
        hub.scriptForget(.failure(.online))
        scriptCarriedOut()
        let controller = makeController()
        controller.forgetPowerBase(base, record: F.record)
        try await waitUntil { controller.forgetAction(for: self.base) != .requesting }
        controller.dismissForgetFailure(for: base)
        controller.forgetPowerBase(base, record: F.record)
        try await waitUntil { controller.forgetAction(for: self.base) == nil }
        let ids = requestIDs()
        XCTAssertEqual(ids.count, 2)
        XCTAssertNotEqual(ids[0], ids[1], "the hub refused the first and stored nothing of it")
    }

    func testALostAnswerIsNotANoAndTheSameRequestIsSentAgain() async throws {
        hub.scriptForget(.failure(.unreachable("timeout")))
        let controller = makeController()
        controller.forgetPowerBase(base, record: F.record)
        try await waitUntil { controller.forgetAction(for: self.base) != .requesting }
        XCTAssertEqual(controller.forgetAction(for: base), .resultUnknown, "not a failure, not a success")
        XCTAssertTrue(controller.completionEvents.isEmpty)
        controller.dismissForgetFailure(for: base)
        XCTAssertEqual(controller.forgetAction(for: base), .resultUnknown, "an open question is not put away as read")

        // "다시 확인": the same request, the same registration -- the hub answers with the same record.
        scriptCarriedOut()
        controller.retryForget(of: base)
        try await waitUntil { controller.forgetAction(for: self.base) == nil }
        let ids = requestIDs()
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids[0], ids[1], "the same request id: the hub does nothing twice")
        XCTAssertEqual(hub.forgets.compactMap { if case let .forget(_, _, _, _, record, _) = $0 { record } else { nil } }, [F.record, F.record])
        XCTAssertEqual(controller.completionEvents.count, 1)
    }

    func testAnAnswerOutsideTheContractAlsoLeavesTheOutcomeOpen() async throws {
        hub.scriptForget(.failure(.badResponse("HTTP 500")))
        let controller = makeController()
        controller.forgetPowerBase(base, record: F.record)
        try await waitUntil { controller.forgetAction(for: self.base) != .requesting }
        XCTAssertEqual(controller.forgetAction(for: base), .resultUnknown)
    }

    func testTheSnapshotSettlesARequestWhoseAnswerWasLostAndItIsToldOnce() async throws {
        hub.scriptForget(.failure(.unreachable("timeout")))
        let controller = makeController()
        controller.sourceDidReport([], forgets: [], from: source)
        controller.forgetPowerBase(base, record: F.record)
        try await waitUntil { controller.forgetAction(for: self.base) == .resultUnknown }
        let sent = try XCTUnwrap(requestIDs().first)

        // The hub did carry it out: its snapshot lists the record with this device's request id.
        let record = F.forget(requestID: sent)
        controller.sourceDidReport([], forgets: [record], from: source)
        XCTAssertNil(controller.forgetAction(for: base))
        XCTAssertEqual(controller.completionEvents.map(\.completion.kind), [.removedFromHubList])
        // The same list again and again, and a late retry's answer: told once.
        controller.sourceDidReport([], forgets: [record], from: source)
        controller.sourceDidReport([], forgets: [record], from: source)
        XCTAssertEqual(controller.completionEvents.count, 1)
        XCTAssertEqual(controller.notices.waiting.count, 1)
    }

    func testAListRemovalAnotherDeviceAskedForIsNoNewsHereAndSettlesNothing() async throws {
        hub.scriptForget(.failure(.unreachable("timeout")))
        let controller = makeController()
        controller.sourceDidReport([], forgets: [], from: source)
        // Another device's record, with nothing asked here: the Base leaves the list, silently.
        controller.sourceDidReport([], forgets: [F.forget()], from: source)
        XCTAssertTrue(controller.completionEvents.isEmpty)
        XCTAssertTrue(controller.notices.waiting.isEmpty)

        // And with a request of this device open for the same Base: another request's record is
        // not this request's answer.
        controller.forgetPowerBase(base, record: F.laterRecord)
        try await waitUntil { controller.forgetAction(for: self.base) == .resultUnknown }
        controller.sourceDidReport([], forgets: [F.forget()], from: source)
        XCTAssertEqual(controller.forgetAction(for: base), .resultUnknown)
        XCTAssertTrue(controller.completionEvents.isEmpty)
    }

    func testAnotherHubDropsTheRequestAndItsLateAnswer() async throws {
        hub.hold()
        scriptCarriedOut()
        let controller = makeController()
        controller.sourceDidReport([], forgets: [], from: source)
        controller.forgetPowerBase(base, record: F.record)
        try await waitUntil { self.hub.heldCount == 1 }

        controller.targetDidChange(RemovalFixtures.target(hubID: RemovalFixtures.hubB))
        controller.sourceDidReport([], forgets: [], from: .hub(id: RemovalFixtures.hubB))
        XCTAssertNil(controller.forgetAction(for: base))
        hub.release()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(controller.forgetAction(for: base))
        XCTAssertTrue(controller.completionEvents.isEmpty, "the previous hub's answer is told on no screen of this one")
        XCTAssertTrue(controller.notices.waiting.isEmpty)
        // The new hub is asked with a request of its own.
        scriptCarriedOut(id: "be0c1d2e3f405162738495a6b7c8d9eb")
        controller.forgetPowerBase(base, record: F.laterRecord)
        try await waitUntil { controller.completionEvents.count == 1 }
        XCTAssertEqual(hub.forgets.count, 2)
        guard case let .forget(hubID, _, _, _, _, _) = hub.forgets[1] else { return XCTFail() }
        XCTAssertEqual(hubID, RemovalFixtures.hubB)
    }

    func testARemovalRequestAndAListRemovalDoNotRunTogether() async throws {
        hub.hold()
        hub.scriptRequest(.success(RemovalFixtures.removal(.pending)))
        let controller = makeController()
        controller.requestRemoval(of: base)
        try await waitUntil { self.hub.heldCount == 1 }
        controller.forgetPowerBase(base, record: F.record)
        XCTAssertNil(controller.forgetAction(for: base), "while the removal request is under way nothing else is asked for that Base")
        XCTAssertTrue(hub.forgets.isEmpty)
        hub.release()
        try await waitUntil { controller.action(for: self.base) == nil }
    }

    func testTheSheetClosesOnItsOwnBasesListRemovalOnly() async throws {
        scriptCarriedOut()
        let controller = makeController()
        let opened = controller.completionSerial
        controller.forgetPowerBase(base, record: F.record)
        try await waitUntil { controller.completionEvents.count == 1 }
        XCTAssertTrue(PowerBaseManagementSheet.closes(on: controller.completionEvents, after: opened, target: PowerBaseManagementTarget(identifier: base)))
        XCTAssertFalse(PowerBaseManagementSheet.closes(on: controller.completionEvents, after: opened, target: PowerBaseManagementTarget(identifier: F.otherBase)))
        XCTAssertFalse(PowerBaseManagementSheet.closes(on: controller.completionEvents, after: controller.completionSerial, target: PowerBaseManagementTarget(identifier: base)),
                       "a sheet opened afterwards is not closed by what happened before it")
    }
}

// MARK: - What the sheet offers and says

final class PowerBaseForgetPresentationTests: XCTestCase {
    private typealias P = PowerBaseManagementPresentation
    private typealias T = PowerBaseManagementText
    private typealias F = ForgetFixtures

    private func base(online: Bool = false, management: PowerBaseManagementSupport = .supported, record: String? = ForgetFixtures.record) -> PowerBase {
        PowerBase(hardwareIdentifier: F.base, isOnline: online, moduleCount: 1, onlineModuleCount: online ? 1 : 0, management: management, record: record, removalSerial: 0)
    }

    private func snapshot(_ base: PowerBase?, removals: [PowerBaseRemoval] = [], forget: Bool = true, moduleOnline: Bool = false) -> HomeSnapshot {
        let module = SensorModule(
            id: UUID(), name: "Sensor", hardwareIdentifier: "744dbdfffe65d357", roomID: UUID(), readings: [], isOnline: moduleOnline,
            lastSeen: Date(), powerBaseIdentifier: F.base, parentIdentifier: F.base
        )
        return HomeSnapshot(
            timestamp: Date(timeIntervalSince1970: 0), rooms: [], modules: base == nil ? [] : [module], powerBases: base.map { [$0] } ?? [],
            reportsPowerBases: true, powerBaseRemovals: removals, reportsPowerBaseManagement: true, reportsPowerBaseForget: forget
        )
    }

    private func state(
        _ snapshot: HomeSnapshot, target: PowerBaseHubTarget = RemovalFixtures.target(), verified: Bool = true,
        forgetAction: PowerBaseRemovalController.ForgetAction? = nil
    ) -> P.State {
        P.state(
            identifier: F.base, snapshot: snapshot, target: target,
            removal: PowerBaseRemovalController.removal(for: F.base, in: snapshot, answered: nil), action: nil,
            isCurrentStateVerified: verified, forgetAction: forgetAction
        )
    }

    func testItIsOfferedForAnOfflineBaseTheHubListsWithItsRecord() {
        let offered = state(snapshot(base()))
        XCTAssertEqual(offered.forgetOffer, P.ForgetOffer(record: F.record, removalEffect: .none))
        XCTAssertEqual(offered.availability, .available, "next to the removal, not in its place: the pending removal can still be asked for")
    }

    func testItIsNotOfferedWhenTheHubWouldRefuseOrNeverSaidItCan() {
        XCTAssertNil(state(snapshot(base(online: true))).forgetOffer, "a Base the hub hears is removed, not taken out of the list")
        XCTAssertNil(state(snapshot(base(), moduleOnline: true)).forgetOffer, "nor one with a sensor the hub hears")
        XCTAssertNil(state(snapshot(base(), forget: false)).forgetOffer, "a hub that does not say it can is not assumed to")
        XCTAssertNil(state(snapshot(base(record: nil))).forgetOffer, "without the registration to name there is nothing to ask")
        XCTAssertNil(state(snapshot(base()), verified: false).forgetOffer, "what the hub says now is not known")
        XCTAssertNil(state(snapshot(base()), target: RemovalFixtures.target(isPaired: false)).forgetOffer)
        XCTAssertNil(state(snapshot(base()), target: RemovalFixtures.target(isSimulated: true)).forgetOffer)
        XCTAssertNil(state(snapshot(nil)).forgetOffer, "a Base the hub does not list")
    }

    func testABaseRegisteredTheEarlierWayCanBeTakenOutWhileItsRemovalStaysUnsupported() {
        let earlier = state(snapshot(base(management: .unsupported)))
        XCTAssertEqual(earlier.availability, .powerBaseUnsupported, "the removal is still not forced on it")
        XCTAssertEqual(earlier.forgetOffer, P.ForgetOffer(record: F.record, removalEffect: .none))
        XCTAssertNil(state(snapshot(base(online: true, management: .unsupported))).forgetOffer, "and while it is heard nothing is offered in its place")
    }

    func testARemovalUnderWayDecidesWhatIsOfferedAndSaid() {
        func offer(_ removal: PowerBaseRemoval) -> P.ForgetOffer? { state(snapshot(base(), removals: [removal])).forgetOffer }
        XCTAssertEqual(offer(RemovalFixtures.removal(.pending))?.removalEffect, .cancelsPendingRemoval)
        XCTAssertEqual(offer(RemovalFixtures.removal(.sent, resultUnknown: true))?.removalEffect, .keepsSentRemoval)
        XCTAssertEqual(offer(RemovalFixtures.removal(.accepted, resultUnknown: true))?.removalEffect, .keepsSentRemoval)
        XCTAssertNil(offer(RemovalFixtures.removal(.sent)), "while a removal is being carried out the offer waits")
        XCTAssertNil(offer(RemovalFixtures.removal(.accepted)))
        XCTAssertEqual(offer(RemovalFixtures.removal(.cancelled))?.removalEffect, P.ForgetOffer.RemovalEffect.none)
        XCTAssertEqual(offer(RemovalFixtures.removal(.superseded))?.removalEffect, P.ForgetOffer.RemovalEffect.none)
        // A finished removal of an earlier registration says nothing of the Base listed now.
        XCTAssertEqual(offer(RemovalFixtures.removal(.completed))?.removalEffect, P.ForgetOffer.RemovalEffect.none)

        let plain = T.forgetConfirmMessage(.none)
        XCTAssertTrue(T.forgetConfirmMessage(.cancelsPendingRemoval).hasPrefix(plain))
        XCTAssertTrue(T.forgetConfirmMessage(.keepsSentRemoval).hasPrefix(plain))
        XCTAssertEqual(Set([plain, T.forgetConfirmMessage(.cancelsPendingRemoval), T.forgetConfirmMessage(.keepsSentRemoval)]).count, 3)
    }

    func testNothingOfItIsShownForABaseTheHubNoLongerLists() {
        XCTAssertNil(state(snapshot(nil), forgetAction: .resultUnknown).forgetAction)
        XCTAssertEqual(state(snapshot(base()), forgetAction: .resultUnknown).forgetAction, .resultUnknown)
    }

    func testItIsNeverWordedAsARemovalOrAsDone() {
        let label = P.label(forIdentifier: F.base)
        let completed = [T.removalTitle(.completed), T.completionNotice(label: label), T.removalMessage(.completed), T.delete, T.deleteConfirm, T.confirmTitle(label: label)]
        let texts = [
            T.forgetHeader, T.forgetExplanation, T.forgetFooter, T.forgetConfirm, T.forgetRequesting, T.forgetResultUnknown, T.forgetRetry,
            T.forgetConfirmTitle(label: label), T.forgetNotice(label: label),
            T.forgetConfirmMessage(.none), T.forgetConfirmMessage(.cancelsPendingRemoval), T.forgetConfirmMessage(.keepsSentRemoval),
        ]
        for text in texts {
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(completed.contains(text), "the same words as a removal: \(text)")
        }
        XCTAssertNotEqual(T.forgetNotice(label: label), T.completionNotice(label: label))
        XCTAssertTrue(T.forgetNotice(label: label).contains(label))
        XCTAssertTrue(T.forgetConfirmTitle(label: label).contains(label))
        guard AppLanguage.current == .korean else { return }
        // The Korean source is what every translation follows.
        XCTAssertEqual(T.forgetConfirmMessage(.none), "이 허브의 목록에서 Power Base와 센서를 제거합니다. Power Base에 저장된 연결 정보는 지워지지 않습니다.")
        for text in texts {
            XCTAssertFalse(text.contains("삭제 완료"), text)
            XCTAssertFalse(text.contains("초기화"), text)
        }
        XCTAssertTrue(T.forgetExplanation.contains("지워지지 않습니다"))
        XCTAssertTrue(T.forgetFooter.contains("되돌릴 수 없"))
        XCTAssertTrue(T.forgetFooter.contains("다시 사용하려면"))
        XCTAssertFalse(T.deleteFooter.contains("다시 쓰려면"))
        XCTAssertTrue(T.deleteFooter.contains("다시 사용하려면"))
        XCTAssertTrue(T.removalMessage(.completed).contains("다시 사용하려면"))
    }

    func testEveryFailureHasWordingThatDoesNotClaimAnythingWasRemoved() {
        let failures: [PowerBaseRemovalController.ForgetFailure] = [
            .notEligible(.notPaired), .notEligible(.simulatedData), .notEligible(.typedAddress), .credentialUnavailable,
            .request(.unauthorized), .request(.forbidden("x")), .request(.certificateMismatch), .request(.notSupported), .request(.notListed),
            .request(.online), .request(.staleRecord), .request(.enrollmentInProgress), .request(.requestConflict), .request(.capacityFull),
            .request(.rejected("x")), .request(.unavailable("x")), .request(.unreachable("x")), .request(.badResponse("x")),
        ]
        for failure in failures {
            let message = T.forgetFailureMessage(failure)
            XCTAssertFalse(message.isEmpty, "\(failure)")
            XCTAssertNotEqual(message, T.forgetNotice(label: "x"))
        }
        // The refusals a user can act on are told apart.
        let distinct: [PowerBaseForgetError] = [.online, .staleRecord, .notListed, .enrollmentInProgress, .capacityFull, .notSupported, .unauthorized, .unavailable("x")]
        XCTAssertEqual(Set(distinct.map { T.forgetFailureMessage(.request($0)) }).count, distinct.count)
    }
}
