import XCTest
@testable import PogoHome

/// What the hub says of **registrations** -- `record` on a listed Base, on a removal job and on a
/// list removal -- and what the app makes of it (1.3.1):
///
/// - a job or a request is about one registration, and is never the state of another one;
/// - a removal whose Base was taken out of the hub's list while its command may be with the
///   board is shown as two answers: out of the list for certain, erased or not unknown;
/// - the confirmation of "허브 목록에서 제거" asks for the registration it was opened for.
///
/// The JSON here is the hub's own (`RemovalJobJson()`, field for field, with 0.4.1's
/// `list_removed`).
final class PowerBaseListRemovedJobTests: XCTestCase {
    private typealias P = PowerBaseManagementPresentation
    private typealias T = PowerBaseManagementText
    private typealias F = ForgetFixtures

    private func job(_ state: PowerBaseRemoval.State, listRemoved: Bool = false, resultUnknown: Bool = false, record: String? = ForgetFixtures.record) -> PowerBaseRemoval {
        var removal = RemovalFixtures.removal(state, resultUnknown: resultUnknown)
        removal.record = record
        removal.powerBaseListRemoved = listRemoved
        return removal
    }

    private func snapshot(bases: [PowerBase] = [], removals: [PowerBaseRemoval]) -> HomeSnapshot {
        HomeSnapshot(
            timestamp: Date(timeIntervalSince1970: 0), rooms: [], modules: [], powerBases: bases, reportsPowerBases: true,
            powerBaseRemovals: removals, reportsPowerBaseManagement: true, reportsPowerBaseForget: true
        )
    }

    private func base(record: String?, online: Bool = true) -> PowerBase {
        PowerBase(hardwareIdentifier: F.base, isOnline: online, moduleCount: 1, onlineModuleCount: online ? 1 : 0, management: .supported, record: record, removalSerial: 0)
    }

    // MARK: The wire

    func testTheHubsMarkIsReadOnAJobWhoseCommandMayBeWithTheBoardAndOnNoOther() throws {
        typealias Transport = URLSessionPowerBaseRemovalTransport
        let marked = ",\"list_removed\":true"
        for word in ["sent", "accepted"] {
            let removal = try Transport.decodeRemoval(Data(RemovalFixtures.json(word, extra: marked).utf8))
            XCTAssertTrue(removal.powerBaseListRemoved, word)
            XCTAssertEqual(removal.presentation, .removedFromListUnconfirmed, word)
            XCTAssertEqual(removal.record, F.record, "the job names its registration (the hub's generation)")
        }
        for word in ["pending", "released", "completed", "cancelled", "superseded"] {
            let removal = try Transport.decodeRemoval(Data(RemovalFixtures.json(word, extra: marked).utf8))
            XCTAssertFalse(removal.powerBaseListRemoved, "\(word): the mark means nothing there, whatever a hub might send")
            XCTAssertNotEqual(removal.presentation, .removedFromListUnconfirmed, word)
        }
        // A hub that does not send it (before 0.4.1), and one that says false.
        XCTAssertFalse(try Transport.decodeRemoval(Data(RemovalFixtures.json("sent").utf8)).powerBaseListRemoved)
        XCTAssertFalse(try Transport.decodeRemoval(Data(RemovalFixtures.json("sent", extra: ",\"list_removed\":false").utf8)).powerBaseListRemoved)
        // A malformed generation is no registration.
        let odd = RemovalFixtures.json("sent").replacingOccurrences(of: String(repeating: "7e", count: 16), with: "XYZ")
        XCTAssertNil(try Transport.decodeRemoval(Data(odd.utf8)).record)
    }

