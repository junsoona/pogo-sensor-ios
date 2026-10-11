import SwiftUI
import XCTest
@testable import PogoHome

/// What happens when a removal ends, and what a finished removal may never do afterwards.
///
/// The flow the user expects: confirm the removal once, it is carried out, a short "삭제 완료"
/// notice, and the Power Base is gone from the list. And the other half: the hub keeps listing the
/// finished job for ten minutes, so reading `completed` again -- after the app was started again,
/// came back to the foreground, read the same list twice, turned to another hub -- must change
/// nothing, close nothing and announce nothing.
///
/// As in `PowerBaseReenrolledAfterRemovalTests`, everything runs through the real `AppModel` and
/// the real `PowerBaseRemovalController`, wired as `DevicesView` wires them.

// MARK: - Which removals are news

final class PowerBaseRemovalCompletionsTests: XCTestCase {
    private typealias Completion = PowerBaseRemovalCompletions.Completion
    private let base = RemovalFixtures.base
    private let job = RemovalFixtures.removalID
    private let other = RemovalFixtures.otherRemovalID

    private func removal(_ state: PowerBaseRemoval.State, id: String = RemovalFixtures.removalID, base: String = RemovalFixtures.base, resultUnknown: Bool = false) -> PowerBaseRemoval {
        RemovalFixtures.removal(state, id: id, base: base, resultUnknown: resultUnknown)
    }

    func testARemovalSeenUnderWayIsAnnouncedOnceWhenItCompletes() {
        for before in [PowerBaseRemoval.State.pending, .sent, .accepted, .released] {
            var seen = PowerBaseRemovalCompletions()
            XCTAssertEqual(seen.observe([removal(before)]), [], "\(before)")
            XCTAssertEqual(seen.observe([removal(.completed)]), [Completion(id: job, powerBaseIdentifier: base)], "\(before)")
            // The hub repeats the finished job in every snapshot and in its list for ten minutes.
            for _ in 0..<5 {
                XCTAssertEqual(seen.observe([removal(.completed)]), [], "\(before): reported again")
            }
            // An older word about it arrives late (an answer that was on its way), then the
            // finished job again: it has ended, and that was said.
            XCTAssertEqual(seen.observe([removal(before)]), [], "\(before): an older answer")
            XCTAssertEqual(seen.observe([removal(.completed)]), [], "\(before): after an older answer")
        }
        // A job without a result that is confirmed by hand is one of them.
        var seen = PowerBaseRemovalCompletions()
        _ = seen.observe([removal(.accepted, resultUnknown: true)])
        XCTAssertEqual(seen.observe([removal(.completed)]).map(\.id), [job])
    }

    func testARemovalFirstReadAsCompletedIsNoNews() {
        // After the app was started again; a removal another device asked for; history.
        var seen = PowerBaseRemovalCompletions()
        XCTAssertEqual(seen.observe([removal(.completed)]), [])
        XCTAssertEqual(seen.observe([removal(.completed)]), [])
        XCTAssertEqual(seen.observe([removal(.completed), removal(.completed, id: other, base: RemovalFixtures.otherBase)]), [])
    }

    func testARemovalThatEndedAnyOtherWayIsNotAnnounced() {
        for end in [PowerBaseRemoval.State.cancelled, .superseded] {
            var seen = PowerBaseRemovalCompletions()
            _ = seen.observe([removal(.pending)])
            XCTAssertEqual(seen.observe([removal(end)]), [], "\(end)")
            XCTAssertEqual(seen.observe([removal(.completed)]), [], "\(end): a job that had ended does not come back as completed news")
        }
    }

    func testTheJobNamedInTheHubsAnswerToThisDeviceIsThisDevicesWheneverItCompletes() {
        // The usual case: the answer names a waiting job; later it completes.
        var seen = PowerBaseRemovalCompletions()
        XCTAssertEqual(seen.observeAnswer(removal(.pending)), [])
        XCTAssertEqual(seen.observe([removal(.completed)]).map(\.id), [job])
        XCTAssertEqual(seen.observe([removal(.completed)]), [])

        // The answer itself says completed (the hub was done before it answered).
        seen = PowerBaseRemovalCompletions()
        XCTAssertEqual(seen.observeAnswer(removal(.completed)).map(\.id), [job])
        XCTAssertEqual(seen.observeAnswer(removal(.completed)), [], "the same answer again")
        XCTAssertEqual(seen.observe([removal(.completed)]), [])

        // The list was quicker than the answer: the job is read completed first -- no news yet,
        // nothing ties it to this device -- and the answer then names it.
        seen = PowerBaseRemovalCompletions()
        XCTAssertEqual(seen.observe([removal(.completed)]), [])
        XCTAssertEqual(seen.observeAnswer(removal(.completed)).map(\.id), [job])
        XCTAssertEqual(seen.observe([removal(.completed)]), [])

        // The same, with an answer that is an older word than the list ("stored, waiting").
        seen = PowerBaseRemovalCompletions()
        XCTAssertEqual(seen.observe([removal(.completed)]), [])
        XCTAssertEqual(seen.observeAnswer(removal(.pending)).map(\.id), [job], "the job it names is known to be completed")
        XCTAssertEqual(seen.observe([removal(.completed)]), [])
        XCTAssertEqual(seen.observeAnswer(removal(.pending)), [])

        // An answer that names a job which ended any other way announces nothing.
        seen = PowerBaseRemovalCompletions()
        XCTAssertEqual(seen.observeAnswer(removal(.cancelled)), [])
        XCTAssertEqual(seen.observe([removal(.completed)]), [])
    }

    /// The review of `1.2.1 (9)`, R1: a request is under way, its answer has not arrived, and the
    /// first thing read is an earlier, finished job of the same Base.
    func testAnEarlierFinishedJobOfTheSameBaseIsNotTheRequestsCompletion() {
        var seen = PowerBaseRemovalCompletions()
        // (the request is under way: nothing is known of its job)
        XCTAssertEqual(seen.observe([removal(.completed)]), [], "the earlier job, read for the first time")
        XCTAssertEqual(seen.observe([removal(.completed)]), [])
        // The request's answer: another job, waiting.
        XCTAssertEqual(seen.observeAnswer(removal(.pending, id: other)), [])
        XCTAssertEqual(seen.observe([removal(.completed), removal(.pending, id: other)]), [])
        // Only that job's completion is the request's.
        XCTAssertEqual(seen.observe([removal(.completed), removal(.completed, id: other)]).map(\.id), [other])
    }

    func testARequestWithoutAnAnswerAndWithoutASightOfItsJobAnnouncesNothing() {
        // The limit that is accepted: the answer was lost and the job was never seen under way.
        // When it turns up completed nothing ties it to the request but the Base.
        var seen = PowerBaseRemovalCompletions()
        XCTAssertEqual(seen.observe([removal(.completed, id: other)]), [])
        // Had the job been seen under way even once, it would be news.
        seen = PowerBaseRemovalCompletions()
        XCTAssertEqual(seen.observe([removal(.sent, id: other)]), [])
        XCTAssertEqual(seen.observe([removal(.completed, id: other)]).map(\.id), [other])
    }

    /// The review of `1.2.1 (9)`, R2: several removals completed in one report are all returned.
    func testEveryRemovalCompletedInOneReportIsReturnedInTheOrderGiven() {
        let third = "7f0c1d2e3f405162738495a6b7c8d9e2", thirdBase = "00124b0001a2b3c6"
        let underWay = [removal(.accepted), removal(.released, id: other, base: RemovalFixtures.otherBase), removal(.sent, id: third, base: thirdBase)]
        let done = [removal(.completed), removal(.completed, id: other, base: RemovalFixtures.otherBase), removal(.completed, id: third, base: thirdBase)]
        for order in [[0, 1, 2], [2, 1, 0], [1, 2, 0]] {
            var seen = PowerBaseRemovalCompletions()
            XCTAssertEqual(seen.observe(underWay), [])
            XCTAssertEqual(seen.observe(order.map { done[$0] }).map(\.id), order.map { done[$0].id }, "\(order)")
            XCTAssertEqual(seen.observe(done), [], "and none of them again")
        }
    }

    func testAnEarlierJobTurningUpCompletedDoesNotSpeakForTheJobUnderWay() {
        // The app saw the first job under way and missed its end and the new registration. What
        // it reads next: the first job completed, and a new job of the same Base under way.
        var seen = PowerBaseRemovalCompletions()
        _ = seen.observe([removal(.accepted)])
        XCTAssertEqual(seen.observe([removal(.completed), removal(.pending, id: other)]), [], "in one report, whatever the order")
        XCTAssertEqual(seen.observe([removal(.completed)]), [], "and not later either")
        // The new job is news when it completes.
        XCTAssertEqual(seen.observe([removal(.completed), removal(.completed, id: other)]).map(\.id), [other])

        seen = PowerBaseRemovalCompletions()
        _ = seen.observe([removal(.accepted)])
        XCTAssertEqual(seen.observe([removal(.pending, id: other), removal(.completed)]), [])

        // An answer about the earlier job alone, while the new one is known to be under way.
        seen = PowerBaseRemovalCompletions()
        _ = seen.observe([removal(.released)])
        _ = seen.observe([removal(.released), removal(.sent, id: other)])
        XCTAssertEqual(seen.observe([removal(.completed)]), [])

        // Another Base's job under way stands in nobody's way.
        seen = PowerBaseRemovalCompletions()
        _ = seen.observe([removal(.released), removal(.sent, id: other, base: RemovalFixtures.otherBase)])
        XCTAssertEqual(seen.observe([removal(.completed)]).map(\.powerBaseIdentifier), [base])
    }
}

