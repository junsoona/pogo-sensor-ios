#if DEBUG
import PowerBaseBLEKit
import SwiftUI
import XCTest
@testable import PogoHome

// Follow-up rules of "삭제 확인", each against the real controller with a scripted board, radio and
// hub (no Bluetooth, no network):
//
//   - the screen can be reached for a job whose "released" notice never got to the hub, and
//     reaching it completes nothing;
//   - a run that is over starts no request, however late its queued task runs, and the late
//     answer of a request that had already left changes nothing on the screen;
//   - nothing new starts in the background: the connect, each message of the opening, the board's
//     status, the receipt request, the request to the hub and "send again".
//
// Waiting is by what happened, not by time: `foregroundWaiters` says that a step is waiting for
// the foreground right now, `unfinishedRunTasks` that every task of a run has come to its end, and
// where "nothing more is sent" has to hold for good, a later run that sends exactly once is the
// event everything stale would have had to come before.

// MARK: - Reaching "삭제 확인"

/// Where the management sheet offers "삭제 확인", and that offering it changes nothing else.
@MainActor
final class PowerBaseEraseConfirmationEntryTests: XCTestCase {
    typealias P = PowerBaseManagementPresentation

    private let eui = EnrollmentFixtures.eui64

    private func job(_ state: PowerBaseRemoval.State, resultUnknown: Bool = false, cancellable: Bool? = nil) -> PowerBaseRemoval {
        PowerBaseRemoval(
            id: RemovalFixtures.removalID, powerBaseIdentifier: eui, state: state, resultUnknown: resultUnknown,
            cancellable: cancellable ?? (state == .pending), affectedModuleCount: 2,
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), updatedAt: Date(timeIntervalSince1970: 1_790_000_100)
        )
    }

    func testItIsOfferedForAReleasedJobAndForOneWhoseResultNeverArrived() {
        XCTAssertTrue(job(.released).offersEraseConfirmation)
        XCTAssertTrue(job(.sent, resultUnknown: true).offersEraseConfirmation, "the notice may be what was lost: the board may hold a receipt")
        XCTAssertTrue(job(.accepted, resultUnknown: true).offersEraseConfirmation)

        XCTAssertFalse(job(.pending).offersEraseConfirmation, "the board was never given the command")
        XCTAssertFalse(job(.sent).offersEraseConfirmation, "still within the hub's time for an answer")
        XCTAssertFalse(job(.accepted).offersEraseConfirmation)
        for final in [PowerBaseRemoval.State.completed, .cancelled, .superseded] {
            XCTAssertFalse(job(final).offersEraseConfirmation, "\(final)")
            XCTAssertFalse(job(final, resultUnknown: true).offersEraseConfirmation, "\(final)")
        }
    }

    func testTheSheetsButtonsFollowThatAndOnlyTheHubsWordForCancelling() {
        XCTAssertEqual(P.removalActions(for: job(.released), isActing: false), [.confirmErase])
        XCTAssertEqual(P.removalActions(for: job(.sent, resultUnknown: true), isActing: false), [.confirmErase],
                       "the job the reviewer could not get out of: there is a way to the receipt now")
        XCTAssertEqual(P.removalActions(for: job(.accepted, resultUnknown: true), isActing: false), [.confirmErase])
        XCTAssertEqual(P.removalActions(for: job(.accepted, resultUnknown: true), isActing: true), [.confirmErase],
                       "reading a receipt does not depend on this sheet's own request")

        XCTAssertEqual(P.removalActions(for: job(.pending), isActing: false), [.cancel], "a waiting job can be cancelled, as before, and nothing else")
        XCTAssertEqual(P.removalActions(for: job(.pending), isActing: true), [])
        XCTAssertEqual(P.removalActions(for: job(.sent), isActing: false), [])
        XCTAssertEqual(P.removalActions(for: job(.accepted), isActing: false), [])
        for final in [PowerBaseRemoval.State.completed, .cancelled, .superseded] {
            XCTAssertEqual(P.removalActions(for: job(final), isActing: false), [], "\(final)")
        }
        // Whether a job can be cancelled is the hub's flag, not a guess from its state.
        XCTAssertEqual(P.removalActions(for: job(.sent, resultUnknown: true, cancellable: true), isActing: false), [.confirmErase, .cancel])
        XCTAssertEqual(P.removalActions(for: job(.pending, cancellable: false), isActing: false), [])
    }

    func testOfferingItChangesNeitherWhatAJobIsShownAsNorWhatCountsAsDone() {
        let unknown = job(.accepted, resultUnknown: true)
        XCTAssertEqual(unknown.presentation, .resultUnknown, "still 'result unknown', not 'released'")
        XCTAssertEqual(job(.sent, resultUnknown: true).presentation, .resultUnknown)
        XCTAssertEqual(job(.released).presentation, .awaitingEraseConfirmation)
        XCTAssertEqual(job(.pending).presentation, .waitingForPowerBase)
        XCTAssertEqual(job(.completed).presentation, .completed)
        XCTAssertEqual(job(.cancelled).presentation, .cancelled)
        XCTAssertEqual(job(.superseded).presentation, .superseded)
        XCTAssertEqual(P.badge(for: unknown), .resultUnknown)
        XCTAssertFalse(unknown.state.isFinal)
        XCTAssertFalse(unknown.cancellable)

        let done = PowerBaseManagementText.removalTitle(.completed)
        XCTAssertNotEqual(PowerBaseManagementText.removalTitle(unknown.presentation), done)
        XCTAssertNotEqual(PowerBaseManagementText.removalTitle(job(.released).presentation), done)
    }

    func testTheScreenExplainsWhichOfTheTwoItWasOpenedFor() {
        XCTAssertEqual(PowerBaseReleaseConfirmationOrigin(job(.released)), .released)
        XCTAssertEqual(PowerBaseReleaseConfirmationOrigin(job(.sent, resultUnknown: true)), .resultUnknown)
        XCTAssertEqual(PowerBaseReleaseConfirmationOrigin(job(.accepted, resultUnknown: true)), .resultUnknown)
        let released = PowerBaseReleaseConfirmationText.intro(.released)
        let unknown = PowerBaseReleaseConfirmationText.intro(.resultUnknown)
        XCTAssertFalse(released.isEmpty || unknown.isEmpty)
        XCTAssertNotEqual(released, unknown, "a job the hub never heard back about is not described as released")
        XCTAssertFalse(PowerBaseManagementText.confirmEraseWhenUnknown.isEmpty)
    }
}

