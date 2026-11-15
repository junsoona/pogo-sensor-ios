import Foundation
import XCTest
@testable import PogoHome

// A removal is asked of ONE registration of a Power Base (firmware repository,
// docs/power-base-management.md, section 16; Linux bridge 0.5.0). `1.3.2` sent the Base's EUI-64
// alone. A device that lost the answer to its request and sent it once more -- after the removal
// had completed and another device had registered the Base again -- made the hub remove the NEW
// registration. Now the request names the registration the user was shown when they confirmed
// (`record`), that registration's removal serial, and an id of its own; the same request is sent
// again unchanged, and a new confirmation is a new request.
//
// Here: the hub's words are the JSON the hub writes, received through the real
// `LiveSensorDataSource`, `PogoSnapshotMapper` and `AppModel`; its answers to the removal routes
// are scripted (`FakeRemovalHub`), and every request the app sends is recorded with what it
// names. What the HUB does with such a request is tested in the firmware repository against the
// real management code; here it is what the APP sends, keeps, drops and shows. The second iPhone
// is a second `AppModel` and controller. No real hub, network or device.

// MARK: - Wire format

final class PowerBaseRemovalBindingWireTests: XCTestCase {
    private typealias Transport = URLSessionPowerBaseRemovalTransport
    private typealias F = ForgetFixtures

    private func base(_ fields: String) throws -> PowerBase {
        let json = "{\"schema_version\":1,\"generated_at_unix_ms\":1790000200000,\"registry_generation\":9,\"power_bases\":[{\"uuid\":\"\(F.base)\",\"online\":true,\"module_count\":0,\"online_module_count\":0\(fields)}],\"modules\":[],\"power_base_removals\":[]}"
        return try XCTUnwrap(PogoSnapshotMapper.decodeSnapshot(from: Data(json.utf8)).powerBases.first)
    }

    func testTheHubsRemovalSerialIsReadForABaseItCanRemove() throws {
        let listed = try base(",\"management\":\"supported\",\"erase_confirmation\":\"automatic\",\"record\":\"\(F.record)\",\"removal_serial\":3")
        XCTAssertEqual(listed.removalSerial, 3)
        XCTAssertEqual(listed.removalBinding, PowerBaseRemovalBinding(record: F.record, serial: 3))
        XCTAssertEqual(try base(",\"management\":\"supported\",\"record\":\"\(F.record)\",\"removal_serial\":0").removalBinding?.serial, 0, "no removal asked yet is a count, too")
    }

    func testWithoutBothOfTheHubsWordsThereIsNothingARequestCouldName() throws {
        // Linux bridge 0.4.x: the registration, no serial. 0.3.0: neither.
        XCTAssertNil(try base(",\"management\":\"supported\",\"record\":\"\(F.record)\"").removalBinding)
        XCTAssertNil(try base(",\"management\":\"supported\"").removalBinding)
        XCTAssertNil(try base(",\"management\":\"supported\",\"removal_serial\":0").removalBinding, "a serial without the registration it counts for")
        // A number that is no count is no word; the rest of the Base is read as before.
        for bad in ["-1", "4294967296"] {
            let listed = try base(",\"management\":\"supported\",\"record\":\"\(F.record)\",\"removal_serial\":\(bad)")
            XCTAssertNil(listed.removalSerial, bad)
            XCTAssertNil(listed.removalBinding, bad)
            XCTAssertEqual(listed.record, F.record)
            XCTAssertEqual(listed.management, .supported)
        }
        // Said of a Base the hub cannot remove, it means nothing.
        for unremovable in [",\"management\":\"unsupported\",\"record\":\"\(F.record)\",\"removal_serial\":0", ",\"record\":\"\(F.record)\",\"removal_serial\":0"] {
            XCTAssertNil(try base(unremovable).removalBinding, unremovable)
            XCTAssertNil(try base(unremovable).removalSerial, unremovable)
        }
    }

    func testAJobSaysWhichRequestCreatedIt() throws {
        let id = String(repeating: "5a", count: 16)
        let withID = try Transport.decodeRemoval(Data(RemovalFixtures.json("pending", extra: ",\"request_id\":\"\(id)\"").utf8))
        XCTAssertEqual(withID.requestID, id)
        XCTAssertEqual(withID.record, RemovalFixtures.record, "and which registration it is about")
        XCTAssertNil(try Transport.decodeRemoval(Data(RemovalFixtures.json("pending").utf8)).requestID, "a job an earlier hub made")
        XCTAssertNil(try Transport.decodeRemoval(Data(RemovalFixtures.json("pending", extra: ",\"request_id\":\"nope\"").utf8)).requestID)
    }

    func testOnlyAWellFormedRequestLeavesTheDevice() async {
        let transport = Transport()
        let credential = RemovalFixtures.credential()
        let good = PowerBaseRemovalBinding(record: F.record, serial: 0)
        let id = String(repeating: "5a", count: 16)
        func refusal(base: String = F.base, binding: PowerBaseRemovalBinding, requestID: String) async -> PowerBaseRemovalError? {
            do {
                _ = try await transport.request(baseURL: RemovalFixtures.url, credential: credential, powerBaseIdentifier: base, binding: binding, requestID: requestID)
                return nil
            } catch {
                return error as? PowerBaseRemovalError
            }
        }
        // Each is refused before anything is sent (nothing here can reach a hub: these return at once).
        let badBase = await refusal(base: "00124B0001A2B3C4", binding: good, requestID: id)
        XCTAssertEqual(badBase, .rejected("invalid_power_base_uuid"))
        let badRecord = await refusal(binding: PowerBaseRemovalBinding(record: "not-a-record", serial: 0), requestID: id)
        XCTAssertEqual(badRecord, .rejected("invalid_record"))
        let badSerial = await refusal(binding: PowerBaseRemovalBinding(record: F.record, serial: -1), requestID: id)
        XCTAssertEqual(badSerial, .rejected("invalid_record"))
        let badID = await refusal(binding: good, requestID: "5A")
        XCTAssertEqual(badID, .rejected("invalid_request_id"))
        XCTAssertTrue(good.isValid)
        // 64-bit numbers on every device: `Int(UInt32.max)` stops a program whose `Int` is 32 bits.
        XCTAssertFalse(PowerBaseRemovalBinding(record: F.record, serial: Int64(UInt32.max) + 1).isValid)
        XCTAssertTrue(PowerBaseRemovalBinding(record: F.record, serial: Int64(UInt32.max)).isValid)
    }