// MARK: - What is shown, and when

final class PowerBaseRemovalNoticesTests: XCTestCase {
    private typealias Completion = PowerBaseRemovalCompletions.Completion
    private let first = Completion(id: RemovalFixtures.removalID, powerBaseIdentifier: RemovalFixtures.base)
    private let second = Completion(id: RemovalFixtures.otherRemovalID, powerBaseIdentifier: RemovalFixtures.otherBase)

    func testACompletionWaitsUntilItIsShownAndIsShownToItsEndOnce() {
        var notices = PowerBaseRemovalNotices()
        notices.receive([first])
        XCTAssertEqual(notices.waiting, [first])
        XCTAssertEqual(notices.shown, [], "taking it in shows nothing")
        XCTAssertEqual(notices.show(), [first])
        XCTAssertEqual(notices.shown, [first])
        XCTAssertEqual(notices.show(), [], "showing again announces nothing new")
        notices.finish([first])
        XCTAssertEqual(notices, PowerBaseRemovalNotices(), "nothing is left to show")
        XCTAssertEqual(notices.show(), [])
    }

    func testANoticeThatWasCutShortIsShownAgainAheadOfTheRest() {
        var notices = PowerBaseRemovalNotices()
        notices.receive([first])
        _ = notices.show()
        notices.receive([second])
        notices.interrupt()
        XCTAssertEqual(notices.shown, [])
        XCTAssertEqual(notices.waiting, [first, second], "the interrupted one first")
        notices.interrupt()
        XCTAssertEqual(notices.waiting, [first, second], "interrupting what is not shown changes nothing")
        XCTAssertEqual(notices.show(), [first, second])
        notices.finish([first, second])
        XCTAssertEqual(notices, PowerBaseRemovalNotices())
    }

    func testSeveralCompletionsAreOneNoticeAndNoneIsTakenInTwice() {
        var notices = PowerBaseRemovalNotices()
        notices.receive([first, second])
        notices.receive([second, first])
        XCTAssertEqual(notices.waiting, [first, second])
        XCTAssertEqual(notices.show(), [first, second])
        notices.receive([first])
        XCTAssertEqual(notices.waiting, [], "what is on screen is not queued again")
        // One of them is put away; the other stays.
        notices.finish([first])
        XCTAssertEqual(notices.shown, [second])
    }
}

// MARK: - The app following a removal

@MainActor
final class PowerBaseRemovalCompletionFlowTests: XCTestCase {
    private typealias P = PowerBaseManagementPresentation
    private typealias F = ReenrollHubFixtures
    private typealias Completion = PowerBaseRemovalCompletions.Completion

    private var harness: ReenrollHarness!

    override func setUp() async throws {
        harness = ReenrollHarness()
    }

    override func tearDown() async throws {
        harness.stop()
        harness = nil
    }

    private var model: AppModel { harness.model }
    private var removals: PowerBaseRemovalController { harness.removals }
    private var target: PowerBaseManagementTarget { PowerBaseManagementTarget(identifier: F.base) }
    private var completed: Completion { Completion(id: RemovalFixtures.removalID, powerBaseIdentifier: F.base) }
    /// How many completion events the test has accounted for.
    private var accounted = 0

    private func automaticJob(_ state: PowerBaseRemoval.State, id: String = RemovalFixtures.removalID) -> PowerBaseRemoval {
        var job = RemovalFixtures.removal(state, id: id)
        if !state.isFinal { job.eraseConfirmation = .automatic }
        return job
    }

    private var requestCount: Int { harness.removalHub.recorded.filter { if case .request = $0 { true } else { false } }.count }

    /// The completions recorded since the last look, in order; they are accounted for from here on.
    private func newCompletions() -> [Completion] {
        let events = removals.completionEvents.dropFirst(accounted).map(\.completion)
        accounted = removals.completionEvents.count
        return events
    }

    /// The Devices tab is on screen: the notices are shown, stay their time and go.
    private func showTheNotices() {
        let appearing = removals.showWaitingNotices()
        removals.noticesWereShown(removals.notices.shown)
        XCTAssertEqual(removals.notices, PowerBaseRemovalNotices(), "nothing is left to show after \(appearing.count) notice(s)")
    }

    private func assertNothingIsAnnounced(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(removals.completionEvents.count, accounted, "no completion is recorded: \(what)", file: file, line: line)
        XCTAssertEqual(removals.notices, PowerBaseRemovalNotices(), "no notice waits or shows: \(what)", file: file, line: line)
        XCTAssertFalse(PowerBaseManagementSheet.closes(on: removals.completionEvents, after: accounted, target: target), "no screen closes: \(what)", file: file, line: line)
    }

    /// Exactly one new completion: `expected`. Its notice waits, and its Base's sheet closes.
    private func assertAnnounced(_ expected: Completion, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let before = accounted
        XCTAssertEqual(newCompletions(), [expected], what, file: file, line: line)
        XCTAssertEqual(removals.notices.waiting, [expected], "its notice waits to be shown: \(what)", file: file, line: line)
        XCTAssertTrue(PowerBaseManagementSheet.closes(on: removals.completionEvents, after: before, target: PowerBaseManagementTarget(identifier: expected.powerBaseIdentifier)),
                      "its management screen closes: \(what)", file: file, line: line)
    }

    // MARK: One confirmation, carried out, announced, gone

    func testAnOnlineBaseGoesFromOneRequestToTheNoticeAndLeavesTheLists() async throws {
        try await harness.startAppAndReport(first: F.enrolled(removals: []))
        XCTAssertEqual(harness.sheetState().availability, .available)

        // The user's one action.
        harness.removalHub.scriptRequest(.success(automaticJob(.pending)))
        removals.requestRemoval(of: F.base)
        try await waitUntil { self.removals.action(for: F.base) == nil }
        assertNothingIsAnnounced("the hub took the request")

        try await harness.receive(F.enrolled(removals: [F.removal("accepted")]))
        XCTAssertEqual(harness.sheetState().removal?.presentation, .inProgress)
        assertNothingIsAnnounced("the board has the command")
        try await harness.receive(F.snapshot(bases: [], modules: [], removals: [F.removal("released")]))
        XCTAssertEqual(harness.sheetState().removal?.presentation, .finishing)
        XCTAssertEqual(P.openRemovalsWithoutPowerBase(in: model.snapshot).map(\.state), [.released], "still a request in the list")
        assertNothingIsAnnounced("released is not removed")

        // The hub verified it.
        try await harness.receive(F.snapshot(bases: [], modules: [], removals: [F.removal("completed")]))
        XCTAssertFalse(PowerBaseManagementSheet.closes(on: removals.completionEvents, after: accounted, target: PowerBaseManagementTarget(identifier: F.otherBase)), "another Base's sheet does not close")
        assertAnnounced(completed, "the notice, for this Base")
        XCTAssertTrue(P.openRemovalsWithoutPowerBase(in: model.snapshot).isEmpty, "no row is left for it")
        XCTAssertTrue(model.snapshot.powerBases.isEmpty)
        XCTAssertTrue(model.snapshot.modules.isEmpty)
        XCTAssertEqual(requestCount, 1, "all the app ever sent")
        XCTAssertTrue(harness.removalHub.receipts.isEmpty)

        // Shown once. The hub goes on repeating the finished job: in snapshots, and in its list.
        showTheNotices()
        for _ in 0..<3 {
            try await harness.receive(F.snapshot(bases: [], modules: [], removals: [F.removal("completed")]))
            assertNothingIsAnnounced("the same finished job in the next snapshot")
        }
        harness.removalHub.scriptList(.success([RemovalFixtures.removal(.completed)]))
        await removals.refresh()
        assertNothingIsAnnounced("the same finished job in the hub's list")
    }

    func testAnOfflineBaseWaitsCanBeCancelledAndAnnouncesNothing() async throws {
        try await harness.startAppAndReport(first: F.enrolled(online: false, removals: []))
        harness.removalHub.scriptRequest(.success(automaticJob(.pending)))
        removals.requestRemoval(of: F.base)
        try await waitUntil { self.removals.action(for: F.base) == nil }
        try await harness.receive(F.enrolled(online: false, removals: [F.removal("pending")]))
        var state = harness.sheetState()
        XCTAssertEqual(state.removal?.presentation, .waitingForPowerBase)
        XCTAssertEqual(P.removalActions(for: try XCTUnwrap(state.removal), isActing: false), [.cancel])
        XCTAssertEqual(P.badge(for: state.removal), .waitingForPowerBase)

        harness.removalHub.scriptCancel(.success(RemovalFixtures.removal(.cancelled)))
        removals.cancelRemoval(try XCTUnwrap(state.removal))
        try await waitUntil { self.removals.action(for: F.base) == nil }
        state = harness.sheetState()
        XCTAssertEqual(state.removal?.presentation, .cancelled)
        XCTAssertEqual(state.availability, .available, "the Base is as it was and can be asked again")
        assertNothingIsAnnounced("a cancelled request")
        try await harness.receive(F.enrolled(online: false, removals: [F.removal("cancelled")]))
        assertNothingIsAnnounced("the snapshot with the cancelled job")
        XCTAssertEqual(model.snapshot.modules.count, 2, "the sensors stay")
    }