// MARK: - The controller, with a scripted provider

@MainActor
final class PowerBaseReleaseConfirmationFollowUpTests: XCTestCase {
    typealias Controller = PowerBaseReleaseConfirmationController
    typealias P = PowerBaseManagementPresentation

    private var log: EnrollmentEventLog!
    private var hub: FakeRemovalHub!
    private var board: FakeBoard!
    private var provider: FakeBLEBoardProvider!
    private var credentials: InMemoryHubCredentialStore!
    private let eui = EnrollmentFixtures.eui64
    private let receipt = EnrollmentFixtures.releaseReceipt()

    override func setUp() async throws {
        credentials = InMemoryHubCredentialStore([
            EnrollmentFixtures.credential(hubID: EnrollmentFixtures.hubA, token: "token-A"),
            EnrollmentFixtures.credential(hubID: EnrollmentFixtures.hubB, token: "token-B", certificate: String(repeating: "d", count: 64)),
        ])
        log = EnrollmentEventLog()
        fresh()
    }

    private func fresh() {
        log.clear()
        hub = FakeRemovalHub()
        board = FakeBoard(log: log)
        board.set(capabilities: [.bridgeEndpointV1, .managementV1, .releaseReceiptV1])
        board.set(receipt: receipt)
        provider = FakeBLEBoardProvider(board: board, log: log)
    }

    private func makeController() -> Controller {
        let controller = Controller(powerBaseIdentifier: eui, provider: provider, transport: hub, credentials: credentials, quietScanPeriod: .milliseconds(30))
        controller.targetDidChange(EnrollmentFixtures.pairedTarget())
        controller.activate()
        controller.startScanning()
        return controller
    }

    private func completed() -> PowerBaseRemoval { RemovalFixtures.removal(.completed, base: eui) }

    private func confirm(_ controller: Controller) {
        controller.confirm(boardID: FakeBLEBoardProvider.boardID, setupCode: EnrollmentFixtures.setupCode)
    }

    private func failure(_ controller: Controller) -> Controller.Failure? {
        if case let .failed(failure) = controller.phase { return failure }
        return nil
    }

    private var hubBTarget: PowerBaseHubTarget { EnrollmentFixtures.pairedTarget(hubID: EnrollmentFixtures.hubB, url: EnrollmentFixtures.urlB) }

    /// How a run ends without having finished.
    private enum Ending: CaseIterable {
        case leave, anotherHub, hubNoLongerPaired

        @MainActor
        func apply(to controller: Controller, otherHub: PowerBaseHubTarget) {
            switch self {
            case .leave: controller.leave()
            case .anotherHub: controller.targetDidChange(otherHub)
            case .hubNoLongerPaired:
                controller.targetDidChange(PowerBaseHubTarget(hubID: EnrollmentFixtures.hubA, baseURL: EnrollmentFixtures.urlA, isSimulated: false, isPaired: false))
            }
        }
    }

    /// A run that read the receipt and could not reach the hub: "send again" is offered.
    private func aControllerWithAnUndeliveredReceipt() async throws -> Controller {
        hub.scriptReceipt(.failure(.unreachable("timeout")))
        let controller = makeController()
        confirm(controller)
        try await eventually { !controller.isBusy }
        XCTAssertEqual(failure(controller), .hub(.unreachable("timeout")))
        XCTAssertTrue(controller.canSendAgain)
        XCTAssertEqual(hub.receipts.count, 1)
        try await eventually { controller.unfinishedRunTasks == 0 }
        return controller
    }

    // MARK: A job without a result

    func testAJobWhoseNoticeWasLostIsConfirmedThroughTheSameScreenAndIsDoneOnlyWhenTheHubSaysSo() async throws {
        let job = RemovalFixtures.removal(.accepted, base: eui, resultUnknown: true)
        XCTAssertEqual(P.removalActions(for: job, isActing: false), [.confirmErase], "the sheet offers the way in")

        hub.hold()
        hub.scriptReceipt(.success(completed()))
        let controller = makeController()
        confirm(controller)
        try await eventually { self.hub.heldCount == 1 }
        // The receipt is with the hub and the hub has not answered.
        XCTAssertEqual(controller.phase, .sendingToHub, "read and handed in, not confirmed")
        XCTAssertEqual(job.presentation, .resultUnknown, "and the job is what the hub last said it is")
        XCTAssertEqual(log.all, ["board open", "board status", "board receipt"], "the authenticated board was only read")
        XCTAssertTrue(board.starts.isEmpty && board.cancels.isEmpty && board.joinerStarts == 0, "no enrollment, no Joiner, no cancel on the board")
        XCTAssertEqual(hub.recorded, [.receipt(hubID: EnrollmentFixtures.hubA, token: "token-A", pin: String(repeating: "c", count: 64), receiptHex: receipt.hex)],
                       "the hub got the receipt and nothing else: no new removal request")

        hub.release()
        try await eventually { !controller.isBusy }
        XCTAssertEqual(controller.phase, .confirmed(completed()), "the hub's `completed` is what completes it")
    }