    func testAHubThatOnlyNamesTheKeptJobInItsListRemovalMeansTheSame() throws {
        // 0.4.0: no mark on the job; the list removal's record names the job it left as it is.
        let json = F.snapshot(
            bases: [], removals: [RemovalFixtures.json("sent"), RemovalFixtures.json("pending", id: RemovalFixtures.otherRemovalID, base: F.otherBase)],
            forgets: [F.json(kept: RemovalFixtures.removalID)]
        )
        let decoded = try PogoSnapshotMapper.decodeSnapshot(from: json)
        XCTAssertEqual(decoded.powerBaseRemovals.map(\.powerBaseListRemoved), [true, false])
        XCTAssertEqual(decoded.powerBaseRemovals.map(\.presentation), [.removedFromListUnconfirmed, .waitingForPowerBase])
        // A kept id that names a job in another state marks nothing.
        let released = try PogoSnapshotMapper.decodeSnapshot(from: F.snapshot(
            bases: [], removals: [RemovalFixtures.json("released")], forgets: [F.json(kept: RemovalFixtures.removalID)]
        ))
        XCTAssertEqual(released.powerBaseRemovals.map(\.powerBaseListRemoved), [false])
    }

    // MARK: What is shown

    func testItIsShownAsOutOfTheListAndNotConfirmedNeverAsDoneOrAsBeingCarriedOut() {
        for state in [PowerBaseRemoval.State.sent, .accepted] {
            for unknown in [false, true] {
                let removal = job(state, listRemoved: true, resultUnknown: unknown)
                XCTAssertEqual(removal.presentation, .removedFromListUnconfirmed)
                XCTAssertFalse(removal.state.isFinal, "the hub's job is not final: only the board's proof ends it")
                XCTAssertFalse(removal.cancellable)
            }
        }
        // Without the mark nothing changes.
        XCTAssertEqual(job(.sent).presentation, .inProgress)
        XCTAssertEqual(job(.accepted, resultUnknown: true).presentation, .resultUnknown)

        let title = T.removalTitle(.removedFromListUnconfirmed)
        let message = T.removalMessage(.removedFromListUnconfirmed)
        XCTAssertNotEqual(title, T.removalTitle(.completed))
        XCTAssertNotEqual(title, T.removalTitle(.inProgress))
        XCTAssertNotEqual(title, T.removalTitle(.resultUnknown))
        XCTAssertNotEqual(message, T.removalMessage(.completed))
        XCTAssertFalse(title.isEmpty)
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(PowerBaseManagementContent.symbol(.removedFromListUnconfirmed), "questionmark.circle")
    }

    func testItStaysInTheListOfRequestsWithItsOwnStateAndOffersTheConfirmationOnlyWhenTheHubDoes() {
        let fresh = job(.sent, listRemoved: true)
        let silent = job(.sent, listRemoved: true, resultUnknown: true)
        XCTAssertEqual(P.openRemovalsWithoutPowerBase(in: snapshot(removals: [fresh])).map(\.presentation), [.removedFromListUnconfirmed])
        XCTAssertEqual(P.badge(for: fresh), .removedFromListUnconfirmed)
        XCTAssertEqual(P.removalActions(for: fresh, isActing: false), [], "nothing to do, nothing to cancel")
        XCTAssertEqual(P.removalActions(for: silent, isActing: false), [.confirmErase], "the board's receipt can still be handed in near it")
        // The sheet opened from that row: nothing is offered for a Base the hub does not list.
        let state = P.state(
            identifier: F.base, snapshot: snapshot(removals: [silent]), target: RemovalFixtures.target(),
            removal: silent, action: nil, isCurrentStateVerified: true
        )
        XCTAssertNil(state.base)
        XCTAssertEqual(state.availability, .removalExists)
        XCTAssertNil(state.forgetOffer)
    }

    // MARK: A job is about one registration