    func testAnOfflineBaseThatComesBackIsRemovedAndAnnouncedWithoutAnyMoreInput() async throws {
        try await harness.startAppAndReport(first: F.enrolled(online: false, removals: [F.removal("pending")]))
        XCTAssertEqual(harness.sheetState().removal?.presentation, .waitingForPowerBase)
        try await harness.receive(F.enrolled(removals: [F.removal("sent")]))
        try await harness.receive(F.snapshot(bases: [], modules: [], removals: [F.removal("released")]))
        assertNothingIsAnnounced("under way")
        try await harness.receive(F.snapshot(bases: [], modules: [], removals: [F.removal("completed")]))
        assertAnnounced(completed, "followed from 'waiting' to the end")
        XCTAssertEqual(requestCount, 0, "the request was made before this run of the app")
    }

    // MARK: Confirming by hand

    func testARemovalConfirmedByHandIsAnnouncedOnceAndLeavesTheList() async throws {
        try await harness.startAppAndReport(first: F.enrolled(removals: [F.removal("accepted", eraseConfirmation: "manual")]))
        try await harness.receive(F.snapshot(bases: [], modules: [], removals: [F.removal("released", eraseConfirmation: "manual")]))
        let state = harness.sheetState()
        XCTAssertEqual(state.removal?.presentation, .awaitingEraseConfirmation)
        XCTAssertEqual(P.removalActions(for: try XCTUnwrap(state.removal), isActing: false), [.confirmErase])
        XCTAssertEqual(P.openRemovalsWithoutPowerBase(in: model.snapshot).map(\.state), [.released], "the list's way into the sheet")
        assertNothingIsAnnounced("waiting for someone to confirm")

        // "삭제 확인" handed the board's confirmation to the hub, and the hub answered `completed`.
        // The snapshot still says `released`.
        removals.removalWasConfirmed(RemovalFixtures.removal(.completed))
        assertAnnounced(completed, "the sheet closes, with the confirmation screen on it")
        XCTAssertEqual(harness.sheetState().removal?.state, .completed, "the hub's answer is shown before its snapshot")
        showTheNotices()

        // The snapshot follows; nothing happens twice.
        try await harness.receive(F.snapshot(bases: [], modules: [], removals: [F.removal("completed")]))
        assertNothingIsAnnounced("the snapshot that follows the answer")
        XCTAssertTrue(P.openRemovalsWithoutPowerBase(in: model.snapshot).isEmpty)
    }

    func testARemovalWithoutAResultIsStillToBeConfirmedAndThenAnnounced() async throws {
        // The board's notice never reached the hub: the Base is still listed, the job has no result.
        try await harness.startAppAndReport(first: F.enrolled(online: false, removals: [F.removal("accepted", resultUnknown: true, eraseConfirmation: "manual")]))
        var state = harness.sheetState()
        XCTAssertEqual(state.removal?.presentation, .resultUnknown)
        XCTAssertEqual(P.removalActions(for: try XCTUnwrap(state.removal), isActing: false), [.confirmErase])
        XCTAssertEqual(P.badge(for: state.removal), .resultUnknown)
        XCTAssertEqual(PowerBaseReleaseConfirmationOrigin(try XCTUnwrap(state.removal)), .resultUnknown)
        XCTAssertEqual(model.snapshot.modules.count, 2, "nothing is assumed: the sensors stay")

        // Confirmed by hand. The hub's answer is ahead of the snapshot, which still lists the Base
        // with the job under way: the answer is that job further along, not history.
        removals.removalWasConfirmed(RemovalFixtures.removal(.completed))
        assertAnnounced(completed, "confirmed by hand")
        state = harness.sheetState()
        XCTAssertEqual(state.removal?.state, .completed)
        XCTAssertEqual(state.availability, .removalExists, "nothing to request of a Base that was just removed")
        showTheNotices()

        try await harness.receive(F.snapshot(bases: [], modules: [], removals: [F.removal("completed")]))
        assertNothingIsAnnounced("the snapshot that follows")
        XCTAssertTrue(model.snapshot.powerBases.isEmpty)
    }

    // MARK: Reading `completed` again is no news

    func testStartingTheAppAgainAnnouncesAndClosesNothing() async throws {
        // The Base is gone; the finished job is in the first snapshot and in the hub's list.
        try await harness.startAppAndReport(first: F.snapshot(bases: [], modules: [], removals: [F.removal("completed")]))
        assertNothingIsAnnounced("the first snapshot")
        harness.removalHub.scriptList(.success([RemovalFixtures.removal(.completed)]))
        await removals.refresh()
        assertNothingIsAnnounced("the hub's list")
        try await harness.receive(F.snapshot(bases: [], modules: [], removals: [F.removal("completed")]))
        assertNothingIsAnnounced("the next snapshot")
        XCTAssertTrue(P.openRemovalsWithoutPowerBase(in: model.snapshot).isEmpty, "and no row is shown for it")

        // Registered again since: nothing either, and the Base is managed like any other.
        try await harness.receive(F.enrolled(removals: [F.removal("completed")]))
        assertNothingIsAnnounced("the Base registered again")
        XCTAssertEqual(harness.sheetState().availability, .available)
    }

    func testComingBackToTheForegroundAnnouncesARemovalThatEndedMeanwhileOnce() async throws {
        try await harness.startAppAndReport(first: F.enrolled(removals: [F.removal("accepted")]))
        XCTAssertEqual(harness.sheetState().removal?.presentation, .inProgress)

        // The app goes to the background (`AppRootView` stops the model); the hub finishes.
        model.stop()
        let finished = F.snapshot(bases: [], modules: [], removals: [F.removal("completed")])
        await harness.transport.setSnapshotProvider { finished }
        assertNothingIsAnnounced("in the background")

        // Back: the first thing read is the finished job.
        model.start()
        try await waitUntil { self.model.snapshot.powerBaseRemovals.first?.state == .completed }
        harness.report()
        assertAnnounced(completed, "it ended while the app was following it")
        showTheNotices()

        // Away and back once more: the same finished job is no news now.
        let opened = await harness.transport.eventStreamOpenCount
        model.stop()
        model.start()
        try await waitUntil { await self.harness.transport.eventStreamOpenCount > opened }
        try await harness.receive(F.snapshot(bases: [], modules: [], removals: [F.removal("completed")]))
        assertNothingIsAnnounced("the second return")
    }

    func testTheSameReportTwiceAndInEitherOrderAnnouncesOnce() async throws {
        // The list first, the snapshot second.
        try await harness.startAppAndReport(first: F.enrolled(removals: [F.removal("accepted")]))
        try await harness.receive(F.snapshot(bases: [], modules: [], removals: [F.removal("released")]))
        harness.removalHub.scriptList(.success([RemovalFixtures.removal(.completed)]))
        await removals.refresh()
        assertAnnounced(completed, "the hub's list said it first")
        XCTAssertEqual(harness.sheetState().removal?.state, .completed)
        showTheNotices()
        harness.removalHub.scriptList(.success([RemovalFixtures.removal(.completed)]))
        await removals.refresh()
        assertNothingIsAnnounced("the list again")
        try await harness.receive(F.snapshot(bases: [], modules: [], removals: [F.removal("completed")]))
        assertNothingIsAnnounced("the snapshot after the list")
        harness.report()
        harness.report()
        assertNothingIsAnnounced("the same snapshot reported again")

        // An older list answer arriving after the snapshot undoes nothing.
        harness.removalHub.scriptList(.success([RemovalFixtures.removal(.released)]))
        await removals.refresh()
        XCTAssertEqual(harness.sheetState().removal?.state, .completed, "the snapshot's word is further along")
        assertNothingIsAnnounced("an older answer")
        try await harness.receive(F.snapshot(bases: [], modules: [], removals: [F.removal("completed")]))
        assertNothingIsAnnounced("the finished job once more, after an older answer")
    }

    func testAListThatCannotBeReadChangesNothing() async throws {
        try await harness.startAppAndReport(first: F.enrolled(removals: [F.removal("accepted")]))
        harness.removalHub.scriptList(.failure(.unreachable("timeout")))
        await removals.refresh()
        XCTAssertNotNil(removals.refreshProblem)
        XCTAssertEqual(harness.sheetState().removal?.presentation, .inProgress, "the snapshot's job is still shown")
        assertNothingIsAnnounced("an unreadable list")
        try await harness.receive(F.snapshot(bases: [], modules: [], removals: [F.removal("released")]))
        try await harness.receive(F.snapshot(bases: [], modules: [], removals: [F.removal("completed")]))
        assertAnnounced(completed, "the snapshots alone are enough")
    }