    func testWithoutAReceiptOrWithoutTheHubsCompletedSuchAJobStaysWhatItWas() async throws {
        // The board never got the command, or has not finished: it has no receipt.
        board.set(receipt: nil)
        var controller = makeController()
        confirm(controller)
        try await eventually { !controller.isBusy }
        XCTAssertEqual(failure(controller), .noReceipt)
        XCTAssertTrue(hub.recorded.isEmpty, "nothing is handed to the hub without a receipt")

        // The hub rejects what was read.
        fresh()
        hub.scriptReceipt(.failure(.receiptRejected))
        controller = makeController()
        confirm(controller)
        try await eventually { !controller.isBusy }
        XCTAssertEqual(failure(controller), .hub(.receiptRejected))
        XCTAssertFalse(controller.canSendAgain)

        // The hub answers with a job that is not complete.
        fresh()
        hub.scriptReceipt(.success(RemovalFixtures.removal(.accepted, base: eui, resultUnknown: true)))
        controller = makeController()
        confirm(controller)
        try await eventually { !controller.isBusy }
        guard case .hub(.badResponse)? = failure(controller) else { return XCTFail("\(controller.phase)") }
    }

    // MARK: A run that is over starts no request

    func testSendAgainAndThenTheEndOfTheRunInTheSameTurnStartsNoRequest() async throws {
        for ending in Ending.allCases {
            fresh()
            let controller = try await aControllerWithAnUndeliveredReceipt()
            // What a request of the ended run would be answered with, if one were made.
            hub.scriptReceipt(.success(completed()))

            // No suspension between the two: the task `sendAgain()` queued cannot have run yet.
            controller.sendAgain()
            ending.apply(to: controller, otherHub: hubBTarget)

            XCTAssertEqual(controller.phase, .idle, "\(ending)")
            try await eventually { controller.unfinishedRunTasks == 0 }
            XCTAssertEqual(hub.receipts.count, 1, "\(ending): the queued task found its run over and sent nothing")
            XCTAssertEqual(controller.phase, .idle, "\(ending)")
            XCTAssertEqual(controller.foregroundWaiters, 0, "\(ending)")
        }
    }

    func testARunThatReplacesTheEndedOneSendsOnceItself() async throws {
        let controller = try await aControllerWithAnUndeliveredReceipt()
        hub.scriptReceipt(.success(completed()))

        controller.sendAgain()
        controller.leave()
        // The screen is opened again and the board is read again: a new run.
        controller.activate()
        controller.startScanning()
        confirm(controller)
        try await eventually { !controller.isBusy }

        XCTAssertEqual(controller.phase, .confirmed(completed()), "the new run got the hub's answer -- the ended one did not use it up")
        XCTAssertEqual(hub.receipts.count, 2, "the first delivery, and the new run's: nothing of the ended run in between")
        XCTAssertEqual(provider.opens.count, 2)
        try await eventually { controller.unfinishedRunTasks == 0 }
    }

    func testTheLateAnswerOfARequestThatHadLeftIsNotShownAfterTheRunEnded() async throws {
        for ending in Ending.allCases {
            for answer in [Result<PowerBaseRemoval, PowerBaseRemovalError>.success(completed()), .failure(.receiptRejected)] {
                let context = "\(ending), \(answer)"
                fresh()
                hub.hold()
                hub.scriptReceipt(answer)
                let controller = makeController()
                confirm(controller)
                try await eventually { self.hub.heldCount == 1 }
                XCTAssertEqual(controller.phase, .sendingToHub, context)

                ending.apply(to: controller, otherHub: hubBTarget)
                XCTAssertEqual(controller.phase, .idle, context)
                XCTAssertEqual(controller.unfinishedRunTasks, 1, "\(context): the request that left is not taken back; it is still waited for")

                hub.release()
                try await eventually { controller.unfinishedRunTasks == 0 }
                XCTAssertEqual(controller.phase, .idle, "\(context): the answer arrived and changed nothing")
                XCTAssertEqual(hub.receipts.count, 1, context)
                XCTAssertEqual(hub.heldCount, 0, "\(context): the request ran to its end -- the hub may well have handled it")
                if ending != .leave { XCTAssertFalse(controller.canSendAgain, context) }
            }
        }
    }

    func testTheLateAnswerOfAnEndedRunDoesNotReplaceWhatANewRunShows() async throws {
        hub.hold()
        hub.scriptReceipt(.success(completed()))
        let controller = makeController()
        confirm(controller)
        try await eventually { self.hub.heldCount == 1 }
        controller.leave()

        // The screen again, and a new run that is reading the board when the old answer arrives.
        board.holdPlainStatus()
        controller.activate()
        controller.startScanning()
        confirm(controller)
        try await eventually { controller.phase == .reading && self.board.heldPlainStatusRequests == 1 }
        XCTAssertEqual(controller.unfinishedRunTasks, 2)

        hub.release()
        try await eventually { controller.unfinishedRunTasks == 1 }
        XCTAssertEqual(controller.phase, .reading, "the old run's `completed` is not this run's result")
        XCTAssertEqual(hub.receipts.count, 1)

        // The new run goes on by itself and gets its own answer.
        hub.scriptReceipt(.failure(.unreachable("timeout")))
        board.releasePlainStatus()
        try await eventually { !controller.isBusy }
        XCTAssertEqual(failure(controller), .hub(.unreachable("timeout")))
        XCTAssertEqual(hub.receipts.count, 2)
    }