    func testAJobOfAnotherRegistrationIsNeverTheListedBasesJob() {
        let later = base(record: F.laterRecord)
        for state in [PowerBaseRemoval.State.pending, .sent, .accepted, .released, .completed, .cancelled, .superseded] {
            XCTAssertFalse(job(state).concerns(later), "\(state): a job of the earlier registration")
            XCTAssertFalse(job(state, listRemoved: true).concerns(later))
        }
        // The same registration: as before -- only a completed job is history once the Base is listed.
        let same = base(record: F.record)
        for state in [PowerBaseRemoval.State.pending, .sent, .accepted, .released, .cancelled, .superseded] {
            XCTAssertTrue(job(state).concerns(same), "\(state)")
        }
        XCTAssertFalse(job(.completed).concerns(same))
        // Where either side does not say, the earlier rule decides.
        XCTAssertTrue(job(.sent, record: nil).concerns(later))
        XCTAssertTrue(job(.sent).concerns(base(record: nil)))
        XCTAssertFalse(job(.completed, record: nil).concerns(later))
        // Not listed: every job concerns its Base.
        XCTAssertTrue(job(.completed).concerns(nil))
        XCTAssertTrue(job(.sent, listRemoved: true).concerns(nil))
    }

    func testTheNewRegistrationCanBeManagedWhateverIsLeftOfTheEarlierOne() {
        let later = base(record: F.laterRecord)
        for kept in [job(.sent, listRemoved: true), job(.accepted, listRemoved: true, resultUnknown: true), job(.sent, resultUnknown: true), job(.released), job(.pending)] {
            let listed = snapshot(bases: [later], removals: [kept])
            XCTAssertNil(listed.removal(forPowerBase: F.base), "\(kept.state): not the listed Base's job")
            // Neither from the snapshot nor from an answer this device still holds.
            XCTAssertNil(PowerBaseRemovalController.removal(for: F.base, in: listed, answered: kept))
            let state = P.state(
                identifier: F.base, snapshot: listed, target: RemovalFixtures.target(),
                removal: PowerBaseRemovalController.removal(for: F.base, in: listed, answered: kept), action: nil, isCurrentStateVerified: true
            )
            XCTAssertEqual(state.availability, .available, "\(kept.state): the delete button is there")
            XCTAssertNil(P.badge(for: state.removal))
            XCTAssertTrue(P.openRemovalsWithoutPowerBase(in: listed).isEmpty, "and it is not listed as a request without a Base either")
        }
        // A job of the listed registration is shown as ever.
        var own = RemovalFixtures.removal(.pending, id: RemovalFixtures.otherRemovalID)
        own.record = F.laterRecord
        let both = snapshot(bases: [later], removals: [job(.sent, listRemoved: true), own])
        XCTAssertEqual(both.removal(forPowerBase: F.base)?.id, RemovalFixtures.otherRemovalID, "the earlier job never hides the listed registration's own")
        XCTAssertEqual(PowerBaseRemovalController.removal(for: F.base, in: both, answered: nil)?.id, RemovalFixtures.otherRemovalID)
    }

    func testTakenOutOfTheListIsALaterWordOfTheHubThanTheSameStateWithoutIt() {
        let before = job(.sent, resultUnknown: true)
        let after = job(.sent, listRemoved: true, resultUnknown: true)
        XCTAssertTrue(PowerBaseRemovalController.isFurtherAlong(after, than: before))
        XCTAssertFalse(PowerBaseRemovalController.isFurtherAlong(before, than: after))
        // An answer this device holds from before the list removal never undoes the snapshot's word.
        let shown = PowerBaseRemovalController.removal(for: F.base, in: snapshot(removals: [after]), answered: before)
        XCTAssertEqual(shown?.presentation, .removedFromListUnconfirmed)
        // And the board's word still moves the job on.
        XCTAssertTrue(PowerBaseRemovalController.isFurtherAlong(job(.released), than: after))
    }
}

/// The registration a "허브 목록에서 제거" confirmation asks for.
final class PowerBaseForgetConfirmationTests: XCTestCase {
    private typealias P = PowerBaseManagementPresentation
    private typealias F = ForgetFixtures