    func testALostAnswerToTheRequestIsFollowedByWhatTheAppSeesOfTheJob() async throws {
        try await harness.startAppAndReport(first: F.enrolled(removals: []))
        harness.removalHub.scriptRequest(.failure(.unreachable("timeout")))
        removals.requestRemoval(of: F.base)
        try await waitUntil { self.removals.action(for: F.base) != .requesting }
        XCTAssertEqual(removals.action(for: F.base), .resultUnknown)
        assertNothingIsAnnounced("no answer is not a result")

        // The hub had taken it. The app sees the job under way in a snapshot, then completed.
        try await harness.receive(F.enrolled(removals: [F.removal("sent")]))
        XCTAssertEqual(harness.sheetState().removal?.presentation, .inProgress)
        XCTAssertNil(removals.action(for: F.base), "the registration's removal is under way: the open request is settled by that")
        try await harness.receive(F.snapshot(bases: [], modules: [], removals: [F.removal("completed")]))
        assertAnnounced(completed, "seen under way, then completed")
    }

    /// The limit that is accepted (review R1): the answer was lost **and** the job was never seen
    /// under way. Nothing but the Base ties the completed job to the request, so no notice is
    /// made up. What the hub says is still shown: the Base and its request leave the lists.
    func testALostAnswerWithoutASightOfTheJobAnnouncesNothingButTheListsFollowTheHub() async throws {
        try await harness.startAppAndReport(first: F.enrolled(removals: []))
        harness.removalHub.scriptRequest(.failure(.unreachable("timeout")))
        removals.requestRemoval(of: F.base)
        try await waitUntil { self.removals.action(for: F.base) != .requesting }

        try await harness.receive(F.snapshot(bases: [], modules: [], removals: [F.removal("completed")]))
        assertNothingIsAnnounced("a job first read as completed, whoever asked for it")
        XCTAssertTrue(model.snapshot.powerBases.isEmpty, "the Base is gone, as on the hub")
        XCTAssertTrue(model.snapshot.modules.isEmpty)
        XCTAssertTrue(P.openRemovalsWithoutPowerBase(in: model.snapshot).isEmpty, "and no request row is left")
        XCTAssertEqual(harness.sheetState().removal?.state, .completed, "the hub's own word is what a screen would show")
    }

    // MARK: Review R1: an earlier finished job is not the request's completion

    func testAnEarlierFinishedJobReadWhileTheRequestIsUnderWayIsNotItsCompletion() async throws {
        // The Base is registered (again). No snapshot has carried its earlier, finished removal.
        try await harness.startAppAndReport(first: F.enrolled(removals: []))
        let second = RemovalFixtures.otherRemovalID
        harness.removalHub.hold()
        harness.removalHub.scriptRequest(.success(automaticJob(.pending, id: second)))
        removals.requestRemoval(of: F.base)
        try await waitUntil { self.harness.removalHub.heldCount == 1 }

        // The hub's list answers first, with the earlier job only.
        harness.removalHub.scriptList(.success([RemovalFixtures.removal(.completed)]))
        await removals.refresh()
        XCTAssertEqual(removals.action(for: F.base), .requesting)
        assertNothingIsAnnounced("the earlier job is not the request's")
        XCTAssertNil(removals.removal(for: F.base, in: model.snapshot), "and it is no state of the Base the hub lists")

        // The request's own answer: a new job, waiting.
        harness.removalHub.release()
        try await waitUntil { self.removals.action(for: F.base) == nil }
        XCTAssertEqual(harness.sheetState().removal?.id, second)
        XCTAssertEqual(harness.sheetState().removal?.presentation, .waitingForPowerBase)
        assertNothingIsAnnounced("a request that has only just been stored")

        // Both jobs in the list and in the snapshots, again and again: still nothing.
        harness.removalHub.scriptList(.success([RemovalFixtures.removal(.completed), automaticJob(.pending, id: second)]))
        await removals.refresh()
        try await harness.receive(F.enrolled(removals: [F.removal("completed"), F.removal("accepted", id: second)]))
        assertNothingIsAnnounced("the earlier job repeated next to the new one")

        // The new job's own end is the request's completion.
        try await harness.receive(F.snapshot(bases: [], modules: [], removals: [F.removal("completed"), F.removal("completed", id: second)]))
        assertAnnounced(Completion(id: second, powerBaseIdentifier: F.base), "the job the hub named in its answer")
        XCTAssertEqual(requestCount, 1)
    }

    func testTheRequestsAnswerThatIsAlreadyCompletedIsAnnounced() async throws {
        // The hub was done before it answered (or the answer was slow): the answer names the job.
        try await harness.startAppAndReport(first: F.enrolled(removals: []))
        harness.removalHub.scriptRequest(.success(RemovalFixtures.removal(.completed)))
        removals.requestRemoval(of: F.base)
        try await waitUntil { self.removals.action(for: F.base) == nil }
        assertAnnounced(completed, "the answer to this device's own request")
        showTheNotices()
        try await harness.receive(F.snapshot(bases: [], modules: [], removals: [F.removal("completed")]))
        assertNothingIsAnnounced("the snapshot that follows")

        // The list was even quicker than the answer.
        harness.stop()
        harness = ReenrollHarness()
        accounted = 0
        try await harness.startAppAndReport(first: F.enrolled(removals: []))
        harness.removalHub.hold()
        harness.removalHub.scriptRequest(.success(RemovalFixtures.removal(.completed)))
        removals.requestRemoval(of: F.base)
        try await waitUntil { self.harness.removalHub.heldCount == 1 }
        harness.removalHub.scriptList(.success([RemovalFixtures.removal(.completed)]))
        await removals.refresh()
        assertNothingIsAnnounced("read as completed before any answer named it")
        harness.removalHub.release()
        try await waitUntil { self.removals.action(for: F.base) == nil }
        assertAnnounced(completed, "the answer names the job that was read before")
    }

    // MARK: Review R2: several removals completed together

    private func twoBases(_ removals: [String]) -> Data {
        F.snapshot(bases: [F.base(), F.base(F.otherBase, moduleCount: 1)],
                   modules: [F.module(F.gasSensor), F.module(F.dustSensor), F.module(F.otherSensor, base: F.otherBase)], removals: removals)
    }

    func testTwoRemovalsCompletedInOneReportAreBothDeliveredInEitherOrder() async throws {
        let mine = completed, others = Completion(id: RemovalFixtures.otherRemovalID, powerBaseIdentifier: F.otherBase)
        let jobs = [F.base: F.removal("completed"), F.otherBase: F.removal("completed", id: RemovalFixtures.otherRemovalID, base: F.otherBase)]
        for order in [[F.base, F.otherBase], [F.otherBase, F.base]] {
            harness.stop()
            harness = ReenrollHarness()
            accounted = 0
            try await harness.startAppAndReport(first: twoBases([F.removal("accepted"), F.removal("accepted", id: RemovalFixtures.otherRemovalID, base: F.otherBase)]))
            let report = F.snapshot(bases: [], modules: [], removals: order.map { jobs[$0]! })
            try await harness.receive(report)

            let expected = order.map { $0 == F.base ? mine : others }
            XCTAssertEqual(newCompletions(), expected, "both, in the hub's order")
            XCTAssertEqual(removals.completionEvents.map(\.serial), [1, 2])
            for base in [F.base, F.otherBase] {
                XCTAssertTrue(PowerBaseManagementSheet.closes(on: removals.completionEvents, after: 0, target: PowerBaseManagementTarget(identifier: base)), "the sheet of ··\(base.suffix(4)) closes")
            }
            XCTAssertEqual(removals.notices.waiting, expected, "both notices wait")
            XCTAssertEqual(removals.showWaitingNotices(), expected, "and are shown together")
            XCTAssertEqual(removals.notices.shown, expected)
            removals.noticesWereShown(expected)

            // The same report again, the list, a late answer: nothing twice.
            try await harness.receive(F.snapshot(bases: [], modules: [], removals: order.map { jobs[$0]! }))
            harness.removalHub.scriptList(.success([RemovalFixtures.removal(.completed), RemovalFixtures.removal(.completed, id: RemovalFixtures.otherRemovalID, base: F.otherBase)]))
            await removals.refresh()
            removals.removalWasConfirmed(RemovalFixtures.removal(.completed))
            assertNothingIsAnnounced("the same completions reported again")
        }
    }

    func testARefusedRequestLeavesNothingToAnnounce() async throws {
        try await harness.startAppAndReport(first: F.enrolled(removals: []))
        harness.removalHub.scriptRequest(.failure(.capacityFull))
        removals.requestRemoval(of: F.base)
        try await waitUntil { self.removals.action(for: F.base) != .requesting }
        // A job of that Base that someone else's request made and finished, first read as completed.
        try await harness.receive(F.snapshot(bases: [], modules: [], removals: [F.removal("completed")]))
        assertNothingIsAnnounced("this device's request was refused")
    }

    // MARK: A new job, an earlier job, another hub