    func testTheSameHubAtAnotherAddressKeepsTheRunAndIsAskedThere() async throws {
        board.holdPlainStatus()
        hub.scriptReceipt(.success(completed()))
        let controller = makeController()
        confirm(controller)
        try await eventually { self.board.heldPlainStatusRequests == 1 }
        controller.targetDidChange(EnrollmentFixtures.pairedTarget(hubID: EnrollmentFixtures.hubA, url: EnrollmentFixtures.urlB))
        XCTAssertEqual(controller.phase, .reading, "the same hub: the same credential and the same pinned certificate")
        board.releasePlainStatus()
        try await eventually { !controller.isBusy }
        XCTAssertEqual(controller.phase, .confirmed(completed()))
        XCTAssertEqual(hub.receipts.count, 1)
    }

    // MARK: Nothing new in the background

    func testEveryMessageOfTheOpeningWaitsForTheForeground() async throws {
        for step in FakeBLEBoardProvider.OpenStep.allCases {
            fresh()
            hub.scriptReceipt(.success(completed()))
            provider.holdsOpensAfter = step
            let controller = makeController()
            confirm(controller)
            try await eventually { self.provider.heldCount == 1 }
            let sent = provider.sentSteps

            // The answer to `step` is under way when the app goes away; then it arrives.
            controller.sceneDidEnterBackground()
            provider.releaseHeld()
            try await eventually { controller.foregroundWaiters == 1 }
            XCTAssertEqual(provider.sentSteps, sent, "\(step): what follows it was not sent")
            XCTAssertEqual(board.statusCalls, 0, "\(step)")
            XCTAssertTrue(hub.recorded.isEmpty, "\(step)")
            XCTAssertEqual(controller.phase, step == .handshake1 ? .reading : .connecting, "\(step): the run is kept")

            controller.sceneDidBecomeActive()
            try await eventually { !controller.isBusy }
            XCTAssertEqual(controller.phase, .confirmed(completed()), "\(step)")
            XCTAssertEqual(provider.sentSteps, FakeBLEBoardProvider.OpenStep.allCases, "\(step): the same opening went on; nothing was sent twice")
            XCTAssertEqual(provider.opens.count, 1, "\(step)")
            XCTAssertEqual(board.statusCalls, 1, "\(step)")
            XCTAssertEqual(board.receiptCalls, 1, "\(step)")
            XCTAssertEqual(hub.receipts.count, 1, "\(step)")
            XCTAssertEqual(controller.foregroundWaiters, 0, "\(step)")
        }
    }

    func testAConnectAskedForInTheBackgroundIsNotStarted() async throws {
        hub.scriptReceipt(.success(completed()))
        let controller = makeController()
        controller.sceneDidEnterBackground()
        confirm(controller)
        try await eventually { controller.foregroundWaiters == 1 }
        XCTAssertEqual(provider.sentSteps, [], "not even the connect")
        XCTAssertEqual(controller.phase, .connecting)
        controller.sceneDidBecomeActive()
        try await eventually { !controller.isBusy }
        XCTAssertEqual(controller.phase, .confirmed(completed()))
        XCTAssertEqual(provider.sentSteps, FakeBLEBoardProvider.OpenStep.allCases)
    }

    func testTheReceiptRequestWaitsWhenTheBoardsStatusArrivesInTheBackground() async throws {
        hub.scriptReceipt(.success(completed()))
        board.holdPlainStatus()
        let controller = makeController()
        confirm(controller)
        try await eventually { self.board.heldPlainStatusRequests == 1 }

        controller.sceneDidEnterBackground()
        board.releasePlainStatus()
        try await eventually { controller.foregroundWaiters == 1 }
        XCTAssertEqual(log.all, ["board open", "board status"], "the status was answered; the receipt was not asked for")
        XCTAssertEqual(board.receiptCalls, 0)
        XCTAssertEqual(controller.phase, .reading)
        XCTAssertTrue(board.closed.isEmpty, "the session is kept for when the app is back")

        controller.sceneDidBecomeActive()
        try await eventually { !controller.isBusy }
        XCTAssertEqual(controller.phase, .confirmed(completed()))
        XCTAssertEqual(log.all, ["board open", "board status", "board receipt"])
        XCTAssertEqual(hub.receipts.count, 1)
    }

    func testTheRequestToTheHubWaitsWhenTheReceiptArrivesInTheBackgroundButTheConnectionIsClosedAtOnce() async throws {
        hub.scriptReceipt(.success(completed()))
        board.holdReceipt()
        let controller = makeController()
        confirm(controller)
        try await eventually { self.board.heldReceiptRequests == 1 }

        controller.sceneDidEnterBackground()
        board.releaseHeldReceipt()
        try await eventually { controller.foregroundWaiters == 1 }
        XCTAssertTrue(hub.recorded.isEmpty, "the receipt was read; nothing went to the hub in the background")
        XCTAssertEqual(controller.phase, .sendingToHub)
        XCTAssertEqual(board.closed, [1], "ending the connection did not wait for the foreground")

        controller.sceneDidBecomeActive()
        try await eventually { !controller.isBusy }
        XCTAssertEqual(controller.phase, .confirmed(completed()))
        XCTAssertEqual(hub.receipts, [.receipt(hubID: EnrollmentFixtures.hubA, token: "token-A", pin: String(repeating: "c", count: 64), receiptHex: receipt.hex)])
        XCTAssertEqual(board.receiptCalls, 1, "the receipt was not read a second time")
    }