    func testTheHubsRefusalsOfARequestAreReadAsWhatTheyAre() {
        func error(_ status: Int, _ code: String) -> PowerBaseRemovalError {
            Transport.error(status: status, data: Data("{\"error\":\"\(code)\"}".utf8))
        }
        XCTAssertEqual(error(409, "stale_record"), .staleRecord)
        XCTAssertFalse(PowerBaseRemovalError.staleRecord.leavesOutcomeUnknown, "a refusal: nothing was created")
        XCTAssertEqual(error(409, "request_id_conflict"), .rejected("request_id_conflict"))
        // What a hub answers to a request that names no registration (this app never sends one).
        XCTAssertEqual(error(422, "removal_registration_required"), .rejected("removal_registration_required"))
        XCTAssertEqual(error(422, "invalid_removal_serial"), .rejected("invalid_removal_serial"))
        XCTAssertTrue(PowerBaseRemovalError.unreachable("timeout").leavesOutcomeUnknown)
        XCTAssertTrue(PowerBaseRemovalError.badResponse("HTTP 500").leavesOutcomeUnknown)
        for refusal in [PowerBaseRemovalError.unavailable("storage"), .capacityFull, .enrollmentInProgress, .unknownPowerBase, .rejected("x"), .unauthorized] {
            XCTAssertFalse(refusal.leavesOutcomeUnknown, "\(refusal)")
        }
    }
}

// MARK: - What the sheet offers and confirms

final class PowerBaseRemovalBindingPresentationTests: XCTestCase {
    private typealias P = PowerBaseManagementPresentation
    private typealias T = PowerBaseManagementText
    private typealias F = ForgetFixtures

    private func base(record: String? = F.record, serial: Int64? = 0, management: PowerBaseManagementSupport = .supported) -> PowerBase {
        PowerBase(hardwareIdentifier: F.base, isOnline: true, moduleCount: 1, onlineModuleCount: 1, management: management, record: record, removalSerial: serial)
    }

    private func state(_ base: PowerBase?, action: PowerBaseRemovalController.Action? = nil) -> P.State {
        let snapshot = HomeSnapshot(
            timestamp: Date(timeIntervalSince1970: 0), rooms: [], modules: [], powerBases: base.map { [$0] } ?? [], reportsPowerBases: true,
            reportsPowerBaseManagement: true, reportsPowerBaseForget: true
        )
        return P.state(identifier: F.base, snapshot: snapshot, target: RemovalFixtures.target(), removal: nil, action: action, isCurrentStateVerified: true)
    }

    func testARemovalIsOfferedOnlyWhenTheHubSaysWhatTheRequestHasToName() {
        XCTAssertEqual(state(base()).availability, .available)
        XCTAssertEqual(state(base()).removalBinding, PowerBaseRemovalBinding(record: F.record, serial: 0))
        XCTAssertEqual(state(base(serial: 4)).removalBinding?.serial, 4)
        // A hub that takes the Base's id alone (0.4.x: the registration, no serial; 0.3.0: neither).
        for older in [base(serial: nil), base(record: nil, serial: nil)] {
            XCTAssertEqual(state(older).availability, .hubUnsupported, "nothing is asked of a hub that cannot be told which registration")
            XCTAssertNil(state(older).removalBinding)
        }
        XCTAssertNotEqual(T.unavailableMessage(.hubUnsupported), T.unavailableMessage(.powerBaseUnsupported), "and the app says which of the two it is")
        // The Korean source is what every translation follows.
        if AppLanguage.current == .korean {
            XCTAssertEqual(T.unavailableMessage(.hubUnsupported), "지원하지 않음: 연결된 허브가 Power Base 삭제를 지원하지 않습니다. 허브를 업데이트해야 합니다.", "and the app says what to do")
        }
        // A Base that was registered without a credential stays what it was.
        XCTAssertEqual(state(base(record: nil, serial: nil, management: .unsupported)).availability, .powerBaseUnsupported)
        XCTAssertEqual(state(nil).availability, .gone)
    }

    func testTheConfirmationKeepsWhatWasShownWhenItOpened() {
        var confirmation = PowerBaseRemovalConfirmation()
        XCTAssertFalse(confirmation.isOpen)
        XCTAssertNil(confirmation.confirmed(), "no dialog, nothing to ask")

        // The dialog opens for the registration on screen.
        let shown = state(base(record: F.record, serial: 2))
        confirmation.open(for: shown.removalBinding)
        XCTAssertTrue(confirmation.isOpen)
        // Behind it another device removes the Base and somebody registers it again: the sheet's
        // state now offers the new registration.
        let behind = state(base(record: F.laterRecord, serial: 0))
        XCTAssertEqual(behind.removalBinding, PowerBaseRemovalBinding(record: F.laterRecord, serial: 0))
        XCTAssertEqual(confirmation.confirmed(), PowerBaseRemovalBinding(record: F.record, serial: 2), "the confirm button asks for what the dialog showed")
        XCTAssertNotEqual(confirmation.confirmed(), behind.removalBinding)

        confirmation.close()
        XCTAssertNil(confirmation.confirmed())
        // Opened for a Base the hub gives nothing to name for: nothing is asked.
        confirmation.open(for: state(base(serial: nil)).removalBinding)
        XCTAssertNil(confirmation.confirmed())
        XCTAssertFalse(confirmation.isOpen)
    }