    func testALateAnswerAboutTheEarlierJobNeitherClosesNorOverwritesTheNewJob() async throws {
        try await harness.startAppAndReport(first: F.enrolled(removals: [F.removal("accepted")]))
        try await harness.receive(F.snapshot(bases: [], modules: [], removals: [F.removal("released")]))
        try await harness.receive(F.snapshot(bases: [], modules: [], removals: [F.removal("completed")]))
        assertAnnounced(completed, "the first removal")
        showTheNotices()

        // Registered again, and removed again: a new job, while the hub still lists the first.
        let second = RemovalFixtures.otherRemovalID
        try await harness.receive(F.enrolled(removals: [F.removal("completed")]))
        harness.removalHub.scriptRequest(.success(automaticJob(.pending, id: second)))
        removals.requestRemoval(of: F.base)
        try await waitUntil { self.removals.action(for: F.base) == nil }
        XCTAssertEqual(harness.sheetState().removal?.id, second)
        try await harness.receive(F.enrolled(removals: [F.removal("completed"), F.removal("accepted", id: second)]))

        // Answers about the first job arrive late: its confirmation, and a list read before.
        removals.removalWasConfirmed(RemovalFixtures.removal(.completed))
        assertNothingIsAnnounced("the earlier job's confirmation")
        harness.removalHub.scriptList(.success([RemovalFixtures.removal(.completed)]))
        await removals.refresh()
        assertNothingIsAnnounced("the earlier job in a list")
        var state = harness.sheetState()
        XCTAssertEqual(state.removal?.id, second, "the job under way is the one shown")
        XCTAssertEqual(state.removal?.presentation, .inProgress)
        XCTAssertEqual(state.availability, .removalExists)

        // The new job goes its own way and is announced when it ends.
        try await harness.receive(F.snapshot(bases: [], modules: [], removals: [F.removal("completed"), F.removal("released", id: second)]))
        state = harness.sheetState()
        XCTAssertEqual(state.removal?.id, second)
        XCTAssertEqual(state.removal?.presentation, .finishing)
        assertNothingIsAnnounced("the new job is only released")
        try await harness.receive(F.snapshot(bases: [], modules: [], removals: [F.removal("completed"), F.removal("completed", id: second)]))
        assertAnnounced(Completion(id: second, powerBaseIdentifier: F.base), "the new job")
        XCTAssertEqual(requestCount, 1)
    }

    func testAnAnswerThatTheSnapshotsHaveOvertakenIsNotShownAgainLater() async throws {
        // This device asked; someone else cancelled; the hub then dropped the job from its history.
        try await harness.startAppAndReport(first: F.enrolled(online: false, removals: []))
        harness.removalHub.scriptRequest(.success(automaticJob(.pending)))
        removals.requestRemoval(of: F.base)
        try await waitUntil { self.removals.action(for: F.base) == nil }
        try await harness.receive(F.enrolled(online: false, removals: [F.removal("pending")]))
        XCTAssertEqual(harness.sheetState().removal?.presentation, .waitingForPowerBase)
        try await harness.receive(F.enrolled(online: false, removals: [F.removal("cancelled")]))
        XCTAssertEqual(harness.sheetState().removal?.presentation, .cancelled)
        try await harness.receive(F.enrolled(online: false, removals: []))
        let state = harness.sheetState()
        XCTAssertNil(state.removal, "the answer of long ago does not come back as '삭제 대기'")
        XCTAssertEqual(state.availability, .available)
        XCTAssertNil(P.badge(for: state.removal))
    }

    func testAnotherHubStartsFromNothing() async throws {
        try await harness.startAppAndReport(first: F.enrolled(removals: [F.removal("accepted")]))
        harness.removalHub.hold()
        harness.removalHub.scriptRequest(.success(automaticJob(.pending)))
        removals.requestRemoval(of: F.base)
        try await waitUntil { self.harness.removalHub.heldCount == 1 }

        // The app turns to hub B, which happens to list the same Base and the same job id -- there
        // the job is finished.
        let hubB = FakeSettingsHub(hubID: String(repeating: "b", count: 32))
        let onB = F.snapshot(bases: [], modules: [], removals: [F.removal("completed")])
        let transportB = ControllableSensorAPITransport { onB }
        model.replace(dataSource: harness.liveSource(transportB), identity: .hub(id: hubB.hubID), address: URL(string: "http://192.168.1.11:8787"))
        removals.targetDidChange(PowerBaseHubTarget(appModel: model))
        harness.report()
        try await waitUntil { self.model.snapshot.powerBaseRemovals.first?.state == .completed }
        harness.report()
        assertNothingIsAnnounced("what hub A had under way says nothing about hub B's job")

        // Hub A's answer arrives now: it belongs to no screen of hub B.
        harness.removalHub.release()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(removals.action(for: F.base))
        assertNothingIsAnnounced("the previous hub's late answer")
        XCTAssertEqual(removals.removal(for: F.base, in: model.snapshot)?.state, .completed, "hub B's own word")
    }

    // MARK: The sensors and rooms of the new registration

    func testAHubRestartAfterTheBaseWasRegisteredAgainKeepsItsSensorsAndRooms() async throws {
        let store = InMemoryHomeConfigurationStore(language: .korean)
        try await harness.startAppAndReport(first: F.enrolled(removals: [F.removal("accepted")]), store: store)
        try await harness.receive(F.snapshot(bases: [], modules: [], removals: [F.removal("released")]))
        try await harness.receive(F.snapshot(bases: [], modules: [], removals: [F.removal("completed")]))
        XCTAssertTrue(model.snapshot.modules.isEmpty)
        assertAnnounced(completed, "the removal")
        showTheNotices()

        // Registered again; the user puts a sensor into a room and names it.
        try await harness.receive(F.enrolled(removals: [F.removal("completed")]))
        XCTAssertEqual(model.health, .healthy)
        let sensor = try XCTUnwrap(model.snapshot.modules.first { $0.hardwareIdentifier == F.gasSensor })
        let room = try XCTUnwrap(model.editableRooms.first { $0.id != ModuleCatalog.unspecifiedRoomID })
        try await model.updateModule(id: sensor.id, customName: "거실 공기", roomID: room.id)
        XCTAssertEqual(model.module(with: sensor.id)?.roomID, room.id)

        // The hub starts again: for a moment it lists nothing but the finished job of the earlier
        // registration. That job is no reason for the new registration's sensors to leave.
        for _ in 0..<2 {
            try await harness.receive(F.snapshot(bases: [], modules: [], removals: [F.removal("completed")]))
            XCTAssertEqual(model.snapshot.modules.count, 2, "the sensors stay")
            XCTAssertEqual(model.snapshot.powerBases.map(\.hardwareIdentifier), [F.base])
            XCTAssertEqual(model.module(with: sensor.id)?.roomID, room.id, "in their rooms")
            XCTAssertEqual(model.module(with: sensor.id)?.name, "거실 공기")
            XCTAssertTrue(model.isRegistryRecovering)
            assertNothingIsAnnounced("a hub restart")
            XCTAssertNil(P.badge(for: removals.removal(for: F.base, in: model.snapshot)), "and nothing says '삭제 완료' meanwhile")
            XCTAssertEqual(harness.sheetState().availability, .available)
        }
        // The topology comes back before the first samples, then everything.
        try await harness.receive(F.snapshot(
            bases: [F.base()], modules: [F.module(F.gasSensor, hasReadings: false), F.module(F.dustSensor, hasReadings: false)], removals: [F.removal("completed")]
        ))
        XCTAssertEqual(model.module(with: sensor.id)?.roomID, room.id)
        try await harness.receive(F.enrolled(removals: [F.removal("completed")]))
        XCTAssertFalse(model.isRegistryRecovering)
        XCTAssertEqual(model.health, .healthy)
        XCTAssertEqual(model.module(with: sensor.id)?.roomID, room.id)
        XCTAssertEqual(model.module(with: sensor.id)?.name, "거실 공기")
        XCTAssertEqual(try store.load().modules[sensor.id]?.roomID, room.id, "the saved placement was never touched")

        // Once the hub drops the finished job from its list, nothing changes either.
        try await harness.receive(F.enrolled(removals: []))
        XCTAssertEqual(harness.sheetState().availability, .available)
        assertNothingIsAnnounced("the history ran out")
    }
}

// MARK: - The screens

/// The real `PowerBaseManagementSheet` and the real `DevicesView`, in a window of the test host,
/// told that the app is in the foreground. What happens across a real trip to the background is in
/// `PowerBaseRemovalRealSceneTests`.
@MainActor
final class PowerBaseRemovalCompletionScreenTests: XCTestCase {
    private typealias F = ReenrollHubFixtures
    private typealias Completion = PowerBaseRemovalCompletions.Completion

    private var harness: ReenrollHarness!
    private var screen: HostedScreen?
    /// What the Devices tab asked VoiceOver to say, in order.
    private var announced: [String] = []

    override func setUp() async throws {
        harness = ReenrollHarness()
        announced = []
    }

    override func tearDown() async throws {
        screen?.close()
        screen = nil
        harness.removalHub?.release()
        harness.stop()
        harness = nil
    }