    func testSendAgainWaitsForTheForeground() async throws {
        let controller = try await aControllerWithAnUndeliveredReceipt()
        hub.scriptReceipt(.success(completed()))

        controller.sceneDidEnterBackground()
        controller.sendAgain()
        try await eventually { controller.foregroundWaiters == 1 }
        XCTAssertEqual(hub.receipts.count, 1, "no request in the background")
        XCTAssertEqual(controller.phase, .sendingToHub)

        controller.sceneDidBecomeActive()
        try await eventually { !controller.isBusy }
        XCTAssertEqual(controller.phase, .confirmed(completed()))
        XCTAssertEqual(hub.receipts.count, 2)
        XCTAssertEqual(provider.opens.count, 1, "no Bluetooth for it")
    }

    func testAnAnswerThatWasUnderWayIsTakenInTheBackground() async throws {
        hub.hold()
        hub.scriptReceipt(.success(completed()))
        let controller = makeController()
        confirm(controller)
        try await eventually { self.hub.heldCount == 1 }
        controller.sceneDidEnterBackground()
        hub.release()
        try await eventually { !controller.isBusy }
        XCTAssertEqual(controller.phase, .confirmed(completed()), "the request had left before the app went away")
        XCTAssertTrue(controller.isSuspended)
        XCTAssertEqual(controller.foregroundWaiters, 0)
    }

    /// Where a run can be waiting for the foreground.
    private enum WaitPoint: CaseIterable {
        case connect, handshake, status, receiptRequest, hubRequest, sendAgain
    }

    /// Brings a run to `point`, waiting there for the foreground.
    private func aRunWaiting(at point: WaitPoint) async throws -> Controller {
        let controller: Controller
        switch point {
        case .connect:
            controller = makeController()
            controller.sceneDidEnterBackground()
            confirm(controller)
        case .handshake:
            provider.holdsOpensAfter = .version
            controller = makeController()
            confirm(controller)
            try await eventually { self.provider.heldCount == 1 }
            controller.sceneDidEnterBackground()
            provider.releaseHeld()
        case .status:
            provider.holdsOpens = true
            controller = makeController()
            confirm(controller)
            try await eventually { self.provider.heldCount == 1 }
            controller.sceneDidEnterBackground()
            provider.releaseHeld()
        case .receiptRequest:
            board.holdPlainStatus()
            controller = makeController()
            confirm(controller)
            try await eventually { self.board.heldPlainStatusRequests == 1 }
            controller.sceneDidEnterBackground()
            board.releasePlainStatus()
        case .hubRequest:
            board.holdReceipt()
            controller = makeController()
            confirm(controller)
            try await eventually { self.board.heldReceiptRequests == 1 }
            controller.sceneDidEnterBackground()
            board.releaseHeldReceipt()
        case .sendAgain:
            controller = try await aControllerWithAnUndeliveredReceipt()
            controller.sceneDidEnterBackground()
            controller.sendAgain()
        }
        try await eventually { controller.foregroundWaiters == 1 }
        return controller
    }

    func testARunThatEndsWhileItWaitsForTheForegroundLeavesNothingWaitingAndGoesNowhereWhenTheAppIsBack() async throws {
        for point in WaitPoint.allCases {
            for ending in Ending.allCases {
                let context = "\(point), \(ending)"
                fresh()
                let controller = try await aRunWaiting(at: point)
                let steps = provider.sentSteps
                let statusCalls = board.statusCalls
                let receiptCalls = board.receiptCalls
                let requests = hub.recorded.count
                let sessions = board.openedSessions

                ending.apply(to: controller, otherHub: hubBTarget)
                XCTAssertEqual(controller.foregroundWaiters, 0, "\(context): everything that waited was woken when the run ended")
                XCTAssertEqual(controller.phase, .idle, context)
                try await eventually { controller.unfinishedRunTasks == 0 }
                // The connection, if there was one and it was still open, is ended without the foreground.
                let expectedClosed = sessions == 0 ? [] : [1]
                try await eventually { self.board.closed == expectedClosed }

                controller.sceneDidBecomeActive()
                XCTAssertEqual(controller.foregroundWaiters, 0, context)
                XCTAssertEqual(controller.unfinishedRunTasks, 0, "\(context): nothing is left that could go on")
                XCTAssertEqual(provider.sentSteps, steps, "\(context): no Bluetooth message after the end")
                XCTAssertEqual(board.statusCalls, statusCalls, context)
                XCTAssertEqual(board.receiptCalls, receiptCalls, context)
                XCTAssertEqual(hub.recorded.count, requests, "\(context): no request to the hub after the end")
                XCTAssertEqual(controller.phase, .idle, context)
                XCTAssertFalse(controller.isBusy, context)
            }
        }
    }

    // MARK: The scene