    func testItAsksForTheRegistrationItWasOpenedForWhateverIsOfferedLater() {
        var confirmation = PowerBaseForgetConfirmation()
        XCTAssertFalse(confirmation.isOpen)
        XCTAssertNil(confirmation.confirmedRecord(), "nothing is asked while no dialog is open")

        confirmation.open(for: P.ForgetOffer(record: F.record, removalEffect: .none))
        XCTAssertTrue(confirmation.isOpen)
        // While the dialog is open the Base is taken out by another device and registered again:
        // the sheet now offers the NEW registration. The open dialog still asks for the one shown.
        let offeredNow = P.ForgetOffer(record: F.laterRecord, removalEffect: .none)
        XCTAssertNotEqual(offeredNow.record, confirmation.confirmedRecord())
        XCTAssertEqual(confirmation.confirmedRecord(), F.record)

        confirmation.close()
        XCTAssertNil(confirmation.confirmedRecord())
        // Opened anew, it is the new registration that is confirmed.
        confirmation.open(for: offeredNow)
        XCTAssertEqual(confirmation.confirmedRecord(), F.laterRecord)
    }
}

/// This device's own requests and the registration they were made for (`settleRequests`), on the
/// controller alone: what `DevicesView` hands it for every snapshot.
@MainActor
final class PowerBaseRequestLifetimeTests: XCTestCase {
    private typealias F = ForgetFixtures

    private var hub: FakeRemovalHub!
    private var credentials: InMemoryHubCredentialStore!
    private let base = ForgetFixtures.base
    private let source = SensorSourceIdentity.hub(id: RemovalFixtures.hubA)

    override func setUp() async throws {
        hub = FakeRemovalHub()
        credentials = InMemoryHubCredentialStore([RemovalFixtures.credential(hubID: RemovalFixtures.hubA), RemovalFixtures.credential(hubID: RemovalFixtures.hubB)])
    }

    private func makeController() -> PowerBaseRemovalController {
        let controller = PowerBaseRemovalController(transport: hub, credentials: credentials)
        controller.targetDidChange(RemovalFixtures.target())
        return controller
    }

    private func listed(_ record: String?) -> [PowerBase] {
        [PowerBase(hardwareIdentifier: base, isOnline: false, moduleCount: 1, onlineModuleCount: 0, management: .supported, record: record, removalSerial: 0)]
    }

    /// A controller whose request for `F.record` got no answer.
    private func controllerWithALostAnswer() async throws -> PowerBaseRemovalController {
        let controller = makeController()
        controller.sourceDidReport([], forgets: [], powerBases: listed(F.record), from: source)
        hub.scriptForget(.failure(.unreachable("timeout")))
        controller.forgetPowerBase(base, record: F.record)
        try await waitUntil { controller.forgetAction(for: self.base) == .resultUnknown }
        return controller
    }

    private func sentRequestIDs() -> [String] {
        hub.forgets.compactMap { if case let .forget(_, _, _, _, _, requestID) = $0 { requestID } else { nil } }
    }

    func testAnotherRequestsListRemovalOfTheSameRegistrationEndsTheOpenQuestionWithoutANotice() async throws {
        let controller = try await controllerWithALostAnswer()
        let others = F.forget(requestID: "ae0c1d2e3f405162738495a6b7c8d9ea")
        controller.sourceDidReport([], forgets: [others], powerBases: [], from: source)
        XCTAssertNil(controller.forgetAction(for: base))
        XCTAssertTrue(controller.completionEvents.isEmpty, "another device's doing is not told as this one's")
        // The Base is listed again under a new registration: nothing shows, nothing is sent again.
        controller.sourceDidReport([], forgets: [others], powerBases: listed(F.laterRecord), from: source)
        XCTAssertNil(controller.forgetAction(for: base))
        controller.retryForget(of: base)
        XCTAssertEqual(hub.forgets.count, 1)
    }