    /// The real sheet, presented the way `DevicesView` presents it.
    private struct SheetHost: View {
        @Bindable var actions: DeviceActions
        let controller: PowerBaseRemovalController

        var body: some View {
            Color.clear
                .sheet(item: $actions.managingPowerBase) { target in
                    PowerBaseManagementSheet(target: target, controller: controller)
                }
        }
    }

    private func presentTheSheet(for identifier: String) async throws -> DeviceActions {
        screen?.close()
        let actions = DeviceActions()
        let hosted = try HostedScreen(SheetHost(actions: actions, controller: harness.removals).environment(harness.model).environment(\.scenePhase, .active))
        screen = hosted
        actions.managingPowerBase = PowerBaseManagementTarget(identifier: identifier)
        try await waitUntil(timeout: 5) { hosted.isPresenting }
        return actions
    }

    /// The real Devices tab on the harness's model and controller, in the foreground.
    private func showTheDevicesTab(actions: DeviceActions = DeviceActions(), navigator: AppNavigator? = nil, noticeDuration: Duration = .seconds(5)) async throws -> HostedScreen {
        let tab = DevicesView(actions: actions, removals: harness.removals, noticeDuration: noticeDuration, announce: { [weak self] in self?.announced.append($0) })
            .environment(harness.model).environment(AppleHomeModel.preview).environment(\.scenePhase, .active)
        let hosted = try navigator.map { try HostedScreen(tab.environment($0)) } ?? HostedScreen(tab)
        screen = hosted
        // The tab is up and has handed the controller the jobs of the snapshot on screen.
        try await waitUntil(timeout: 5) { self.harness.removals.reportedSource == self.harness.model.sourceIdentity }
        return hosted
    }

    private func notice(_ base: String = F.base) -> String {
        PowerBaseManagementText.completionNotice(label: PowerBaseManagementPresentation.label(forIdentifier: base))
    }

    private func twoBases(_ removals: [String]) -> Data {
        F.snapshot(bases: [F.base(), F.base(F.otherBase, moduleCount: 1)],
                   modules: [F.module(F.gasSensor), F.module(F.dustSensor), F.module(F.otherSensor, base: F.otherBase)], removals: removals)
    }

    private var bothUnderWay: [String] { [F.removal("accepted"), F.removal("accepted", id: RemovalFixtures.otherRemovalID, base: F.otherBase)] }

    private func bothCompleted(firstInTheList first: String) -> [String] {
        let mine = F.removal("completed"), others = F.removal("completed", id: RemovalFixtures.otherRemovalID, base: F.otherBase)
        return first == F.base ? [mine, others] : [others, mine]
    }

    // MARK: The management sheet

    func testTheManagementSheetClosesWhenItsRemovalIsCompleted() async throws {
        try await harness.startAppAndReport(first: F.enrolled(removals: [F.removal("accepted")]))
        let actions = try await presentTheSheet(for: F.base)
        let hosted = try XCTUnwrap(screen)

        try await harness.receive(F.snapshot(bases: [], modules: [], removals: [F.removal("released")]))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNotNil(actions.managingPowerBase, "released is not removed: the sheet stays")
        XCTAssertTrue(hosted.isPresenting)

        try await harness.receive(F.snapshot(bases: [], modules: [], removals: [F.removal("completed")]))
        try await waitUntil(timeout: 5) { actions.managingPowerBase == nil }
        try await waitUntil(timeout: 5) { !hosted.isPresenting }
    }

    /// Review R2: two removals complete in one report. Whichever Base's sheet is open, and wherever
    /// its job stands in the hub's list, that sheet closes.
    func testEachBasesSheetClosesWhenBothRemovalsCompleteInOneReport() async throws {
        for (open, first) in [(F.base, F.base), (F.base, F.otherBase), (F.otherBase, F.base), (F.otherBase, F.otherBase)] {
            harness.stop()
            harness = ReenrollHarness()
            try await harness.startAppAndReport(first: twoBases(bothUnderWay))
            let actions = try await presentTheSheet(for: open)
            try await harness.receive(F.snapshot(bases: [], modules: [], removals: bothCompleted(firstInTheList: first)))
            let deadline = Date().addingTimeInterval(3)
            while actions.managingPowerBase != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertNil(actions.managingPowerBase, "the sheet of ··\(open.suffix(4)) closes when its removal is completed (first in the list: ··\(first.suffix(4)))")
        }
    }

    /// Review R1: the sheet of a Base whose removal has only been requested stays open when an
    /// earlier, finished job of that Base is read meanwhile.
    func testTheManagementSheetStaysOpenWhenAnEarlierFinishedJobIsReadDuringTheRequest() async throws {
        try await harness.startAppAndReport(first: F.enrolled(removals: []))
        let removals = harness.removals!
        let actions = try await presentTheSheet(for: F.base)
        harness.removalHub.hold()
        harness.removalHub.scriptRequest(.success(RemovalFixtures.removal(.pending, id: RemovalFixtures.otherRemovalID)))
        removals.requestRemoval(of: F.base)
        try await waitUntil { self.harness.removalHub.heldCount == 1 }

        harness.removalHub.scriptList(.success([RemovalFixtures.removal(.completed)]))
        await removals.refresh()
        harness.removalHub.release()
        try await waitUntil { removals.action(for: F.base) == nil }
        // Every chance for the sheet to react to what was read.
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(actions.managingPowerBase?.identifier, F.base, "the sheet is still open")
        XCTAssertEqual(screen?.isPresenting, true)
        XCTAssertTrue(removals.completionEvents.isEmpty)

        // The new job's own completion closes it.
        try await harness.receive(F.snapshot(bases: [], modules: [], removals: [F.removal("completed"), F.removal("completed", id: RemovalFixtures.otherRemovalID)]))
        try await waitUntil(timeout: 5) { actions.managingPowerBase == nil }
        XCTAssertEqual(removals.completionEvents.map(\.completion.id), [RemovalFixtures.otherRemovalID])
    }

    func testTheManagementSheetStaysForAFinishedRemovalOfBeforeAndForAnotherBase() async throws {
        // The Base on screen was registered again; its earlier removal is still in the hub's list.
        // Another Base is being removed.
        let other = F.base(F.otherBase, moduleCount: 1)
        let otherSensor = F.module(F.otherSensor, base: F.otherBase)
        let both: ([String]) -> Data = { removals in
            F.snapshot(bases: [F.base(), other], modules: [F.module(F.gasSensor), F.module(F.dustSensor), otherSensor], removals: removals)
        }
        let otherJob = RemovalFixtures.otherRemovalID
        try await harness.startAppAndReport(first: both([F.removal("completed"), F.removal("accepted", id: otherJob, base: F.otherBase)]))
        let actions = try await presentTheSheet(for: F.base)
        let hosted = try XCTUnwrap(screen)
        // Read where the sheet is part of the window (on the Mac it is a window of its own).
        if !PlatformSupport.isMacCatalyst {
            let labels = try await hosted.labels()
            XCTAssertTrue(labels.contains(PowerBaseManagementText.delete), "the sheet of the new registration offers the delete button: \(labels)")
        }
        XCTAssertEqual(harness.sheetState().availability, .available)

        // The finished job is repeated; the hub's list is read; the other Base's removal completes.
        try await harness.receive(both([F.removal("completed"), F.removal("accepted", id: otherJob, base: F.otherBase)]))
        harness.removalHub.scriptList(.success([RemovalFixtures.removal(.completed)]))
        await harness.removals.refresh()
        try await harness.receive(F.snapshot(
            bases: [F.base()], modules: [F.module(F.gasSensor), F.module(F.dustSensor)],
            removals: [F.removal("completed"), F.removal("completed", id: otherJob, base: F.otherBase)]
        ))
        XCTAssertEqual(harness.removals.completionEvents.map(\.completion.powerBaseIdentifier), [F.otherBase], "the other Base's removal is the one event")
        // The sheet has had every chance to react.
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(actions.managingPowerBase?.identifier, F.base, "this Base's sheet is still open")
        XCTAssertTrue(hosted.isPresenting)
    }

    func testASheetOpenedAfterTheRemovalOfItsBaseWasCompletedStaysOpen() async throws {
        // Removed and announced; registered again; only then is the sheet opened.
        try await harness.startAppAndReport(first: F.enrolled(removals: [F.removal("accepted")]))
        try await harness.receive(F.snapshot(bases: [], modules: [], removals: [F.removal("completed")]))
        XCTAssertEqual(harness.removals.completionEvents.count, 1)
        try await harness.receive(F.enrolled(removals: [F.removal("completed")]))
        let actions = try await presentTheSheet(for: F.base)

        // The finished job goes on being reported, by every way there is.
        try await harness.receive(F.enrolled(removals: [F.removal("completed")]))
        harness.removalHub.scriptList(.success([RemovalFixtures.removal(.completed)]))
        await harness.removals.refresh()
        harness.removals.removalWasConfirmed(RemovalFixtures.removal(.completed))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(actions.managingPowerBase?.identifier, F.base, "a completion from before the sheet was opened is not its own")
        XCTAssertEqual(screen?.isPresenting, true)
        XCTAssertEqual(harness.removals.completionEvents.count, 1)
    }