    func testTheScenePhaseIsReadLikeTheRegistrationScreenReadsIt() {
        let controller = makeController()
        PowerBaseReleaseConfirmationScene.apply(.inactive, to: controller)
        XCTAssertFalse(controller.isSuspended, "the app switcher or a system alert holds nothing back")
        PowerBaseReleaseConfirmationScene.apply(.background, to: controller)
        XCTAssertTrue(controller.isSuspended)
        PowerBaseReleaseConfirmationScene.apply(.inactive, to: controller)
        XCTAssertTrue(controller.isSuspended, "on the way back: not yet")
        PowerBaseReleaseConfirmationScene.apply(.active, to: controller)
        XCTAssertFalse(controller.isSuspended)
        PowerBaseReleaseConfirmationScene.apply(.background, to: nil)
    }

    /// The real screen, hosted with a scene phase the test sets: it hands the phase it appears in
    /// and every later change to its controller, and leaving it ends the run.
    func testTheScreenHandsItsScenePhaseToTheController() async throws {
        hub.scriptReceipt(.success(completed()))
        let controller = makeController()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let phase = ScenePhaseBox(.background)
        let model = AppModel(dataSource: MockSensorDataSource())
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = UIHostingController(rootView: HostedConfirmation(phase: phase, makeController: { controller }).environment(model))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        try await eventually { controller.isSuspended }
        // The screen gave the controller the source the app reads (not a paired hub here); the
        // run below is about the scene, so it is given the paired one again.
        controller.targetDidChange(EnrollmentFixtures.pairedTarget())
        confirm(controller)
        try await eventually { controller.foregroundWaiters == 1 }
        XCTAssertEqual(provider.sentSteps, [], "the screen appeared in the background: nothing is connected")

        phase.value = .inactive
        phase.value = .active
        try await eventually { !controller.isSuspended }
        try await eventually { !controller.isBusy }
        XCTAssertEqual(provider.sentSteps, FakeBLEBoardProvider.OpenStep.allCases, "back in the foreground the run went on")

        phase.value = .background
        try await eventually { controller.isSuspended }
    }
}

@MainActor
@Observable
private final class ScenePhaseBox {
    var value: ScenePhase
    init(_ value: ScenePhase) { self.value = value }
}

private struct HostedConfirmation: View {
    let phase: ScenePhaseBox
    let makeController: () -> PowerBaseReleaseConfirmationController

    var body: some View {
        NavigationStack {
            PowerBaseReleaseConfirmationView(powerBaseIdentifier: EnrollmentFixtures.eui64, makeController: makeController)
        }
        .environment(\.scenePhase, phase.value)
    }
}

// MARK: - The controller on the real connection lifecycle

/// The confirmation run's permits at the moment a connection is really started: the controller and
/// `PowerBaseEnrollmentBLELifecycle` are the real ones, the radio is scripted
/// (`LifecycleBLEBoardProvider`). A connect that had to wait for the end of the previous connection
/// is decided when that wait is over.
@MainActor
final class PowerBaseReleaseConfirmationConnectPermitTests: XCTestCase {
    typealias Controller = PowerBaseReleaseConfirmationController

    private var log: EnrollmentEventLog!
    private var hub: FakeRemovalHub!
    private var board: FakeBoard!
    private var provider: LifecycleBLEBoardProvider!
    private var credentials: InMemoryHubCredentialStore!
    private let eui = EnrollmentFixtures.eui64

    override func setUp() async throws {
        credentials = InMemoryHubCredentialStore([
            EnrollmentFixtures.credential(hubID: EnrollmentFixtures.hubA, token: "token-A"),
            EnrollmentFixtures.credential(hubID: EnrollmentFixtures.hubB, token: "token-B", certificate: String(repeating: "d", count: 64)),
        ])
        log = EnrollmentEventLog()
        fresh()
    }

    private func fresh() {
        log.clear()
        hub = FakeRemovalHub()
        board = FakeBoard(log: log)
        board.set(capabilities: [.bridgeEndpointV1, .managementV1, .releaseReceiptV1])
        board.set(receipt: EnrollmentFixtures.releaseReceipt())
        provider = LifecycleBLEBoardProvider(board: board, log: log)
    }

    private func makeController() -> Controller {
        let controller = Controller(powerBaseIdentifier: eui, provider: provider, transport: hub, credentials: credentials, quietScanPeriod: .milliseconds(30))
        controller.targetDidChange(EnrollmentFixtures.pairedTarget())
        controller.activate()
        controller.startScanning()
        return controller
    }

    private func completed() -> PowerBaseRemoval { RemovalFixtures.removal(.completed, base: eui) }

    private func confirm(_ controller: Controller) {
        controller.confirm(boardID: LifecycleBLEBoardProvider.boardID, setupCode: EnrollmentFixtures.setupCode)
    }

    private func failure(_ controller: Controller) -> Controller.Failure? {
        if case let .failed(failure) = controller.phase { return failure }
        return nil
    }

    /// A first run ended (another board answered) and the end of its connection is not reported
    /// yet. A second run is started: its opening waits for that end and has connected nothing.
    private func startARunThatWaitsForTheEndOfThePreviousConnection(_ controller: Controller) async throws {
        provider.reportsEnds = false
        board.report(eui64: "00124b0001a2b3c5")
        confirm(controller)
        try await eventually { self.failure(controller) == .differentBoard }
        try await eventually { self.provider.cancels == 1 }
        XCTAssertEqual(provider.connects, 1)
        XCTAssertTrue(hub.recorded.isEmpty)

        board.report(eui64: eui)
        controller.acknowledgeResult()
        confirm(controller)
        // The opening runs up to the lifecycle's wait in one turn: once it was asked for, it waits.
        try await eventually { self.provider.opens == 2 }
        XCTAssertEqual(controller.phase, .connecting)
        XCTAssertEqual(provider.connects, 1, "the new connection waits for the end of the previous one")
    }