    /// The guidance and what the app does are one thing: "asking again is safe" is said of the
    /// state whose only button sends the same request again.
    func testTheWordingOfARequestWithoutAnAnswerAndOfARefusal() {
        let stale = T.failureMessage(.request(.staleRecord))
        XCTAssertFalse(T.removalResultUnknown.isEmpty)
        XCTAssertFalse(T.removalRetry.isEmpty)
        XCTAssertFalse(stale.isEmpty)
        XCTAssertNotEqual(stale, T.removalResultUnknown, "a refusal is not worded as an answer that did not arrive")
        XCTAssertNotEqual(stale, T.failureMessage(.request(.rejected("x"))))
        // The Korean source is what every translation follows.
        if AppLanguage.current == .korean {
            XCTAssertEqual(T.removalResultUnknown, "허브의 응답을 받지 못해 요청이 전달됐는지 알 수 없습니다. 다시 요청해도 안전합니다.")
            XCTAssertEqual(T.removalRetry, "다시 요청")
            XCTAssertEqual(stale, "그사이 이 Power Base의 등록이나 삭제 요청 상태가 바뀌어 삭제를 요청하지 않았습니다. 목록을 새로 확인한 뒤 다시 시도하세요.")
            XCTAssertFalse(stale.contains("안전"), "a refusal is not an invitation to send it again")
        }
        // The state is shown in the delete section, with no delete button next to it.
        XCTAssertEqual(state(base(), action: .resultUnknown).action, .resultUnknown)
    }
}

// MARK: - What the controller sends, keeps and drops

@MainActor
final class PowerBaseRemovalBindingControllerTests: XCTestCase {
    private typealias F = ForgetFixtures

    private let base = F.base
    private var hub: FakeRemovalHub!
    private var controller: PowerBaseRemovalController!
    private let source = SensorSourceIdentity.hub(id: RemovalFixtures.hubA)
    private let first = PowerBaseRemovalBinding(record: F.record, serial: 0)

    override func setUp() async throws {
        hub = FakeRemovalHub()
        let credentials = InMemoryHubCredentialStore()
        try credentials.save(RemovalFixtures.credential())
        controller = PowerBaseRemovalController(transport: hub, credentials: credentials)
        controller.targetDidChange(RemovalFixtures.target())
    }

    private func listed(record: String?, serial: Int64? = 0) -> [PowerBase] {
        [PowerBase(hardwareIdentifier: base, isOnline: true, moduleCount: 1, onlineModuleCount: 1, management: .supported, record: record, removalSerial: serial)]
    }

    private func job(_ state: PowerBaseRemoval.State, id: String = RemovalFixtures.removalID, record: String = F.record, requestID: String? = nil) -> PowerBaseRemoval {
        var removal = RemovalFixtures.removal(state, id: id, base: base)
        removal.record = record
        removal.requestID = requestID
        return removal
    }

    /// The hub's next snapshot, as `DevicesView` hands it to the controller.
    private func report(jobs: [PowerBaseRemoval] = [], forgets: [PowerBaseForget] = [], powerBases: [PowerBase]) {
        controller.sourceDidReport(jobs, forgets: forgets, powerBases: powerBases, from: source)
    }

    private func settled() async throws {
        try await waitUntil { self.controller.action(for: self.base) != .requesting }
    }

    func testARequestNamesTheConfirmedRegistrationAndEveryConfirmationIsANewRequest() async throws {
        hub.scriptRequest(.success(job(.pending)))
        controller.requestRemoval(of: base, binding: first)
        try await settled()
        hub.scriptRequest(.success(job(.pending)))
        controller.requestRemoval(of: base, binding: PowerBaseRemovalBinding(record: F.record, serial: 1))
        try await settled()
        let sent = hub.sentRequests
        XCTAssertEqual(sent.map(\.base), [base, base])
        XCTAssertEqual(sent.map(\.binding), [first, PowerBaseRemovalBinding(record: F.record, serial: 1)], "what the user was shown, each time")
        XCTAssertTrue(sent.allSatisfy { PowerBaseRemovalID.isValid($0.requestID) })
        XCTAssertNotEqual(sent[0].requestID, sent[1].requestID, "a new confirmation is a new request")
    }

    /// The hub counts in 32 bits unsigned: a count beyond `Int32.max` is requested as it is, and a
    /// request without an answer is sent again with the same number.
    func testARequestCarriesASerialFromTheUpperHalfOfTheHubsRange() async throws {
        let high = PowerBaseRemovalBinding(record: F.record, serial: 4_294_967_295)
        XCTAssertEqual(listed(record: F.record, serial: 4_294_967_295).first?.removalBinding, high)
        hub.scriptRequest(.failure(.unreachable("timeout")))
        controller.requestRemoval(of: base, binding: high)
        try await settled()
        XCTAssertEqual(controller.action(for: base), .resultUnknown)
        hub.scriptRequest(.success(job(.pending)))
        controller.retryRemoval(of: base)
        try await waitUntil { self.hub.sentRequests.count == 2 }
        try await settled()
        XCTAssertEqual(hub.sentRequests.map(\.binding), [high, high])
        XCTAssertEqual(hub.sentRequests[0].requestID, hub.sentRequests[1].requestID, "the same request")
    }