    // MARK: The Devices tab

    /// The request row while the removal is under way, then the notice -- shown and announced
    /// once -- and no row left.
    func testTheDevicesTabShowsTheNoticeOnceAndNoRowForTheFinishedRemoval() async throws {
        // Another Base stays, so the tab keeps its list throughout.
        let other = F.base(F.otherBase, moduleCount: 1)
        let otherSensor = F.module(F.otherSensor, base: F.otherBase)
        try await harness.startApp(first: F.snapshot(
            bases: [F.base(), other], modules: [F.module(F.gasSensor), F.module(F.dustSensor), otherSensor], removals: [F.removal("accepted")]
        ))
        let hosted = try await showTheDevicesTab()
        let label = PowerBaseManagementPresentation.label(forIdentifier: F.base)
        let removing = PowerBaseManagementText.removalTitle(.inProgress)
        var labels = try await hosted.labels()
        XCTAssertTrue(labels.contains { $0.contains(label) && $0.contains(removing) }, "the Base's row says it is being removed: \(labels)")
        XCTAssertFalse(labels.contains { $0.contains(notice()) })

        try await harness.deliver(F.snapshot(bases: [other], modules: [otherSensor], removals: [F.removal("released")]))
        labels = try await hosted.labels()
        XCTAssertTrue(labels.contains(PowerBaseManagementText.listHeader), "the request is listed while it is under way: \(labels)")
        XCTAssertFalse(labels.contains { $0.contains(notice()) }, "released is not announced as removed: \(labels)")
        XCTAssertEqual(announced, [])

        try await harness.deliver(F.snapshot(bases: [other], modules: [otherSensor], removals: [F.removal("completed")]))
        labels = try await hosted.labels()
        XCTAssertEqual(labels.filter { $0.contains(notice()) }.count, 1, "the notice, once: \(labels)")
        XCTAssertFalse(labels.contains(PowerBaseManagementText.listHeader), "no list of requests is left: \(labels)")
        XCTAssertFalse(labels.contains { $0.contains(label) && !$0.contains(notice()) }, "and no row of the removed Base: \(labels)")
        XCTAssertEqual(announced, [notice()], "VoiceOver is told once")

        // The same finished job in the next snapshots: still that one notice, until it goes away.
        try await harness.deliver(F.snapshot(bases: [other], modules: [otherSensor], removals: [F.removal("completed")]))
        labels = try await hosted.labels()
        XCTAssertLessThanOrEqual(labels.filter { $0.contains(notice()) }.count, 1, "\(labels)")
        XCTAssertFalse(labels.contains(PowerBaseManagementText.listHeader))
        XCTAssertEqual(announced, [notice()])
    }

    /// Review R2 on the screen: two removals that end together are both shown and both announced.
    func testTwoRemovalsThatEndTogetherAreBothShownAndAnnounced() async throws {
        for first in [F.base, F.otherBase] {
            screen?.close()
            harness.stop()
            harness = ReenrollHarness()
            announced = []
            try await harness.startApp(first: twoBases(bothUnderWay))
            let hosted = try await showTheDevicesTab(noticeDuration: .seconds(2))
            try await harness.deliver(F.snapshot(bases: [], modules: [], removals: bothCompleted(firstInTheList: first)))
            let order = first == F.base ? [F.base, F.otherBase] : [F.otherBase, F.base]
            try await waitUntil(timeout: 5) { self.announced.count == 2 }
            XCTAssertEqual(announced, order.map { notice($0) }, "each is announced, in the hub's order (events \(harness.removals.completionEvents.map(\.completion.powerBaseIdentifier)), notices \(harness.removals.notices), first \(first.suffix(4)))")
            let labels = try await hosted.labels()
            XCTAssertTrue(labels.contains { $0.contains(notice(F.base)) && $0.contains(notice(F.otherBase)) }, "one notice names both: \(labels)")
            // It stays its time and goes; the same report again brings nothing back.
            try await waitUntil(timeout: 6) { self.harness.removals.notices == PowerBaseRemovalNotices() }
            try await harness.deliver(F.snapshot(bases: [], modules: [], removals: bothCompleted(firstInTheList: first)))
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(announced.count, 2, "nothing is announced twice")
            XCTAssertEqual(harness.removals.notices, PowerBaseRemovalNotices())
        }
    }

    func testTheSheetOfTheRemovedBaseClosesAndThenItsNoticeIsShown() async throws {
        try await harness.startApp(first: F.enrolled(removals: [F.removal("accepted")]))
        let actions = DeviceActions()
        let hosted = try await showTheDevicesTab(actions: actions, noticeDuration: .seconds(2))
        actions.managingPowerBase = PowerBaseManagementTarget(identifier: F.base)
        try await waitUntil(timeout: 5) { hosted.isPresenting }

        try await harness.deliver(F.snapshot(bases: [], modules: [], removals: [F.removal("completed")]))
        try await waitUntil(timeout: 5) { actions.managingPowerBase == nil }
        try await waitUntil(timeout: 5) { self.announced == [self.notice()] }
        XCTAssertEqual(harness.removals.notices.shown.map(\.powerBaseIdentifier), [F.base], "shown once the sheet is out of the way")
        try await waitUntil(timeout: 6) { self.harness.removals.notices == PowerBaseRemovalNotices() }
        XCTAssertEqual(announced.count, 1)
    }

    /// A sheet over the tab (here: another Base's management sheet) hides the notice's place. The
    /// completion waits; its time does not run; the sheet that is open is not closed by it.
    func testACompletionWaitsWhileASheetCoversTheTab() async throws {
        try await harness.startApp(first: twoBases([F.removal("accepted")]))
        let actions = DeviceActions()
        let hosted = try await showTheDevicesTab(actions: actions, noticeDuration: .milliseconds(400))
        actions.managingPowerBase = PowerBaseManagementTarget(identifier: F.otherBase)
        try await waitUntil(timeout: 5) { hosted.isPresenting }

        try await harness.deliver(F.snapshot(bases: [F.base(F.otherBase, moduleCount: 1)], modules: [F.module(F.otherSensor, base: F.otherBase)], removals: [F.removal("completed")]))
        try await waitUntil { self.harness.removals.completionEvents.count == 1 }
        // Longer than the notice's own time, with the sheet over the tab.
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(announced, [], "nothing is announced behind a sheet")
        XCTAssertEqual(harness.removals.notices.shown, [])
        XCTAssertEqual(harness.removals.notices.waiting.map(\.powerBaseIdentifier), [F.base], "the notice waits, its time unspent")
        XCTAssertEqual(actions.managingPowerBase?.identifier, F.otherBase, "the other Base's sheet is still open")

        // The user closes the sheet: now it is shown, once.
        actions.managingPowerBase = nil
        try await waitUntil(timeout: 5) { self.announced == [self.notice()] }
        XCTAssertEqual(harness.removals.notices.shown.map(\.powerBaseIdentifier), [F.base])
        try await waitUntil(timeout: 5) { self.harness.removals.notices == PowerBaseRemovalNotices() }
        XCTAssertEqual(announced.count, 1)
    }

    /// Another tab is selected: the Devices tab is not on screen.
    func testACompletionWaitsWhileAnotherTabIsSelected() async throws {
        try await harness.startApp(first: F.enrolled(removals: [F.removal("accepted")]))
        let navigator = AppNavigator()
        navigator.selectedTab = .devices
        _ = try await showTheDevicesTab(navigator: navigator, noticeDuration: .milliseconds(400))
        navigator.selectedTab = .settings
        try await Task.sleep(for: .milliseconds(100))

        try await harness.deliver(F.snapshot(bases: [], modules: [], removals: [F.removal("completed")]))
        try await waitUntil { self.harness.removals.completionEvents.count == 1 }
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(announced, [], "nothing is announced on another tab")
        XCTAssertEqual(harness.removals.notices.waiting.map(\.powerBaseIdentifier), [F.base], "the notice waits, its time unspent")

        navigator.selectedTab = .devices
        try await waitUntil(timeout: 5) { self.announced == [self.notice()] }
        try await waitUntil(timeout: 5) { self.harness.removals.notices == PowerBaseRemovalNotices() }
        // Away and back once more: nothing again.
        navigator.selectedTab = .home
        navigator.selectedTab = .devices
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(announced.count, 1)
    }