    func testAConnectWhosePreviousConnectionEndsWhileTheAppIsAwayConnectsOnceWhenItIsBack() async throws {
        hub.scriptReceipt(.success(completed()))
        let controller = makeController()
        try await startARunThatWaitsForTheEndOfThePreviousConnection(controller)

        controller.sceneDidEnterBackground()
        provider.reportEnd()
        // The lifecycle asks the permit now, and the permit waits for the foreground.
        try await eventually { controller.foregroundWaiters == 1 }
        XCTAssertEqual(provider.connects, 1, "the late end of the old connection starts no connect in the background")
        XCTAssertEqual(controller.phase, .connecting, "the run and its opening are kept")
        XCTAssertEqual(log.all.filter { $0 == "radio connect" }.count, 1)

        provider.reportsEnds = true
        controller.sceneDidBecomeActive()
        try await eventually { !controller.isBusy }
        XCTAssertEqual(controller.phase, .confirmed(completed()))
        XCTAssertEqual(provider.connects, 2, "the opening that waited connected, once")
        XCTAssertEqual(provider.opens, 2, "the same opening went on: no new one was asked for")
        XCTAssertEqual(hub.receipts.count, 1)
        XCTAssertEqual(board.receiptCalls, 1)
    }

    func testAConnectWithNoEarlierConnectionIsNotStartedInTheBackgroundEither() async throws {
        hub.scriptReceipt(.success(completed()))
        let controller = makeController()
        controller.sceneDidEnterBackground()
        confirm(controller)
        try await eventually { controller.foregroundWaiters == 1 }
        XCTAssertEqual(provider.opens, 1, "the opening was asked for")
        XCTAssertEqual(provider.connects, 0, "and the radio was not: there is nothing to wait for but the foreground")
        XCTAssertEqual(provider.cancels, 0)
        XCTAssertEqual(controller.phase, .connecting)

        controller.sceneDidBecomeActive()
        try await eventually { !controller.isBusy }
        XCTAssertEqual(controller.phase, .confirmed(completed()))
        XCTAssertEqual(provider.connects, 1, "one connect, when the app was back")
        XCTAssertEqual(provider.opens, 1)
        XCTAssertEqual(hub.receipts.count, 1)
    }

    /// Where the connect of a run can be waiting when the run ends.
    private enum WaitPoint: CaseIterable {
        /// The end of the previous connection is still outstanding.
        case previousEnd
        /// That end arrived in the background: the permit is asked and waits.
        case permit
    }

    private enum Ending: CaseIterable {
        case leave, anotherHub, bluetoothOff, bluetoothResetting
    }

    func testARunThatEndsWhileItsConnectWaitsNeverConnectsAndLeavesNothingBehind() async throws {
        for point in WaitPoint.allCases {
            for ending in Ending.allCases {
                let context = "\(point), \(ending)"
                fresh()
                let controller = makeController()
                try await startARunThatWaitsForTheEndOfThePreviousConnection(controller)
                controller.sceneDidEnterBackground()
                if point == .permit {
                    provider.reportEnd()
                    try await eventually { controller.foregroundWaiters == 1 }
                    XCTAssertEqual(provider.connects, 1, context)
                }

                switch ending {
                case .leave:
                    controller.leave()
                    XCTAssertEqual(controller.phase, .idle, context)
                case .anotherHub:
                    controller.targetDidChange(EnrollmentFixtures.pairedTarget(hubID: EnrollmentFixtures.hubB, url: EnrollmentFixtures.urlB))
                    XCTAssertEqual(controller.phase, .idle, context)
                case .bluetoothOff, .bluetoothResetting:
                    let state: PowerBaseBLEAvailability = ending == .bluetoothOff ? .poweredOff : .resetting
                    provider.set(availability: state)
                    try await eventually { self.failure(controller) == .bluetooth(state) }
                }
                try await eventually { controller.unfinishedRunTasks == 0 }
                XCTAssertEqual(controller.foregroundWaiters, 0, "\(context): the permit that waited was woken and is nobody's any more")

                // The app is back, Bluetooth is on, and everything that can still arrive arrives.
                provider.set(availability: .poweredOn)
                controller.sceneDidBecomeActive()
                provider.reportEnd()
                provider.lifecycle.didFailToConnect(LifecycleBLEBoardProvider.boardID)
                provider.lifecycle.didConnect(LifecycleBLEBoardProvider.boardID)
                XCTAssertFalse(controller.isBusy, context)
                XCTAssertEqual(controller.foregroundWaiters, 0, context)

                // A new run, for this hub again, connects for itself -- and that is the second
                // connect there ever was: the ended run's would have had to come before it.
                provider.reportsEnds = true
                hub.scriptReceipt(.success(completed()))
                controller.targetDidChange(EnrollmentFixtures.pairedTarget())
                controller.acknowledgeResult()
                controller.startScanning()
                confirm(controller)
                try await eventually { !controller.isBusy }
                XCTAssertEqual(controller.phase, .confirmed(completed()), context)
                XCTAssertEqual(provider.connects, 2, "\(context): no connect for the run that was over")
                XCTAssertEqual(hub.receipts.count, 1, "\(context): and no request of it")
                XCTAssertEqual(board.receiptCalls, 1, context)
                try await eventually { controller.unfinishedRunTasks == 0 }
            }
        }
    }
}