    func testARequestWithoutAnAnswerIsKeptAndSentAgainExactlyAsItWas() async throws {
        hub.scriptRequest(.failure(.unreachable("timeout")))
        controller.requestRemoval(of: base, binding: first)
        try await settled()
        XCTAssertEqual(controller.action(for: base), .resultUnknown)

        // Still no answer.
        hub.scriptRequest(.failure(.badResponse("HTTP 502")))
        controller.retryRemoval(of: base)
        try await settled()
        XCTAssertEqual(controller.action(for: base), .resultUnknown, "an answer outside the contract is no answer either")

        // Meanwhile the list changed in a way that says nothing of this registration's end (the
        // serial moved: the hub did get the request). What is sent again is still the request
        // as it was confirmed -- not one made up from what is listed now.
        report(powerBases: listed(record: F.record, serial: 1))
        XCTAssertEqual(controller.action(for: base), .resultUnknown)
        hub.scriptRequest(.success(job(.pending)))
        controller.retryRemoval(of: base)
        try await settled()
        XCTAssertNil(controller.action(for: base))
        let sent = hub.sentRequests
        XCTAssertEqual(sent.count, 3)
        XCTAssertEqual(Set(sent.map(\.requestID)).count, 1, "one confirmation, one request id")
        XCTAssertEqual(Set(sent.map(\.binding)), [first], "and the registration and serial it was confirmed for")

        // With its answer in, there is nothing to send again.
        controller.retryRemoval(of: base)
        XCTAssertEqual(hub.sentRequests.count, 3)
    }

    func testARetryIsOnlyForARequestWithoutAnAnswer() async throws {
        controller.retryRemoval(of: base)
        XCTAssertTrue(hub.sentRequests.isEmpty, "nothing was asked: nothing to ask again")
        hub.scriptRequest(.failure(.staleRecord))
        controller.requestRemoval(of: base, binding: first)
        try await settled()
        XCTAssertEqual(controller.action(for: base), .failed(.request(.staleRecord)))
        controller.retryRemoval(of: base)
        XCTAssertEqual(hub.sentRequests.count, 1, "a refusal is a final word: that request is not sent again")
        controller.dismissFailure(for: base)
        XCTAssertNil(controller.action(for: base))
        controller.retryRemoval(of: base)
        XCTAssertEqual(hub.sentRequests.count, 1)
    }

    func testARequestWithoutAnAnswerEndsWhenTheBaseIsListedUnderAnotherRegistration() async throws {
        hub.scriptRequest(.failure(.unreachable("timeout")))
        controller.requestRemoval(of: base, binding: first)
        try await settled()
        // The removal did complete, and the Base was registered again: the hub lists it under
        // another registration.
        report(powerBases: listed(record: F.laterRecord))
        XCTAssertNil(controller.action(for: base), "nothing of the earlier request is on the new registration's screen")
        controller.retryRemoval(of: base)
        XCTAssertEqual(hub.sentRequests.count, 1, "and the earlier request is never sent again by this app")
        // The new registration is removed like any other: a new confirmation, a new request.
        hub.scriptRequest(.success(job(.pending, id: RemovalFixtures.otherRemovalID, record: F.laterRecord)))
        controller.requestRemoval(of: base, binding: PowerBaseRemovalBinding(record: F.laterRecord, serial: 0))
        try await settled()
        XCTAssertEqual(hub.sentRequests.last?.binding.record, F.laterRecord)
        XCTAssertNotEqual(hub.sentRequests.last?.requestID, hub.sentRequests.first?.requestID)
    }

    func testARequestWithoutAnAnswerEndsWhenTheHubNamesItsBaseAsOutOfTheList() async throws {
        hub.scriptRequest(.failure(.unreachable("timeout")))
        controller.requestRemoval(of: base, binding: first)
        try await settled()
        // An empty list by itself says nothing (a hub that is starting again), and neither does
        // another Base being out of the list: the request stays.
        report(powerBases: [])
        XCTAssertEqual(controller.action(for: base), .resultUnknown)
        let other = PowerBaseDeparture(powerBaseIdentifier: F.otherBase, record: F.record, reason: .removed, since: nil)
        controller.sourceDidReport([], forgets: [], powerBases: [], departures: [other], from: source)
        XCTAssertEqual(controller.action(for: base), .resultUnknown)
        // Long after the removal the job is shown no more; the hub names the Base as out of its
        // list -- whichever registration ended last, the one this request named is over.
        let gone = PowerBaseDeparture(powerBaseIdentifier: base, record: nil, reason: nil, since: nil)
        controller.sourceDidReport([], forgets: [], powerBases: [], departures: [gone], from: source)
        XCTAssertNil(controller.action(for: base), "nothing is left to send again")
        controller.retryRemoval(of: base)
        XCTAssertEqual(hub.sentRequests.count, 1)
    }

    func testAnAnswerThatArrivesAfterTheBaseWasRegisteredAgainIsNobodys() async throws {
        hub.hold()
        hub.scriptRequest(.success(job(.completed)))
        controller.requestRemoval(of: base, binding: first)
        try await waitUntil { self.hub.heldCount == 1 }
        XCTAssertEqual(controller.action(for: base), .requesting)
        // While the request is on its way: removed (by another device's request), registered again.
        report(powerBases: listed(record: F.laterRecord))
        XCTAssertNil(controller.action(for: base), "the request was about a registration that is gone")
        let eventsBefore = controller.completionSerial

        hub.release()
        try await waitUntil { self.hub.heldCount == 0 }
        try await Task.sleep(for: .milliseconds(50))   // the answer has been handed to the controller
        XCTAssertNil(controller.action(for: base), "the late answer changes no state of the Base as it is listed now")
        let snapshot = HomeSnapshot(
            timestamp: Date(timeIntervalSince1970: 0), rooms: [], modules: [], powerBases: listed(record: F.laterRecord), reportsPowerBases: true,
            reportsPowerBaseManagement: true, reportsPowerBaseForget: true
        )
        XCTAssertNil(controller.removal(for: base, in: snapshot), "no job is shown for the new registration")
        XCTAssertEqual(controller.completionSerial, eventsBefore, "and nothing is announced or closed because of it")
        XCTAssertEqual(
            PowerBaseManagementPresentation.state(
                identifier: base, snapshot: snapshot, target: controller.target, removal: controller.removal(for: base, in: snapshot),
                action: controller.action(for: base), isCurrentStateVerified: true
            ).availability, .available, "its delete button is as it was"
        )
    }