    /// The same through the app's real tab view (`AppRootView`): the Devices tab is left, the
    /// removal completes, and the notice is there when the user comes back -- after more than the
    /// notice's own five seconds on another tab. (One fixed wait: the app's real notice time.)
    func testTheRealTabViewKeepsTheNoticeForTheReturnToTheDevicesTab() async throws {
        try XCTSkipIf(PlatformSupport.isMacCatalyst, "the Mac's sidebar keeps the tab's labels out of this window's tree; covered by the test above")
        try await harness.startApp(first: twoBases([F.removal("accepted")]))
        let navigator = AppNavigator()
        navigator.selectedTab = .devices
        let hosted = try HostedScreen(AppRootView().environment(harness.model).environment(AppleHomeModel.preview).environment(navigator).environment(\.scenePhase, .active))
        screen = hosted
        var labels = try await hosted.labels()
        let label = PowerBaseManagementPresentation.label(forIdentifier: F.base)
        XCTAssertTrue(labels.contains { $0.contains(label) && $0.contains(PowerBaseManagementText.removalTitle(.inProgress)) }, "the Devices tab shows the removal under way: \(labels)")

        navigator.selectedTab = .settings
        try await harness.deliver(F.snapshot(bases: [F.base(F.otherBase, moduleCount: 1)], modules: [F.module(F.otherSensor, base: F.otherBase)], removals: [F.removal("completed")]))
        try await Task.sleep(for: .milliseconds(5500))
        labels = try await hosted.labels()
        XCTAssertFalse(labels.contains { $0.contains(notice()) }, "nothing of it on the Settings tab: \(labels)")

        navigator.selectedTab = .devices
        var found = false
        let deadline = Date().addingTimeInterval(4)
        while !found, Date() < deadline { found = try await hosted.labels().contains { $0.contains(notice()) } }
        XCTAssertTrue(found, "the notice is shown when the user is back on the Devices tab")
    }

    // MARK: Another hub, a screen that was left

    func testThePreviousHubsLateAnswerClosesNothingAndAnnouncesNothingOnTheNewHub() async throws {
        try await harness.startApp(first: F.enrolled(removals: []))
        let actions = DeviceActions()
        let hosted = try await showTheDevicesTab(actions: actions, noticeDuration: .milliseconds(400))
        let removals = harness.removals!
        harness.removalHub.hold()
        harness.removalHub.scriptRequest(.success(RemovalFixtures.removal(.completed)))
        removals.requestRemoval(of: F.base)
        try await waitUntil { self.harness.removalHub.heldCount == 1 }

        // The app turns to hub B, which lists the same Base (registered there). Its sheet is opened.
        let hubB = FakeSettingsHub(hubID: String(repeating: "b", count: 32))
        let onB = F.enrolled(removals: [])
        let transportB = ControllableSensorAPITransport { onB }
        harness.model.replace(dataSource: harness.liveSource(transportB), identity: .hub(id: hubB.hubID), address: URL(string: "http://192.168.1.11:8787"))
        try await waitUntil { self.harness.model.snapshot.modules.count == 2 }
        try await waitUntil { removals.action(for: F.base) == nil }
        actions.managingPowerBase = PowerBaseManagementTarget(identifier: F.base)
        try await waitUntil(timeout: 5) { hosted.isPresenting }

        // Hub A's answer arrives now, and says "completed".
        harness.removalHub.release()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(removals.completionEvents.isEmpty, "the previous hub's answer is no event here")
        XCTAssertEqual(removals.notices, PowerBaseRemovalNotices())
        XCTAssertEqual(announced, [])
        XCTAssertEqual(actions.managingPowerBase?.identifier, F.base, "the sheet on the new hub is still open")
        XCTAssertNil(removals.removal(for: F.base, in: harness.model.snapshot), "and nothing of that job is shown")
    }

    func testANoticeTakenInOnOneHubIsNotShownAfterTheAppTurnedToAnother() async throws {
        // The completion is taken in while a sheet covers the tab; before it is shown, the hub changes.
        try await harness.startApp(first: twoBases([F.removal("accepted")]))
        let actions = DeviceActions()
        let hosted = try await showTheDevicesTab(actions: actions, noticeDuration: .milliseconds(400))
        actions.managingPowerBase = PowerBaseManagementTarget(identifier: F.otherBase)
        try await waitUntil(timeout: 5) { hosted.isPresenting }
        try await harness.deliver(F.snapshot(bases: [F.base(F.otherBase, moduleCount: 1)], modules: [F.module(F.otherSensor, base: F.otherBase)], removals: [F.removal("completed")]))
        try await waitUntil { self.harness.removals.notices.waiting.count == 1 }

        let hubB = FakeSettingsHub(hubID: String(repeating: "b", count: 32))
        let onB = F.enrolled(removals: [])
        let transportB = ControllableSensorAPITransport { onB }
        harness.model.replace(dataSource: harness.liveSource(transportB), identity: .hub(id: hubB.hubID), address: URL(string: "http://192.168.1.11:8787"))
        try await waitUntil { self.harness.model.snapshot.modules.count == 2 }
        try await waitUntil { self.harness.removals.notices == PowerBaseRemovalNotices() }
        actions.managingPowerBase = nil
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(announced, [], "what the previous hub completed is not announced on this one")
        XCTAssertTrue(harness.removals.completionEvents.isEmpty)
    }

    func testAnAnswerThatArrivesAfterTheSheetWasClosedOnlyShowsItsNoticeOnTheTab() async throws {
        try await harness.startApp(first: twoBases([]))
        let actions = DeviceActions()
        let hosted = try await showTheDevicesTab(actions: actions, noticeDuration: .seconds(2))
        let removals = harness.removals!
        actions.managingPowerBase = PowerBaseManagementTarget(identifier: F.base)
        try await waitUntil(timeout: 5) { hosted.isPresenting }
        harness.removalHub.hold()
        harness.removalHub.scriptRequest(.success(RemovalFixtures.removal(.completed)))
        removals.requestRemoval(of: F.base)
        try await waitUntil { self.harness.removalHub.heldCount == 1 }

        // The user closes the sheet and opens the other Base's instead; then the answer arrives.
        actions.managingPowerBase = nil
        try await waitUntil(timeout: 5) { !hosted.isPresenting }
        actions.managingPowerBase = PowerBaseManagementTarget(identifier: F.otherBase)
        try await waitUntil(timeout: 5) { hosted.isPresenting }
        harness.removalHub.release()
        try await waitUntil { removals.completionEvents.count == 1 }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(actions.managingPowerBase?.identifier, F.otherBase, "the sheet that is open now is another Base's and stays")
        XCTAssertEqual(announced, [], "and the notice waits behind it")
        actions.managingPowerBase = nil
        try await waitUntil(timeout: 5) { self.announced == [self.notice()] }
    }

    // MARK: The notice itself

    func testTheNoticeNamesEveryBaseAsOneElementAndGoesAwayByItself() async throws {
        let completions = [F.base, F.otherBase].map { Completion(id: "9f0c1d2e3f405162" + $0, powerBaseIdentifier: $0) }
        var dismissed = 0
        let hosted = try HostedScreen(PowerBaseRemovalCompletionNotice(completions: completions, duration: .milliseconds(600)) { dismissed += 1 })
        screen = hosted
        let labels = try await hosted.labels()
        XCTAssertTrue(notice().contains("b3c4"), notice())
        XCTAssertTrue(notice().localizedCaseInsensitiveContains(PowerBaseManagementText.removalTitle(.completed)), "the notice uses the word that means removed: \(notice())")
        XCTAssertEqual(labels.filter { $0.contains(notice(F.base)) && $0.contains(notice(F.otherBase)) }.count, 1, "read once, as one element: \(labels)")
        try await waitUntil(timeout: 5) { dismissed == 1 }
    }
}

// MARK: - Helpers

extension ReenrollHarness {
    /// What `DevicesView` hands the controller for the first snapshot and for every change.
    func report() {
        removals.sourceDidReport(model.snapshot.powerBaseRemovals, from: model.sourceIdentity)
    }

    func startAppAndReport(first: Data, store: InMemoryHomeConfigurationStore = InMemoryHomeConfigurationStore(language: .korean)) async throws {
        try await startApp(first: first, store: store)
        report()
    }

    /// The hub's next snapshot, and the Devices tab's report of it.
    func receive(_ json: Data) async throws {
        try await deliver(json)
        report()
    }
}

/// A real SwiftUI screen in a window of the test host, kept while a test changes what it shows.
@MainActor
final class HostedScreen {
    let window: UIWindow

    init<V: View>(_ view: V, size: CGSize = CGSize(width: 390, height: 844)) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        // SwiftUI builds its accessibility tree only once something asks for accessibility (see
        // `SheetIconRowLayoutTests`).
        typealias SetAutomationEnabled = @convention(c) (Int32) -> Void
        if let library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let symbol = dlsym(library, "_AXSSetAutomationEnabled") {
            unsafeBitCast(symbol, to: SetAutomationEnabled.self)(1)
        }
    }

    /// A sheet (or anything else) is presented over the screen.
    var isPresenting: Bool { window.rootViewController?.presentedViewController != nil }

    /// What VoiceOver reads now, on the screen and on whatever is presented over it.
    func labels() async throws -> [String] {
        try await Task.sleep(for: .milliseconds(350))
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        var labels: [String] = []
        func collect(_ object: Any) {
            guard let element = object as? NSObject else { return }
            if element.isAccessibilityElement, let label = element.accessibilityLabel, !label.isEmpty { labels.append(label) }
            if let children = element.accessibilityElements { children.forEach(collect) }
            if !element.isAccessibilityElement, let view = element as? UIView { view.subviews.forEach(collect) }
        }
        collect(window)
        try XCTSkipIf(labels.isEmpty, "this test host exposes no accessibility tree (not verified here)")
        return labels
    }

    func close() {
        window.rootViewController?.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
    }
}