    func testAListRemovalOfAnotherRegistrationOrAnotherBaseEndsNothing() async throws {
        let controller = try await controllerWithALostAnswer()
        // An earlier registration's record (the hub keeps it for a while), and another Base's.
        let earlier = F.forget(requestID: "ae0c1d2e3f405162738495a6b7c8d9ea", record: String(repeating: "11", count: 16))
        let otherBase = F.forget(id: "9d0c1d2e3f405162738495a6b7c8d9e9", requestID: "be0c1d2e3f405162738495a6b7c8d9eb", base: F.otherBase)
        controller.sourceDidReport([], forgets: [earlier, otherBase], powerBases: listed(F.record), from: source)
        XCTAssertEqual(controller.forgetAction(for: base), .resultUnknown)
    }

    func testTheSameBaseListedUnderAnotherRegistrationEndsIt() async throws {
        let controller = try await controllerWithALostAnswer()
        controller.sourceDidReport([], forgets: [], powerBases: listed(F.laterRecord), from: source)
        XCTAssertNil(controller.forgetAction(for: base))
        // A new confirmation of the new registration is a new request.
        hub.scriptForget { base, record, requestID in .success(ForgetFixtures.forget(requestID: requestID, base: base, record: record)) }
        controller.forgetPowerBase(base, record: F.laterRecord)
        try await waitUntil { controller.completionEvents.count == 1 }
        let ids = sentRequestIDs()
        XCTAssertEqual(ids.count, 2)
        XCTAssertNotEqual(ids[0], ids[1])
    }

    func testAReleasedOrCompletedRemovalOfThatRegistrationEndsIt() async throws {
        for state in [PowerBaseRemoval.State.released, .completed] {
            let controller = try await controllerWithALostAnswer()
            var removal = RemovalFixtures.removal(state)
            removal.record = F.record
            controller.sourceDidReport([removal], forgets: [], powerBases: [], from: source)
            XCTAssertNil(controller.forgetAction(for: base), "\(state)")
        }
        // A removal of that registration that is still under way, or one of another registration, does not.
        let controller = try await controllerWithALostAnswer()
        var pending = RemovalFixtures.removal(.pending)
        pending.record = F.record
        var earlier = RemovalFixtures.removal(.completed, id: RemovalFixtures.otherRemovalID)
        earlier.record = String(repeating: "11", count: 16)
        controller.sourceDidReport([pending, earlier], forgets: [], powerBases: listed(F.record), from: source)
        XCTAssertEqual(controller.forgetAction(for: base), .resultUnknown)
    }

    func testSilenceEndsNothingAndTheSameRegistrationKeepsTheQuestionOpen() async throws {
        let controller = try await controllerWithALostAnswer()
        controller.sourceDidReport([], forgets: [], powerBases: [], from: source)
        XCTAssertEqual(controller.forgetAction(for: base), .resultUnknown, "not listed, nothing said: nothing is known")
        controller.sourceDidReport([], forgets: [], powerBases: listed(F.record), from: source)
        XCTAssertEqual(controller.forgetAction(for: base), .resultUnknown)
        // A hub that does not name the registration it lists says nothing either.
        controller.sourceDidReport([], forgets: [], powerBases: listed(nil), from: source)
        XCTAssertEqual(controller.forgetAction(for: base), .resultUnknown)
        // A caller that does not say which Bases are listed changes nothing (as before 1.3.1).
        controller.sourceDidReport([], forgets: [F.forget(requestID: "ae0c1d2e3f405162738495a6b7c8d9ea")], from: source)
        XCTAssertEqual(controller.forgetAction(for: base), .resultUnknown)
    }