    func testTheSameLateRefusalIsNobodysEither() async throws {
        hub.hold()
        hub.scriptRequest(.failure(.staleRecord))
        controller.requestRemoval(of: base, binding: first)
        try await waitUntil { self.hub.heldCount == 1 }
        report(powerBases: listed(record: F.laterRecord))
        hub.release()
        try await waitUntil { self.hub.heldCount == 0 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(controller.action(for: base), "no failure of the earlier request appears on the new registration")
    }

    func testTheHubsJobWithThisRequestsIdIsItsAnswer() async throws {
        hub.scriptRequest(.failure(.unreachable("timeout")))
        controller.requestRemoval(of: base, binding: first)
        try await settled()
        let requestID = try XCTUnwrap(hub.sentRequests.first?.requestID)

        // A job of another request does not answer this one, but shows that the registration's
        // removal is under way: the open request is settled, quietly.
        report(jobs: [job(.pending, id: RemovalFixtures.otherRemovalID, requestID: String(repeating: "1b", count: 16))], powerBases: listed(record: F.record, serial: 1))
        XCTAssertNil(controller.action(for: base))
        // That job is cancelled by whoever asked for it: the registration is as it was, with one
        // removal asked of it.
        report(jobs: [job(.cancelled, id: RemovalFixtures.otherRemovalID, requestID: String(repeating: "1b", count: 16))], powerBases: listed(record: F.record, serial: 1))

        // The user confirms anew (the answer is lost again): this time the snapshot carries the
        // job of this very request.
        hub.scriptRequest(.failure(.unreachable("timeout")))
        controller.requestRemoval(of: base, binding: PowerBaseRemovalBinding(record: F.record, serial: 1))
        try await settled()
        XCTAssertEqual(controller.action(for: base), .resultUnknown)
        let secondID = try XCTUnwrap(hub.sentRequests.last?.requestID)
        XCTAssertNotEqual(secondID, requestID)
        let own = job(.sent, requestID: secondID)
        report(jobs: [own], powerBases: listed(record: F.record, serial: 2))
        XCTAssertNil(controller.action(for: base), "the hub's word for this request arrived with the snapshot")
        let snapshot = HomeSnapshot(
            timestamp: Date(timeIntervalSince1970: 0), rooms: [], modules: [], powerBases: listed(record: F.record, serial: 2), reportsPowerBases: true,
            powerBaseRemovals: [own], reportsPowerBaseManagement: true
        )
        XCTAssertEqual(controller.removal(for: base, in: snapshot)?.id, own.id)
        controller.retryRemoval(of: base)
        XCTAssertEqual(hub.sentRequests.count, 2, "nothing is left to send again")
        // The job this device asked for completes: that is news here.
        let before = controller.completionSerial
        report(jobs: [job(.completed, requestID: secondID)], powerBases: [])
        XCTAssertEqual(controller.completionSerial, before + 1)
    }

    func testARequestOnItsWayIsAnsweredByItsOwnJobInASnapshot() async throws {
        hub.hold()
        hub.scriptRequest(.success(job(.pending)))
        controller.requestRemoval(of: base, binding: first)
        try await waitUntil { self.hub.heldCount == 1 }
        let requestID = try XCTUnwrap(hub.sentRequests.first?.requestID)
        // The event that carries the new job overtakes the answer to the request.
        report(jobs: [job(.pending, requestID: requestID)], powerBases: listed(record: F.record, serial: 1))
        XCTAssertNil(controller.action(for: base), "the hub's word for this very request is here: nothing is under way any more")
        hub.release()
        try await waitUntil { self.hub.heldCount == 0 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(controller.action(for: base))
    }

    /// With the request's id on the job, a job that this app first sees already completed is
    /// still this device's news: the hub says which request made it. (Without the id -- an
    /// earlier hub -- nothing but the Base would tie it to the request, and nothing is announced.)
    func testAJobOfThisRequestFirstSeenCompletedIsStillThisDevicesNews() async throws {
        hub.scriptRequest(.failure(.unreachable("timeout")))
        controller.requestRemoval(of: base, binding: first)
        try await settled()
        let requestID = try XCTUnwrap(hub.sentRequests.first?.requestID)
        let before = controller.completionSerial
        // A completed job of the same registration that another request made: not this device's.
        report(jobs: [job(.completed, id: RemovalFixtures.otherRemovalID, requestID: String(repeating: "1b", count: 16))], powerBases: [])
        XCTAssertEqual(controller.completionSerial, before, "another request's job, first seen completed: no news here")
        // Asked again on another registration, the answer lost, and its own job turns up completed.
        hub.scriptRequest(.failure(.unreachable("timeout")))
        controller.requestRemoval(of: base, binding: PowerBaseRemovalBinding(record: F.laterRecord, serial: 0))
        try await settled()
        let secondID = try XCTUnwrap(hub.sentRequests.last?.requestID)
        XCTAssertNotEqual(secondID, requestID)
        report(jobs: [job(.completed, record: F.laterRecord, requestID: secondID)], powerBases: [])
        XCTAssertNil(controller.action(for: base))
        XCTAssertEqual(controller.completionSerial, before + 1, "the job of this device's own request completed: that is told")
        XCTAssertEqual(controller.completionEvents.last?.completion.id, RemovalFixtures.removalID)
    }

    func testARequestOnItsWayIsNotEndedByAnotherRequestsJob() async throws {
        hub.hold()
        hub.scriptRequest(.success(job(.pending, requestID: nil)))
        controller.requestRemoval(of: base, binding: first)
        try await waitUntil { self.hub.heldCount == 1 }
        // Another device's request made the job first; the snapshot shows it.
        report(jobs: [job(.pending, requestID: String(repeating: "1b", count: 16))], powerBases: listed(record: F.record, serial: 1))
        XCTAssertEqual(controller.action(for: base), .requesting, "this request's own answer is still awaited")
        hub.release()
        try await settled()
        XCTAssertNil(controller.action(for: base), "the hub answered it with that job")
    }

    func testAnotherHubDropsTheRequestAndItsLateAnswer() async throws {
        hub.hold()
        hub.scriptRequest(.success(job(.pending)))
        controller.requestRemoval(of: base, binding: first)
        try await waitUntil { self.hub.heldCount == 1 }
        controller.targetDidChange(RemovalFixtures.target(hubID: RemovalFixtures.hubB))
        XCTAssertNil(controller.action(for: base))
        hub.release()
        try await waitUntil { self.hub.heldCount == 0 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(controller.action(for: base))
        XCTAssertTrue(controller.removals.isEmpty, "the first hub's answer is not the second hub's job")
        controller.retryRemoval(of: base)
        XCTAssertEqual(hub.sentRequests.count, 1)
    }
}

// MARK: - AppModel: two devices, one Base

@MainActor
final class AppModelRemovalBindingTests: XCTestCase {
    private typealias F = ForgetFixtures
    private typealias D = DepartureFixtures
    private typealias P = PowerBaseManagementPresentation

    private static let gasSensor = "744dbdfffe65d357"
    private static let dustSensor = "744dbdfffe65d07a"

    private final class Device {
        let transport: ControllableSensorAPITransport
        let model: AppModel
        let removalHub: FakeRemovalHub
        let removals: PowerBaseRemovalController

        init(transport: ControllableSensorAPITransport, model: AppModel, removalHub: FakeRemovalHub, removals: PowerBaseRemovalController) {
            self.transport = transport
            self.model = model
            self.removalHub = removalHub
            self.removals = removals
        }
    }

    private var settingsHub: FakeSettingsHub!
    private var devices: [Device] = []

    override func tearDown() async throws {
        devices.forEach { $0.model.stop() }
        devices = []
        settingsHub = nil
    }

    /// An app following the hub, paired, connected, with the first snapshot in.
    private func startDevice(first: Data) async throws -> Device {
        if settingsHub == nil { settingsHub = FakeSettingsHub() }
        let hub: FakeSettingsHub = settingsHub
        let credentials = InMemoryHubCredentialStore()
        let transport = ControllableSensorAPITransport { first }
        let model = AppModel(
            dataSource: LiveSensorDataSource(
                endpoint: PogoAPIEndpoint(baseURL: RemovalFixtures.url), transport: transport, sleeper: RecordingSleeper(),
                livenessIdleTimeout: 5, periodicRefreshInterval: nil
            ),
            sourceIdentity: .hub(id: hub.hubID),
            sourceAddress: RemovalFixtures.url,
            configurationStore: InMemoryHomeConfigurationStore(language: .korean),
            sharedSettings: SharedSettingsController(
                transport: hub, credentials: credentials, cache: InMemorySharedSettingsCache(), language: .korean, retryInterval: .zero
            ),
            language: .korean
        )
        let removalHub = FakeRemovalHub()
        let device = Device(transport: transport, model: model, removalHub: removalHub, removals: PowerBaseRemovalController(transport: removalHub, credentials: credentials))
        devices.append(device)
        model.start()
        try await waitUntil { model.lastSyncAt != nil }
        try await waitUntil { await transport.hasOpenEventStream }
        await transport.sendLine(": heartbeat")
        try await waitUntil { model.connectionStatus == .connected }
        _ = hub.createCode()
        _ = try await model.sharedSettings.pair(code: "7KQM-3XWD-PA9T", deviceName: "Test \(devices.count)")
        report(device)
        return device
    }

    private func deliver(_ json: Data, to device: Device) async throws {
        let before = device.model.lastSyncAt
        await device.transport.setSnapshotProvider { json }
        await device.transport.sendLines(PogoAPIFixtures.sseSnapshotEvent(json: json))
        try await waitUntil { device.model.lastSyncAt != before }
        report(device)
    }

    /// What `DevicesView` hands the controller for the first snapshot and for every change.
    private func report(_ device: Device) {
        device.removals.targetDidChange(PowerBaseHubTarget(appModel: device.model))
        device.removals.sourceDidReport(
            device.model.snapshot.powerBaseRemovals, forgets: device.model.snapshot.powerBaseForgets,
            powerBases: device.model.snapshot.powerBases, departures: device.model.snapshot.powerBaseDepartures,
            from: device.model.sourceIdentity
        )
    }

    private func sheetState(_ device: Device) -> P.State {
        P.state(
            identifier: F.base, snapshot: device.model.snapshot, target: device.removals.target,
            removal: device.removals.removal(for: F.base, in: device.model.snapshot),
            action: device.removals.action(for: F.base),
            isCurrentStateVerified: device.model.isPowerBaseStateVerified,
            forgetAction: device.removals.forgetAction(for: F.base)
        )
    }

    /// The Base with two sensors, registered under `record`, with `serial` removals asked of it.
    private func home(record: String = F.record, serial: Int64 = 0, removals: [String] = []) -> Data {
        let base = F.baseJSON(online: true, moduleCount: 2, record: record)
            .replacingOccurrences(of: "\"removal_serial\":0", with: "\"removal_serial\":\(serial)")
        return D.snapshot(
            bases: [base], modules: [F.moduleJSON(Self.gasSensor, base: F.base, online: true), F.moduleJSON(Self.dustSensor, base: F.base, online: true)],
            removals: removals
        )
    }

    private func removed(record: String = F.record, removals: [String] = []) -> Data {
        D.snapshot(bases: [], removals: removals, departures: [D.json(record: record)])
    }

    private func answered(_ state: PowerBaseRemoval.State, id: String = RemovalFixtures.removalID, record: String = F.record) -> PowerBaseRemoval {
        var removal = RemovalFixtures.removal(state, id: id)
        removal.record = record
        return removal
    }

    private func settled(_ device: Device) async throws {
        try await waitUntil { device.removals.action(for: F.base) != .requesting }
    }

    private func assertTheNewRegistrationIsUntouched(_ device: Device, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let state = sheetState(device)
        XCTAssertEqual(device.model.snapshot.powerBases.map(\.record), [F.laterRecord], "\(message): the Base is listed under the new registration", file: file, line: line)
        XCTAssertEqual(device.model.snapshot.modules.count, 2, "\(message): with its sensors", file: file, line: line)
        XCTAssertFalse(device.model.isRegistryRecovering, "\(message): not recovering", file: file, line: line)
        XCTAssertNil(state.removal, "\(message): no job is shown for it", file: file, line: line)
        XCTAssertEqual(state.removalBinding, PowerBaseRemovalBinding(record: F.laterRecord, serial: 0), "\(message): a removal of it would name it", file: file, line: line)
    }

    /// The hub's count as the JSON the hub writes, through the real data source, mapper and
    /// `AppModel`, to the sheet and into the request: every number of the hub's range is kept as
    /// it is, also the upper half that a 32-bit `Int` cannot hold.
    func testTheSerialTheHubListsIsShownAndRequestedAsItIsAcrossItsWholeRange() async throws {
        let device = try await startDevice(first: home())
        for serial: Int64 in [0, 1, 2_147_483_647, 2_147_483_648, 4_294_967_295] {
            try await deliver(home(serial: serial), to: device)
            let shown = try XCTUnwrap(sheetState(device).removalBinding, "\(serial)")
            XCTAssertEqual(shown, PowerBaseRemovalBinding(record: F.record, serial: serial))
            XCTAssertEqual(sheetState(device).availability, .available, "\(serial)")
            let before = device.removalHub.sentRequests.count
            device.removalHub.scriptRequest(.failure(.staleRecord))
            device.removals.requestRemoval(of: F.base, binding: shown)
            try await waitUntil { device.removalHub.sentRequests.count == before + 1 }
            try await settled(device)
            XCTAssertEqual(device.removalHub.sentRequests.last?.binding, shown, "\(serial)")
        }
        // A number that is no count of the hub's: nothing is offered, and the Base stays listed.
        for serial: Int64 in [-1, 4_294_967_296] {
            try await deliver(home(serial: serial), to: device)
            XCTAssertNil(sheetState(device).removalBinding, "\(serial)")
            XCTAssertEqual(device.model.snapshot.powerBases.map(\.record), [F.record], "\(serial)")
            XCTAssertEqual(device.model.snapshot.modules.count, 2, "\(serial)")
        }
    }

    // MARK: The reviewed order

    /// Phone A asks for the removal and loses the answer. The removal completes. Phone B
    /// registers the Base again. Phone A is told so by the hub's snapshot: nothing of its
    /// earlier request is left, and "다시 요청" is not there to press.
    func testALostAnswerThenARegistrationByAnotherDeviceLeavesNothingOfTheEarlierRequest() async throws {
        let a = try await startDevice(first: home())
        let b = try await startDevice(first: home())
        let shown = try XCTUnwrap(sheetState(a).removalBinding)
        XCTAssertEqual(shown, PowerBaseRemovalBinding(record: F.record, serial: 0))

        a.removalHub.scriptRequest(.failure(.unreachable("timeout")))
        a.removals.requestRemoval(of: F.base, binding: shown)
        try await settled(a)
        XCTAssertEqual(sheetState(a).action, .resultUnknown, "no answer: the request is kept, and can be sent again as it is")
        XCTAssertEqual(a.removalHub.sentRequests.map(\.binding), [shown])

        // The hub had taken it: the board carries it out, and B registers the Base again.
        for device in [a, b] { try await deliver(removed(removals: [D.job("completed")]), to: device) }
        XCTAssertNil(sheetState(a).action, "the registration A asked about is gone: its removal completed")
        XCTAssertNil(a.removals.action(for: F.base))
        for device in [a, b] { try await deliver(home(record: F.laterRecord, removals: [D.job("completed")]), to: device) }

        assertTheNewRegistrationIsUntouched(a, "on the device that asked")
        assertTheNewRegistrationIsUntouched(b, "on the device that registered it")
        XCTAssertEqual(sheetState(a).availability, .available, "the new registration can be removed -- by a new confirmation")
        a.removals.retryRemoval(of: F.base)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(a.removalHub.sentRequests.count, 1, "the earlier request is not sent again")
    }

    /// The same, but A presses "다시 요청" BEFORE it learns of the new registration (it was off the
    /// network). What it sends is the earlier request, unchanged -- which the hub refuses.
    func testARetryBeforeTheNewRegistrationIsKnownSendsTheEarlierRequestUnchanged() async throws {
        let a = try await startDevice(first: home())
        a.removalHub.scriptRequest(.failure(.unreachable("timeout")))
        a.removals.requestRemoval(of: F.base, binding: try XCTUnwrap(sheetState(a).removalBinding))
        try await settled(a)

        a.removalHub.scriptRequest(.failure(.staleRecord))   // the hub's answer to a request for a registration that is over
        a.removals.retryRemoval(of: F.base)
        try await settled(a)
        let sent = a.removalHub.sentRequests
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0], sent[1], "exactly the request that was confirmed: the earlier registration, its serial, its id")
        XCTAssertEqual(sent[1].binding.record, F.record, "never the registration that is listed by now")
        XCTAssertEqual(sheetState(a).action, .failed(.request(.staleRecord)))
        if AppLanguage.current == .korean {
            XCTAssertEqual(PowerBaseManagementText.failureMessage(.request(.staleRecord)), "그사이 이 Power Base의 등록이나 삭제 요청 상태가 바뀌어 삭제를 요청하지 않았습니다. 목록을 새로 확인한 뒤 다시 시도하세요.")
        }

        // Now the list arrives.
        try await deliver(home(record: F.laterRecord), to: a)
        XCTAssertEqual(a.model.snapshot.modules.count, 2, "the new registration's sensors are there")
        XCTAssertEqual(sheetState(a).removalBinding?.record, F.laterRecord)
        a.removals.dismissFailure(for: F.base)
        XCTAssertNil(sheetState(a).action)
        XCTAssertEqual(sheetState(a).availability, .available)
    }

    /// The dialog is open on A while B removes the Base and registers it again. A confirms.
    func testADialogThatWasOpenThroughARemovalAndARegistrationAsksForWhatItShowed() async throws {
        let a = try await startDevice(first: home(serial: 1))
        var confirmation = PowerBaseRemovalConfirmation()
        confirmation.open(for: sheetState(a).removalBinding)

        try await deliver(removed(), to: a)
        try await deliver(home(record: F.laterRecord), to: a)
        XCTAssertEqual(sheetState(a).removalBinding, PowerBaseRemovalBinding(record: F.laterRecord, serial: 0), "the sheet behind the dialog offers the new registration")

        a.removalHub.scriptRequest(.failure(.staleRecord))
        a.removals.requestRemoval(of: F.base, binding: try XCTUnwrap(confirmation.confirmed()))
        confirmation.close()
        try await settled(a)
        XCTAssertEqual(a.removalHub.sentRequests.map(\.binding), [PowerBaseRemovalBinding(record: F.record, serial: 1)], "what the dialog showed when it opened")
        XCTAssertEqual(sheetState(a).action, .failed(.request(.staleRecord)), "and the hub's refusal is shown")
        assertTheNewRegistrationIsUntouched(a, "after the refusal")
    }

    /// The answer to A's request arrives after the Base was registered again.
    func testAnAnswerThatArrivesAfterTheRegistrationChangesNothingOfTheNewOne() async throws {
        let a = try await startDevice(first: home())
        a.removalHub.hold()
        a.removalHub.scriptRequest(.success(answered(.completed)))
        a.removals.requestRemoval(of: F.base, binding: try XCTUnwrap(sheetState(a).removalBinding))
        try await waitUntil { a.removalHub.heldCount == 1 }

        try await deliver(removed(), to: a)
        try await deliver(home(record: F.laterRecord), to: a)
        assertTheNewRegistrationIsUntouched(a, "before the answer")
        let events = a.removals.completionSerial

        a.removalHub.release()
        try await waitUntil { a.removalHub.heldCount == 0 }
        try await Task.sleep(for: .milliseconds(50))
        assertTheNewRegistrationIsUntouched(a, "after the late answer")
        XCTAssertNil(sheetState(a).action)
        XCTAssertEqual(sheetState(a).availability, .available, "its delete button is as it was")
        XCTAssertEqual(a.removals.completionSerial, events, "and nothing closes or is announced on its screen")
    }

    func testTwoDevicesAskForTheSameRegistrationEachWithItsOwnRequest() async throws {
        let a = try await startDevice(first: home())
        let b = try await startDevice(first: home())
        // The hub makes one job; the second request is answered with it.
        a.removalHub.scriptRequest(.success(answered(.pending)))
        b.removalHub.scriptRequest(.success(answered(.pending)))
        a.removals.requestRemoval(of: F.base, binding: try XCTUnwrap(sheetState(a).removalBinding))
        b.removals.requestRemoval(of: F.base, binding: try XCTUnwrap(sheetState(b).removalBinding))
        try await settled(a)
        try await settled(b)
        let fromA = try XCTUnwrap(a.removalHub.sentRequests.first), fromB = try XCTUnwrap(b.removalHub.sentRequests.first)
        XCTAssertEqual(fromA.binding, fromB.binding, "both confirmed the same registration")
        XCTAssertNotEqual(fromA.requestID, fromB.requestID, "each with its own request")
        XCTAssertEqual(sheetState(a).removal?.id, sheetState(b).removal?.id, "and both show the one job the hub made")
        XCTAssertEqual(a.removalHub.sentRequests.count, 1)
        XCTAssertEqual(b.removalHub.sentRequests.count, 1)
    }

    func testAnEarlierHubIsNotAskedToRemoveAndSaysWhy() async throws {
        // Linux bridge 0.4.2: the registration, the departures -- and a removal request that
        // takes the Base's id alone.
        let earlier = F.baseJSON(online: true, moduleCount: 2, record: F.record).replacingOccurrences(of: ",\"removal_serial\":0", with: "")
        XCTAssertFalse(earlier.contains("removal_serial"))
        let a = try await startDevice(first: D.snapshot(
            bases: [earlier], modules: [F.moduleJSON(Self.gasSensor, base: F.base, online: true), F.moduleJSON(Self.dustSensor, base: F.base, online: true)]
        ))
        let state = sheetState(a)
        XCTAssertEqual(state.base?.management, .supported, "the hub can remove it")
        XCTAssertNil(state.removalBinding)
        XCTAssertEqual(state.availability, .hubUnsupported, "but not by a request this app sends")
        XCTAssertTrue(a.removalHub.sentRequests.isEmpty)
        // What it could do before, it still can: its jobs are shown, and the list removal is offered.
        try await deliver(D.snapshot(
            bases: [earlier.replacingOccurrences(of: "\"online\":true", with: "\"online\":false").replacingOccurrences(of: "\"online_module_count\":2", with: "\"online_module_count\":0")],
            modules: [F.moduleJSON(Self.gasSensor, base: F.base), F.moduleJSON(Self.dustSensor, base: F.base)], removals: [D.job("pending")]
        ), to: a)
        XCTAssertEqual(sheetState(a).removal?.presentation, .waitingForPowerBase)
        XCTAssertNotNil(sheetState(a).forgetOffer)
    }
}