// MARK: - The registration run's receipt relay

/// The registration run hands a receipt it found on the board to the hub. That request is a new
/// one: when the board's answer arrived while the app was away, it waits for the foreground.
@MainActor
final class PowerBaseEnrollmentReceiptRelayForegroundTests: XCTestCase {
    typealias Controller = PowerBaseEnrollmentBLEController

    private var log: EnrollmentEventLog!
    private var hub: FakeEnrollmentHub!
    private var removals: FakeRemovalHub!
    private var board: FakeBoard!
    private var provider: FakeBLEBoardProvider!
    private var credentials: InMemoryHubCredentialStore!
    private let receipt = EnrollmentFixtures.releaseReceipt()

    override func setUp() async throws {
        log = EnrollmentEventLog()
        hub = FakeEnrollmentHub()
        hub.issuedManagement = EnrollmentFixtures.managementCredential()
        removals = FakeRemovalHub()
        board = FakeBoard(log: log)
        board.set(capabilities: [.bridgeEndpointV1, .managementV1, .releaseReceiptV1])
        board.set(receipt: receipt)
        provider = FakeBLEBoardProvider(board: board, log: log)
        credentials = InMemoryHubCredentialStore([EnrollmentFixtures.credential(hubID: EnrollmentFixtures.hubA, token: "token-A")])
    }

    private func makeController() -> Controller {
        let controller = Controller(
            provider: provider, transport: LoggedEnrollmentHub(hub: hub, log: log), credentials: credentials,
            pollInterval: .milliseconds(10), boardPollInterval: .milliseconds(10), leaveGrace: .milliseconds(40),
            quietScanPeriod: .milliseconds(30), maxReconnects: 3, requireManagement: true, receiptRelay: removals
        )
        controller.targetDidChange(EnrollmentFixtures.pairedTarget())
        controller.activate()
        return controller
    }

    private func scriptWaitingSession() {
        let session = EnrollmentFixtures.session(.waitingForHeartbeat, managementGeneration: EnrollmentFixtures.managementGeneration)
        hub.scriptStart(.success(session))
        hub.scriptStatus(.success(session))
    }

    private func isJoining(_ controller: Controller) -> Bool {
        if case .joining = controller.phase { true } else { false }
    }

    private func start(_ controller: Controller) {
        controller.start(boardID: FakeBLEBoardProvider.boardID, expectedEUI64: EnrollmentFixtures.eui64, setupCode: EnrollmentFixtures.setupCode)
    }

    /// The receipt request has left; the app goes away; the board's answer arrives.
    private func aRunWhoseReceiptArrivedInTheBackground() async throws -> Controller {
        board.holdReceipt()
        let controller = makeController()
        start(controller)
        try await eventually { self.board.heldReceiptRequests == 1 }
        controller.sceneDidEnterBackground()
        board.releaseHeldReceipt()
        try await eventually { controller.foregroundWaiters == 1 }
        return controller
    }

    func testAReceiptThatArrivedInTheBackgroundIsHandedInOnlyWhenTheAppIsBack() async throws {
        removals.scriptReceipt(.success(RemovalFixtures.removal(.completed, base: EnrollmentFixtures.eui64)))
        scriptWaitingSession()
        let controller = try await aRunWhoseReceiptArrivedInTheBackground()

        XCTAssertEqual(log.all, ["board open", "board status", "board receipt"], "the receipt was read")
        XCTAssertTrue(removals.recorded.isEmpty, "and not handed to the hub in the background")
        XCTAssertTrue(hub.recorded.isEmpty, "nor is a hub session asked for")
        XCTAssertEqual(controller.phase, .authenticating)
        XCTAssertEqual(controller.relayedReceipts, 0)

        controller.sceneDidBecomeActive()
        try await eventually { self.isJoining(controller) }
        XCTAssertEqual(removals.receipts, [.receipt(hubID: EnrollmentFixtures.hubA, token: "token-A", pin: String(repeating: "c", count: 64), receiptHex: receipt.hex)],
                       "handed in once, byte for byte")
        XCTAssertEqual(controller.relayedReceipts, 1)
        XCTAssertEqual(board.receiptCalls, 1, "the board was not asked again")
        XCTAssertEqual(hub.recorded(.start).count, 1, "and the enrollment went on")
        XCTAssertEqual(board.starts.count, 1)
        controller.leave()
    }

    func testARunThatEndsWhileThatRequestWaitsHandsNothingIn() async throws {
        let controller = try await aRunWhoseReceiptArrivedInTheBackground()
        controller.leave()
        XCTAssertEqual(controller.foregroundWaiters, 0, "ending the run woke what waited")
        XCTAssertEqual(controller.phase, .idle)
        controller.sceneDidBecomeActive()

        // A new run reads the board again and hands its receipt in once: a request of the ended
        // run would have had to come before that one.
        removals.scriptReceipt(.success(RemovalFixtures.removal(.completed, base: EnrollmentFixtures.eui64)))
        scriptWaitingSession()
        try await eventually { !controller.isBusy }
        start(controller)
        try await eventually { self.isJoining(controller) }
        XCTAssertEqual(removals.receipts.count, 1, "only the new run's")
        XCTAssertEqual(controller.relayedReceipts, 1)
        XCTAssertEqual(hub.recorded(.start).count, 1)
        controller.leave()
    }
}
#endif