    func testARequestStillOnItsWayIsOverTooAndItsAnswerIsNobodys() async throws {
        let controller = makeController()
        hub.hold()
        hub.scriptForget { base, record, requestID in .success(ForgetFixtures.forget(requestID: requestID, base: base, record: record)) }
        controller.forgetPowerBase(base, record: F.record)
        try await waitUntil { self.hub.heldCount == 1 }
        XCTAssertEqual(controller.forgetAction(for: base), .requesting)
        // Another device's request for the same registration was carried out first.
        controller.sourceDidReport([], forgets: [F.forget(requestID: "ae0c1d2e3f405162738495a6b7c8d9ea")], powerBases: [], from: source)
        XCTAssertNil(controller.forgetAction(for: base))
        hub.release()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(controller.forgetAction(for: base))
        XCTAssertTrue(controller.completionEvents.isEmpty, "whatever that answer says, it is not shown")
    }

    func testThisDevicesOwnRecordStillSettlesItsRequestAndIsToldOnce() async throws {
        let controller = try await controllerWithALostAnswer()
        let own = F.forget(requestID: try XCTUnwrap(sentRequestIDs().first))
        controller.sourceDidReport([], forgets: [own], powerBases: [], from: source)
        controller.sourceDidReport([], forgets: [own], powerBases: [], from: source)
        XCTAssertNil(controller.forgetAction(for: base))
        XCTAssertEqual(controller.completionEvents.map(\.completion.kind), [.removedFromHubList])
    }

    func testARefusalIsKeptWhileTheBaseIsListedAndEndsWhenItIsNot() async throws {
        let controller = makeController()
        controller.sourceDidReport([], forgets: [], powerBases: listed(F.record), from: source)
        hub.scriptForget(.failure(.online))
        controller.forgetPowerBase(base, record: F.record)
        try await waitUntil { controller.forgetAction(for: self.base) == .failed(.request(.online)) }
        controller.sourceDidReport([], forgets: [], powerBases: listed(F.record), from: source)
        controller.sourceDidReport([], forgets: [], powerBases: listed(F.laterRecord), from: source)
        XCTAssertEqual(controller.forgetAction(for: base), .failed(.request(.online)), "a refusal is read by the user, not taken away")
        controller.sourceDidReport([], forgets: [], powerBases: [], from: source)
        XCTAssertNil(controller.forgetAction(for: base), "nothing is shown for a Base that is not listed, and nothing comes back with it")
        controller.sourceDidReport([], forgets: [], powerBases: listed(F.laterRecord), from: source)
        XCTAssertNil(controller.forgetAction(for: base))
    }

    func testTheFailureOfARemovalRequestEndsWithItsBaseToo() async throws {
        let controller = makeController()
        controller.sourceDidReport([], forgets: [], powerBases: listed(F.record), from: source)
        hub.scriptRequest(.failure(.enrollmentInProgress))
        controller.requestRemoval(of: base)
        try await waitUntil { controller.action(for: self.base) == .failed(.request(.enrollmentInProgress)) }
        controller.sourceDidReport([], forgets: [], powerBases: listed(F.laterRecord), from: source)
        XCTAssertEqual(controller.action(for: base), .failed(.request(.enrollmentInProgress)), "kept while the Base is listed")
        controller.sourceDidReport([], forgets: [], powerBases: [], from: source)
        XCTAssertNil(controller.action(for: base))
    }

    func testAnAppStartedAgainAndAnotherHubKnowNothingOfTheRequest() async throws {
        let controller = try await controllerWithALostAnswer()
        // Started again: a new controller, as after a relaunch.
        let relaunched = makeController()
        relaunched.sourceDidReport([], forgets: [], powerBases: listed(F.record), from: source)
        XCTAssertNil(relaunched.forgetAction(for: base), "the open question was this run's; the hub's list is what is shown")
        // Another hub.
        controller.targetDidChange(RemovalFixtures.target(hubID: RemovalFixtures.hubB))
        XCTAssertNil(controller.forgetAction(for: base))
        controller.retryForget(of: base)
        XCTAssertEqual(hub.forgets.count, 1)
    }
}
