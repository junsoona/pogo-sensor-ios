#if DEBUG
import PowerBaseBLEKit
import XCTest
@testable import PogoHome

/// Regressions found in review of the DEBUG "BLE 등록 시험" controller, against the same scripted hub
/// and board as `PowerBaseEnrollmentBLEControllerTests`: the background before a hub session
/// exists and while a session is being opened, `REQUEST_CONFLICT`, and a `pb-cancel` the board
/// did not take.
@MainActor
final class PowerBaseEnrollmentBLEFollowUpTests: XCTestCase {
    typealias Controller = PowerBaseEnrollmentBLEController

    private var log: EnrollmentEventLog!
    private var hub: FakeEnrollmentHub!
    private var board: FakeBoard!
    private var provider: FakeBLEBoardProvider!
    private var credentials: InMemoryHubCredentialStore!
    private var reports: [Controller.CleanupReport] = []

    override func setUp() async throws {
        log = EnrollmentEventLog()
        hub = FakeEnrollmentHub()
        board = FakeBoard(log: log)
        provider = FakeBLEBoardProvider(board: board, log: log)
        credentials = InMemoryHubCredentialStore([
            EnrollmentFixtures.credential(hubID: EnrollmentFixtures.hubA, token: "token-A"),
            EnrollmentFixtures.credential(hubID: EnrollmentFixtures.hubB, token: "token-B", certificate: String(repeating: "d", count: 64)),
        ])
        reports = []
    }

    private func freshFixtures() {
        log.clear()
        hub = FakeEnrollmentHub()
        board = FakeBoard(log: log)
        provider = FakeBLEBoardProvider(board: board, log: log)
        reports = []
    }

    private func makeController(maxReconnects: Int = 3, randomBytes: @escaping (Int) -> [UInt8]? = SecureRandomBytes.system) -> Controller {
        let controller = Controller(
            provider: provider, transport: LoggedEnrollmentHub(hub: hub, log: log), credentials: credentials,
            pollInterval: .milliseconds(10), boardPollInterval: .milliseconds(10), leaveGrace: .milliseconds(40),
            quietScanPeriod: .milliseconds(30), maxReconnects: maxReconnects, randomBytes: randomBytes
        )
        controller.onCleanupReport = { [weak self] in self?.reports.append($0) }
        controller.targetDidChange(EnrollmentFixtures.pairedTarget())
        controller.activate()
        return controller
    }

    private func start(_ controller: Controller) {
        controller.start(boardID: FakeBLEBoardProvider.boardID, expectedEUI64: EnrollmentFixtures.eui64, setupCode: EnrollmentFixtures.setupCode)
    }

    private func scriptWaitingHub() {
        hub.scriptStart(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        hub.scriptStatus(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
    }

    private func startedAndAccepted(_ controller: Controller) async throws {
        scriptWaitingHub()
        start(controller)
        try await eventually { self.isJoining(controller) }
    }

    private func isJoining(_ controller: Controller) -> Bool {
        if case .joining = controller.phase { true } else { false }
    }

    private func outcome(_ controller: Controller) -> Controller.Outcome? {
        if case let .finished(outcome) = controller.phase { return outcome }
        return nil
    }

    private func failure(_ controller: Controller) -> Controller.Failure? {
        if case let .failed(failure) = controller.phase { return failure }
        return nil
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(80))
    }

    /// The run went on after the background exactly once: one authentication, one `POST`, one
    /// `pb-start`, one Joiner.
    private func assertTheRunWentOnOnce(_ controller: Controller, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await eventually(file: file, line: line) { self.isJoining(controller) }
        XCTAssertEqual(provider.opens.count, 1, "the original authentication, not a new run", file: file, line: line)
        XCTAssertEqual(hub.recorded(.start).count, 1, "one POST", file: file, line: line)
        XCTAssertEqual(board.starts.count, 1, "one pb-start", file: file, line: line)
        XCTAssertEqual(board.joinerStarts, 1, file: file, line: line)
        let events = log.all
        XCTAssertEqual(events.filter { $0 == "board status" }.prefix(1).count, 1, file: file, line: line)
        let identity = try XCTUnwrap(events.firstIndex(of: "board status"), file: file, line: line)
        let post = try XCTUnwrap(events.firstIndex(of: "hub POST"), file: file, line: line)
        XCTAssertLessThan(identity, post, "the board's identity is checked before the hub is asked", file: file, line: line)
    }

    // MARK: - The background before a hub session exists

    func testBackgroundWhileTheBoardIsBeingAuthenticatedSendsNoIdentityReadAndNoPOSTUntilTheAppIsBack() async throws {
        scriptWaitingHub()
        provider.holdsOpens = true
        let controller = makeController()
        start(controller)
        try await eventually { self.provider.heldCount == 1 }

        controller.sceneDidEnterBackground()
        provider.releaseHeld()
        try await settle()
        XCTAssertEqual(board.statusCalls, 0, "the identity read is a new Bluetooth command: it waits for the foreground")
        XCTAssertTrue(hub.recorded.isEmpty, "and no hub session is asked for in the background")
        XCTAssertTrue(controller.isBusy, "the run is kept")

        controller.sceneDidBecomeActive()
        try await assertTheRunWentOnOnce(controller)
        controller.leave()
    }

    func testBackgroundWhileTheIdentityStatusIsUnderWaySendsNoPOSTUntilTheAppIsBack() async throws {
        scriptWaitingHub()
        board.holdPlainStatus()
        let controller = makeController()
        start(controller)
        try await eventually { self.board.heldPlainStatusRequests == 1 }

        controller.sceneDidEnterBackground()
        board.releasePlainStatus()
        try await settle()
        XCTAssertEqual(board.statusCalls, 1, "the request that was already out is answered")
        XCTAssertTrue(hub.recorded.isEmpty, "but the POST is a new request: not started in the background")
        XCTAssertTrue(board.starts.isEmpty)
        XCTAssertTrue(controller.isBusy)

        controller.sceneDidBecomeActive()
        try await assertTheRunWentOnOnce(controller)
        XCTAssertEqual(board.statusCalls - board.challengeRequests, 1, "the identity is not asked a second time")
        controller.leave()
    }

    func testBackgroundRightBeforeThePOSTSendsNoPOSTUntilTheAppIsBack() async throws {
        scriptWaitingHub()
        var controller: Controller!
        var asked = 0
        // The secrets for the hub are made right after the board's identity was verified and right
        // before the POST: the app goes to the background at exactly that point.
        controller = makeController(randomBytes: { count in
            asked += 1
            if asked == 1 { controller.sceneDidEnterBackground() }
            return SecureRandomBytes.system(count)
        })
        start(controller)
        try await eventually { asked >= 2 }
        try await settle()
        XCTAssertEqual(board.statusCalls, 1, "the identity was verified")
        XCTAssertTrue(hub.recorded.isEmpty, "no POST in the background")
        XCTAssertTrue(controller.isBusy)

        controller.sceneDidBecomeActive()
        try await assertTheRunWentOnOnce(controller)
        XCTAssertEqual(asked, 2, "one PSKd and one request id: the original run's")
        controller.leave()
    }

    func testBackgroundBetweenTheMessagesOfAnOpeningSendsNoFurtherMessageUntilTheAppIsBack() async throws {
        let cases: [(FakeBLEBoardProvider.OpenStep, [FakeBLEBoardProvider.OpenStep])] = [
            (.connect, [.connect]),
            (.version, [.connect, .version]),
            (.handshake0, [.connect, .version, .handshake0]),
        ]
        for (step, sent) in cases {
            freshFixtures()
            scriptWaitingHub()
            provider.holdsOpensAfter = step
            let controller = makeController()
            start(controller)
            try await eventually { self.provider.heldCount == 1 }

            // The answer to that command is under way when the app goes to the background.
            controller.sceneDidEnterBackground()
            provider.releaseHeld()
            try await settle()
            XCTAssertEqual(provider.sentSteps, sent, "\(step): the next message of the opening waits for the foreground")
            XCTAssertEqual(board.openedSessions, 0)
            XCTAssertEqual(board.statusCalls, 0)
            XCTAssertTrue(hub.recorded.isEmpty)
            XCTAssertTrue(controller.isBusy)

            controller.sceneDidBecomeActive()
            try await assertTheRunWentOnOnce(controller)
            XCTAssertEqual(provider.sentSteps, FakeBLEBoardProvider.OpenStep.allCases, "\(step): the same opening went on; nothing was sent twice")
            controller.leave()
        }
    }

    /// Where a run without a hub session can be waiting for the foreground.
    private enum WaitPoint: CaseIterable {
        /// Inside the opening, before the handshake.
        case opening
        /// Authenticated; the identity read is next.
        case identity
        /// The identity is verified; the POST is next.
        case post
    }

    /// Starts a run and brings it to `point`, waiting there in the background.
    private func startAndWaitInTheBackground(_ controller: Controller, at point: WaitPoint) async throws {
        switch point {
        case .opening:
            provider.holdsOpensAfter = .version
            start(controller)
            try await eventually { self.provider.heldCount == 1 }
            controller.sceneDidEnterBackground()
            provider.releaseHeld()
        case .identity:
            provider.holdsOpens = true
            start(controller)
            try await eventually { self.provider.heldCount == 1 }
            controller.sceneDidEnterBackground()
            provider.releaseHeld()
        case .post:
            board.holdPlainStatus()
            start(controller)
            try await eventually { self.board.heldPlainStatusRequests == 1 }
            controller.sceneDidEnterBackground()
            board.releasePlainStatus()
        }
        try await settle()
        XCTAssertTrue(controller.isBusy, "\(point)")
        XCTAssertTrue(hub.recorded.isEmpty, "\(point)")
    }

    /// The run that waited is over for good: coming back sends nothing, and the session it had
    /// opened is closed.
    private func assertNothingFollows(_ controller: Controller, _ point: WaitPoint, _ ending: String) async throws {
        let statusCalls = board.statusCalls
        let steps = provider.sentSteps
        controller.sceneDidBecomeActive()
        try await settle()
        XCTAssertTrue(hub.recorded.isEmpty, "\(point), \(ending): no POST, no DELETE without a session")
        XCTAssertTrue(board.starts.isEmpty, "\(point), \(ending)")
        XCTAssertEqual(board.statusCalls, statusCalls, "\(point), \(ending): no identity read after the run ended")
        XCTAssertEqual(provider.sentSteps, steps, "\(point), \(ending): the opening does not go on")
        XCTAssertEqual(provider.opens.count, 1, "\(point), \(ending)")
        XCTAssertEqual(board.closed, point == .opening ? [] : [1], "\(point), \(ending): a session that was opened is closed")
        XCTAssertFalse(controller.isBusy)
    }

    func testCancellingWhileWaitingForTheForegroundEndsTheRunAndItsCleanUp() async throws {
        for point in WaitPoint.allCases {
            freshFixtures()
            scriptWaitingHub()
            let controller = makeController()
            try await startAndWaitInTheBackground(controller, at: point)
            controller.cancel()
            // The clean-up waits for the run's own task: it must not wait for the foreground.
            try await eventually { self.failure(controller) != nil }
            XCTAssertEqual(failure(controller), .stopped(.init(hub: .notNeeded, board: .notNeeded)), "\(point)")
            try await assertNothingFollows(controller, point, "cancel")
            XCTAssertTrue(controller.canStart, "\(point): a new run may start")
        }
    }

    func testLeavingWhileWaitingForTheForegroundEndsTheRunAndReports() async throws {
        for point in WaitPoint.allCases {
            freshFixtures()
            scriptWaitingHub()
            let controller = makeController()
            try await startAndWaitInTheBackground(controller, at: point)
            controller.leave()
            XCTAssertEqual(controller.phase, .idle)
            try await eventually { self.reports.count == 1 }
            XCTAssertEqual(reports.first?.cleanup, .init(hub: .notNeeded, board: .notNeeded), "\(point)")
            try await assertNothingFollows(controller, point, "leave")
            XCTAssertEqual(controller.phase, .idle)
        }
    }

    func testAnotherHubWhileWaitingForTheForegroundEndsTheRunAndReports() async throws {
        for point in WaitPoint.allCases {
            freshFixtures()
            scriptWaitingHub()
            let controller = makeController()
            try await startAndWaitInTheBackground(controller, at: point)
            controller.targetDidChange(EnrollmentFixtures.pairedTarget(hubID: EnrollmentFixtures.hubB, url: EnrollmentFixtures.urlB))
            XCTAssertEqual(controller.phase, .failed(.sourceChanged))
            try await eventually { self.reports.count == 1 }
            XCTAssertEqual(reports.first?.cleanup, .init(hub: .notNeeded, board: .notNeeded), "\(point)")
            try await assertNothingFollows(controller, point, "another hub")
            XCTAssertEqual(controller.phase, .failed(.sourceChanged), "nothing of the old run is shown for the new source")
        }
    }

    func testANewRunAfterOneThatEndedWhileWaitingStartsCleanly() async throws {
        scriptWaitingHub()
        let controller = makeController()
        try await startAndWaitInTheBackground(controller, at: .identity)
        controller.cancel()
        try await eventually { self.failure(controller) != nil }
        controller.sceneDidBecomeActive()

        start(controller)
        try await eventually { self.isJoining(controller) }
        XCTAssertEqual(provider.opens.count, 2, "the new run authenticates for itself")
        XCTAssertEqual(hub.recorded(.start).count, 1, "one POST: the new run's")
        XCTAssertEqual(board.starts.count, 1)
        XCTAssertEqual(board.joinerStarts, 1)
        controller.leave()
    }

    // MARK: - The background while a session is opened again, with a hub session

    func testBackgroundWhileReconnectingToDeliverGivesTheOpeningUpAndAsksTheHubFirst() async throws {
        hub.scriptStart(.success(EnrollmentFixtures.session(.preparing)))
        hub.scriptStatus(.success(EnrollmentFixtures.session(.preparing)))
        // One try: the opening that is given up for the background must not use it up.
        let controller = makeController(maxReconnects: 1)
        start(controller)
        try await eventually { !self.hub.recorded(.status).isEmpty }
        board.disconnect()
        provider.holdsOpensAfter = .version
        hub.scriptStatus(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        try await eventually { self.provider.heldCount == 1 }
        XCTAssertEqual(provider.opens.count, 2)

        controller.sceneDidEnterBackground()
        provider.releaseHeld()
        try await settle()
        let all = FakeBLEBoardProvider.OpenStep.allCases
        XCTAssertEqual(provider.sentSteps, all + [.connect, .version], "no handshake message in the background")
        XCTAssertTrue(board.starts.isEmpty)
        XCTAssertTrue(controller.isBusy)
        let hubRequests = hub.recorded.count
        try await settle()
        XCTAssertEqual(hub.recorded.count, hubRequests, "and no poll either")

        log.clear()
        controller.sceneDidBecomeActive()
        try await eventually { self.isJoining(controller) }
        let events = log.all
        XCTAssertEqual(events.first, "hub GET", "the hub is asked before the board hears anything")
        XCTAssertEqual(provider.sentSteps, all + [.connect, .version] + all, "the opening that was given up was not carried on; a new one was made")
        XCTAssertEqual(provider.opens.count, 3)
        XCTAssertEqual(board.starts.count, 1)
        XCTAssertEqual(board.joinerStarts, 1)
        XCTAssertEqual(hub.recorded(.start).count, 1)
        controller.leave()
    }

    func testAHubThatFinishedWhileAnOpeningWasGivenUpLeavesTheBoardAlone() async throws {
        hub.scriptStart(.success(EnrollmentFixtures.session(.preparing)))
        hub.scriptStatus(.success(EnrollmentFixtures.session(.preparing)))
        let controller = makeController()
        start(controller)
        try await eventually { !self.hub.recorded(.status).isEmpty }
        board.disconnect()
        provider.holdsOpensAfter = .handshake0
        hub.scriptStatus(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        try await eventually { self.provider.heldCount == 1 }
        controller.sceneDidEnterBackground()
        provider.releaseHeld()
        try await settle()
        let steps = provider.sentSteps

        // The hub's window ran out while the app was away.
        hub.replaceStatus(.success(EnrollmentFixtures.session(.expired, joinerEntry: "removed")))
        controller.sceneDidBecomeActive()
        try await eventually { self.outcome(controller) != nil }
        XCTAssertEqual(outcome(controller)?.session.state, .expired)
        XCTAssertEqual(outcome(controller)?.delivery, .notSent)
        try await settle()
        XCTAssertEqual(provider.sentSteps, steps, "the hub's session is over: Bluetooth is not taken up again")
        XCTAssertEqual(provider.opens.count, 2)
        XCTAssertTrue(board.starts.isEmpty)
        XCTAssertTrue(board.cancels.isEmpty)
    }

    func testAStartUnderWayWhenTheAppGoesAwayIsNotTakenForAStartThatWasNeverSent() async throws {
        // The start is on its way when the app goes to the background; the board takes it, the
        // answer never arrives, and the connection is gone.
        board.loseNextStartAnswer(reachesBoard: true)
        board.holdStart()
        scriptWaitingHub()
        let controller = makeController()
        start(controller)
        try await eventually { self.board.heldStarts == 1 }
        controller.sceneDidEnterBackground()
        board.releaseStart()
        try await settle()
        XCTAssertEqual(provider.opens.count, 1, "no reconnect in the background")
        XCTAssertEqual(board.starts.count, 1)
        XCTAssertEqual(board.joinerStarts, 1, "the board has the request")
        XCTAssertTrue(controller.isBusy)

        // Coming back: the hub first. It still waits, so the original request is looked up -- by
        // its request id, on a new session -- and nothing is started again.
        log.clear()
        controller.sceneDidBecomeActive()
        try await eventually { self.isJoining(controller) }
        XCTAssertEqual(log.all.first, "hub GET")
        XCTAssertEqual(provider.opens.count, 2)
        XCTAssertEqual(board.starts.count, 1, "the start that was under way is not sent a second time")
        XCTAssertEqual(board.joinerStarts, 1)
        XCTAssertEqual(board.attemptRequestID, board.starts.first?.requestID)
        XCTAssertEqual(hub.recorded(.start).count, 1)
        controller.leave()
    }

    func testAStartUnderWayWhenTheAppGoesAwayIsUncertainIfTheHubHasEndedMeanwhile() async throws {
        board.loseNextStartAnswer(reachesBoard: true)
        board.holdStart()
        scriptWaitingHub()
        let controller = makeController()
        start(controller)
        try await eventually { self.board.heldStarts == 1 }
        controller.sceneDidEnterBackground()
        board.releaseStart()
        try await settle()

        hub.replaceStatus(.success(EnrollmentFixtures.session(.expired, joinerEntry: "removed")))
        controller.sceneDidBecomeActive()
        try await eventually { self.outcome(controller) != nil }
        XCTAssertEqual(outcome(controller)?.session.state, .expired)
        XCTAssertEqual(outcome(controller)?.delivery, .uncertain, "a start left this device: not \"nothing was sent to the board\"")
        try await settle()
        XCTAssertEqual(provider.opens.count, 1, "the hub's session is over: Bluetooth is not taken up again")
        XCTAssertEqual(board.starts.count, 1)
    }

    func testBackgroundWhileTheMonitorReconnectsWaitsForTheHubAndStartsNothing() async throws {
        let controller = makeController()
        try await startedAndAccepted(controller)
        board.disconnect()
        board.advance(to: .running, state: .attaching)
        provider.holdsOpensAfter = .version
        try await eventually { self.provider.heldCount == 1 }
        hub.holdStatus()
        controller.sceneDidEnterBackground()
        provider.releaseHeld()
        try await settle()
        let all = FakeBLEBoardProvider.OpenStep.allCases
        XCTAssertEqual(provider.sentSteps, all + [.connect, .version])

        // Back, but the hub has not answered yet: the handshake still waits.
        controller.sceneDidBecomeActive()
        try await settle()
        XCTAssertEqual(provider.sentSteps, all + [.connect, .version], "the hub is asked first")
        hub.releaseHeld()
        try await eventually { controller.boardProgress == .attaching }
        XCTAssertEqual(provider.sentSteps, all + all, "then the same opening goes on")
        XCTAssertEqual(provider.opens.count, 2)
        XCTAssertEqual(board.starts.count, 1, "the original request is looked up; nothing is started")
        XCTAssertEqual(hub.recorded(.start).count, 1)
        controller.leave()
    }

    // MARK: - REQUEST_CONFLICT is not ACCEPTED

    func testARequestConflictFromABoardThatHasNoSuchRequestIsARefusal() async throws {
        board.scriptStart(.requestConflict)
        scriptWaitingHub()
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        let controller = makeController()
        start(controller)
        try await eventually { self.board.starts.count == 1 }
        try await eventually { !controller.isBusy }
        guard case let .boardRefused(code, cleanup) = failure(controller) else { return XCTFail("\(controller.phase)") }
        XCTAssertEqual(code, .requestConflict)
        XCTAssertEqual(cleanup.hub, .cancelled(EnrollmentFixtures.session(.cancelled)), "this run's own hub session is cancelled")
        XCTAssertEqual(board.joinerStarts, 0, "nothing started on the board")
        XCTAssertEqual(board.starts.count, 1, "not sent again, and never under a new request id")
        XCTAssertEqual(hub.recorded(.start).count, 1, "no new hub session with a new PSKd")
        XCTAssertEqual(provider.opens.count, 1)
    }

    func testARequestConflictForARequestThatAlreadyEndedIsNotShownAsInProgress() async throws {
        let cases: [(FakeBoard.AttemptChange, Controller.BoardProgress)] = [
            ((.failed, .waiting, 8), .failed(result: 8)),
            ((.cancelled, .waiting, 13), .cancelled),
        ]
        for (change, progress) in cases {
            let hub = FakeEnrollmentHub()
            self.hub = hub
            let board = FakeBoard(log: log)
            self.board = board
            provider = FakeBLEBoardProvider(board: board, log: log)
            board.deliverNextStartTwice(.same, attemptBecomes: change)
            scriptWaitingHub()
            hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
            let controller = makeController()
            var seen: [Controller.Phase] = []
            start(controller)
            try await eventually {
                seen.append(controller.phase)
                return !controller.isBusy
            }
            XCTAssertFalse(seen.contains { if case .joining = $0 { true } else { false } }, "\(change.phase): an attempt that ended is never shown as in progress")
            guard case let .boardAttemptFailed(result, cleanup) = failure(controller) else { XCTFail("\(change.phase): \(controller.phase)"); continue }
            XCTAssertEqual(result, change.result)
            XCTAssertEqual(controller.boardProgress, progress)
            XCTAssertEqual(cleanup.hub, .cancelled(EnrollmentFixtures.session(.cancelled)))
            XCTAssertEqual(board.joinerStarts, 1, "the one Joiner the first copy started")
            XCTAssertEqual(board.starts.count, 1, "no new request id, no second start")
            XCTAssertEqual(hub.recorded(.start).count, 1)
        }
    }

    func testARequestConflictForAnAttemptUnderWayWithOtherContentIsReadFromTheBoardsStatus() async throws {
        // An earlier copy of this run's start (another challenge) made the attempt.
        board.deliverNextStartTwice(.otherContent)
        scriptWaitingHub()
        let controller = makeController()
        start(controller)
        try await eventually { self.isJoining(controller) }
        try await eventually { controller.boardProgress == .queued }
        XCTAssertEqual(board.statusCalls - board.challengeRequests, 2, "the identity, and the request looked up by its id")
        XCTAssertEqual(board.challengeRequests, 1, "no new challenge: nothing more is started")
        XCTAssertEqual(board.starts.count, 1)
        XCTAssertEqual(board.joinerStarts, 1)
        XCTAssertEqual(board.attemptRequestID, board.starts.first?.requestID, "the original request id")
        XCTAssertEqual(hub.recorded(.start).count, 1)

        board.advance(to: .running, state: .joining)
        try await eventually { controller.boardProgress == .joining }
        XCTAssertNil(outcome(controller), "progress on the board is not success")
        hub.scriptStatus(.success(EnrollmentFixtures.session(.heartbeatReceived)))
        try await eventually { self.outcome(controller) != nil }
        XCTAssertEqual(outcome(controller)?.session.state, .heartbeatReceived, "only the hub's heartbeat is")
        XCTAssertEqual(outcome(controller)?.delivery, .accepted)
    }

    func testARequestConflictForARequestTheBoardEnrolledWithIsStillNotSuccess() async throws {
        board.deliverNextStartTwice(.same, attemptBecomes: (.enrolled, .enrolled, 17))
        scriptWaitingHub()
        let controller = makeController()
        start(controller)
        try await eventually { controller.boardProgress == .enrolled }
        try await settle()
        XCTAssertTrue(isJoining(controller), "the hub is still waited for")
        XCTAssertNil(outcome(controller), "enrolled on the board is not success")
        XCTAssertTrue(board.cancels.isEmpty, "the enrolled board is left alone")
        XCTAssertTrue(hub.recorded(.cancel).isEmpty)
        XCTAssertEqual(board.starts.count, 1)

        hub.scriptStatus(.success(EnrollmentFixtures.session(.expired, joinerEntry: "removed")))
        try await eventually { self.outcome(controller) != nil }
        XCTAssertEqual(outcome(controller)?.session.state, .expired, "the hub did not confirm it")
        XCTAssertEqual(outcome(controller)?.boardProgress, .enrolled)
        XCTAssertTrue(board.cancels.isEmpty)
    }

    func testADuplicateMeansTheBoardHasThisVeryRequest() async throws {
        // The same request arrives twice; the answer the app gets is the second one's.
        board.deliverNextStartTwice(.same)
        scriptWaitingHub()
        let controller = makeController()
        start(controller)
        try await eventually { self.isJoining(controller) }
        XCTAssertEqual(controller.boardProgress, .accepted)
        XCTAssertEqual(board.statusCalls - board.challengeRequests, 1, "DUPLICATE needs no look-up")
        XCTAssertEqual(board.starts.count, 1)
        XCTAssertEqual(board.joinerStarts, 1, "nothing new started")
        XCTAssertEqual(hub.recorded(.start).count, 1)
        controller.leave()
    }

    /// A `pb-start` whose answer is lost after the board took it; the look-up on the new session
    /// is held until the test has moved the board's attempt on.
    private func startWithALostAnswerAndAHeldLookUp(_ controller: Controller) async throws {
        board.loseNextStartAnswer(reachesBoard: true)
        board.holdStart()
        scriptWaitingHub()
        start(controller)
        try await eventually { self.board.heldStarts == 1 }
        board.holdChallenges()
        board.releaseStart()
        try await eventually { self.board.heldChallengeRequests == 1 }
    }

    func testAStartWhoseAnswerIsLostIsShownAsFarAsTheBoardSaysItIs() async throws {
        let controller = makeController()
        try await startWithALostAnswerAndAHeldLookUp(controller)
        board.advance(to: .running, state: .attaching)
        board.releaseChallenges()
        try await eventually { self.isJoining(controller) }
        XCTAssertEqual(controller.boardProgress, .attaching, "the phase and the state, not just the match")
        XCTAssertEqual(board.starts.count, 1, "the board had it: no second pb-start")
        XCTAssertEqual(board.joinerStarts, 1)
        XCTAssertEqual(provider.opens.count, 2)
        XCTAssertEqual(hub.recorded(.start).count, 1)
        controller.leave()
    }

    func testAStartWhoseAnswerIsLostAndWhoseAttemptHasFailedIsNotShownAsInProgress() async throws {
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        let controller = makeController()
        try await startWithALostAnswerAndAHeldLookUp(controller)
        board.advance(to: .failed, state: .waiting, result: 10)
        var seen: [Controller.Phase] = []
        board.releaseChallenges()
        try await eventually {
            seen.append(controller.phase)
            return !controller.isBusy
        }
        XCTAssertFalse(seen.contains { if case .joining = $0 { true } else { false } }, "a matching request that failed is not a request in progress")
        guard case let .boardAttemptFailed(result, cleanup) = failure(controller) else { return XCTFail("\(controller.phase)") }
        XCTAssertEqual(result, 10, "joiner_timeout")
        XCTAssertEqual(cleanup.hub, .cancelled(EnrollmentFixtures.session(.cancelled)))
        XCTAssertEqual(cleanup.board, .nothingToCancel)
        XCTAssertEqual(board.starts.count, 1, "not sent again")
        XCTAssertEqual(hub.recorded(.start).count, 1)
    }

    func testAHeartbeatThatWinsTheRaceAgainstTheConflictLookUpIsNotOverwrittenByTheBoardsError() async throws {
        board.deliverNextStartTwice(.same, attemptBecomes: (.failed, .waiting, 15))
        scriptWaitingHub()
        // The hub got the heartbeat before this run's cancel arrived.
        hub.scriptCancel(.failure(.sessionAlreadyFinal(EnrollmentFixtures.session(.heartbeatReceived))))
        let controller = makeController()
        start(controller)
        try await eventually { !controller.isBusy }
        XCTAssertEqual(outcome(controller)?.session.state, .heartbeatReceived, "the hub's success, not the board's late error")
        XCTAssertEqual(outcome(controller)?.boardProgress, .failed(result: 15), "what the board said is still shown as what the board said")
        XCTAssertEqual(board.starts.count, 1)
        XCTAssertEqual(hub.recorded(.start).count, 1)

        // And nothing that arrives later changes it.
        try await settle()
        XCTAssertEqual(outcome(controller)?.session.state, .heartbeatReceived)
    }

    func testARequestConflictThatCannotBeLookedUpIsUncertainNotAccepted() async throws {
        board.scriptStart(.requestConflict)
        board.holdStart()
        scriptWaitingHub()
        let controller = makeController(maxReconnects: 2)
        var seen: [Controller.Phase] = []
        start(controller)
        try await eventually { self.board.heldStarts == 1 }
        // The connection is gone right after the board's answer, and can't be made again.
        board.failStatus(.requestFailed(.disconnected))
        provider.alwaysFailOpens = .connectionFailed("timeout")
        board.releaseStart()
        try await eventually {
            seen.append(controller.phase)
            if case .deliveryUncertain = controller.phase { return true }
            return false
        }
        XCTAssertFalse(seen.contains { if case .joining = $0 { true } else { false } })
        XCTAssertNil(controller.boardProgress, "nothing the board said is shown as an acceptance")
        XCTAssertEqual(provider.opens.count, 3, "bounded")
        XCTAssertEqual(board.starts.count, 1)
        XCTAssertTrue(hub.recorded(.cancel).isEmpty, "the hub session is kept and followed")
        hub.scriptStatus(.success(EnrollmentFixtures.session(.heartbeatReceived)))
        try await eventually { self.outcome(controller) != nil }
        XCTAssertEqual(outcome(controller)?.delivery, .uncertain)
    }

    // MARK: - A cancel the board did not take

    func testACancelTheBoardRefusesIsNotReportedAsNothingToCancel() async throws {
        for code in [PowerBaseBLECode.busy, .closed, .wrongTarget, .internalError, .malformed] {
            let hub = FakeEnrollmentHub()
            self.hub = hub
            let board = FakeBoard(log: log)
            self.board = board
            provider = FakeBLEBoardProvider(board: board, log: log)
            hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
            let controller = makeController()
            try await startedAndAccepted(controller)
            board.scriptCancel(code)
            controller.cancel()
            try await eventually { self.outcome(controller) != nil }
            let cleanup = try XCTUnwrap(outcome(controller)?.cleanup)
            XCTAssertFalse(String(describing: cleanup.board).contains("nothingToCancel"), "\(code.name) says nothing about whether an attempt exists")
            XCTAssertEqual(cleanup.board, .refused(code), code.name)
            XCTAssertEqual(board.cancels.count, 1, "\(code.name): the board answered; it is not asked again on a new connection")
            XCTAssertEqual(provider.opens.count, 1)
            XCTAssertEqual(cleanup.hub, .cancelled(EnrollmentFixtures.session(.cancelled)), "\(code.name): the hub session is cancelled whatever the board said")
            XCTAssertEqual(board.attemptPhase, .queued, "the scripted refusal left the attempt as it was")
        }
    }

    func testACancelTheBoardRefusesAfterReconnectingIsNotReportedAsNothingToCancel() async throws {
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        let controller = makeController()
        try await startedAndAccepted(controller)
        // The first cancel gets no answer; the one on the new connection is refused.
        board.failNextCancel(.requestFailed(.timeout))
        board.scriptCancel(.busy)
        controller.cancel()
        try await eventually { self.outcome(controller) != nil }
        let cleanup = try XCTUnwrap(outcome(controller)?.cleanup)
        XCTAssertFalse(String(describing: cleanup.board).contains("nothingToCancel"))
        XCTAssertEqual(cleanup.board, .refused(.busy))
        XCTAssertEqual(board.cancels.count, 2)
        XCTAssertEqual(Set(board.cancels.map(\.requestID)), Set(board.starts.map(\.requestID)), "this run's own request id both times")
        XCTAssertEqual(provider.opens.count, 2)
        XCTAssertEqual(cleanup.hub, .cancelled(EnrollmentFixtures.session(.cancelled)))
    }

    func testOnlyOKIsACancelAndOnlyNoSuchAttemptMeansThereIsNothingToCancel() async throws {
        XCTAssertEqual(Controller.boardCancel(for: .ok), .taken)
        XCTAssertEqual(Controller.boardCancel(for: .noSuchAttempt), .nothingToCancel)
        for code in PowerBaseBLECode.allCases where code != .ok && code != .noSuchAttempt {
            XCTAssertEqual(Controller.boardCancel(for: code), .refused(code), code.name)
        }

        // NO_SUCH_ATTEMPT from the board itself: its attempt had already failed.
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        hub.holdStatus()
        let controller = makeController()
        scriptWaitingHub()
        start(controller)
        hub.releaseHeld()
        try await eventually { self.isJoining(controller) }
        board.advance(to: .failed, state: .waiting, result: 9)
        controller.cancel()
        try await eventually { !controller.isBusy }
        let cleanup: Controller.Cleanup?
        switch controller.phase {
        case let .finished(outcome): cleanup = outcome.cleanup
        case let .failed(.boardAttemptFailed(_, found)): cleanup = found
        default: cleanup = nil
        }
        XCTAssertEqual(cleanup?.board, .nothingToCancel)
    }

    func testAClosedBoardThatStillRunsItsAttemptIsNotReportedAsHavingNothingToCancel() async throws {
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        let controller = makeController()
        try await startedAndAccepted(controller)
        board.advance(to: .running, state: .joining)
        try await eventually { controller.boardProgress == .joining }
        // Too many failed handshakes from somewhere: BLE enrollment closes, the Joiner goes on.
        board.closeEnrollment()
        controller.cancel()
        try await eventually { self.outcome(controller) != nil }
        XCTAssertEqual(outcome(controller)?.cleanup?.board, .refused(.closed))
        XCTAssertEqual(board.attemptPhase, .running, "the board's attempt is still under way")
        XCTAssertEqual(outcome(controller)?.session.state, .cancelled, "the hub's session is cancelled all the same")
    }

    func testACancelWithoutAnAnswerIsUnconfirmedNotUndelivered() async throws {
        // Explicit cancel: the answer is lost and the board can't be reached again.
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        var controller = makeController()
        try await startedAndAccepted(controller)
        board.failNextCancel(.requestFailed(.timeout))
        provider.alwaysFailOpens = .connectionFailed("timeout")
        controller.cancel()
        try await eventually { self.outcome(controller) != nil }
        XCTAssertEqual(outcome(controller)?.cleanup?.board, .unconfirmed, "the cancel left this device; the board may have taken it")
        XCTAssertEqual(board.cancels.count, 1)

        // Leaving: no second connection is made, so the lost answer stays lost.
        freshFixtures()
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        controller = makeController()
        try await startedAndAccepted(controller)
        board.failNextCancel(.requestFailed(.timeout))
        controller.leave()
        try await eventually { self.reports.count == 1 }
        XCTAssertEqual(reports.first?.cleanup, .init(hub: .cancelled(EnrollmentFixtures.session(.cancelled)), board: .unconfirmed))
        XCTAssertEqual(provider.opens.count, 1)
    }

    func testLeavingReportsACancelTheBoardRefused() async throws {
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        let controller = makeController()
        try await startedAndAccepted(controller)
        board.scriptCancel(.busy)
        controller.leave()
        try await eventually { self.reports.count == 1 }
        XCTAssertEqual(reports.first?.cleanup, .init(hub: .cancelled(EnrollmentFixtures.session(.cancelled)), board: .refused(.busy)),
                       "what is left for the screen below says that the board did not take the cancel")
    }

    func testAHubCancelThatFailsDoesNotSkipTheBoardAndItsResultIsKept() async throws {
        // The hub can't be reached: the board is asked all the same, and took the cancel.
        hub.scriptCancel(.failure(.unreachable("timeout")))
        let controller = makeController()
        try await startedAndAccepted(controller)
        controller.cancel()
        try await eventually { if case .earlierHubSession = controller.phase { true } else { false } }
        XCTAssertEqual(board.cancels.count, 1)
        XCTAssertEqual(board.attemptPhase, .cancelled)

        // The session, followed again, ends by itself: the board's part is still reported as it was.
        hub.scriptStatus(.success(EnrollmentFixtures.session(.expired, joinerEntry: "removed")))
        try await eventually { self.outcome(controller) != nil }
        XCTAssertEqual(outcome(controller)?.session.state, .expired)
        XCTAssertEqual(outcome(controller)?.cleanup?.board, .taken, "not \"nothing was sent to the board\"")
        XCTAssertEqual(board.cancels.count, 1, "the board is not asked twice")
    }

    func testAHubCancelThatFailsAndABoardThatRefusesAreBothReported() async throws {
        hub.scriptCancel(.failure(.unreachable("timeout")))
        let controller = makeController()
        try await startedAndAccepted(controller)
        board.scriptCancel(.busy)
        controller.cancel()
        try await eventually { if case .earlierHubSession = controller.phase { true } else { false } }
        XCTAssertEqual(board.cancels.count, 1, "the hub's failure did not skip the board")

        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        controller.cancel()
        try await eventually { self.outcome(controller) != nil }
        XCTAssertEqual(outcome(controller)?.session.state, .cancelled)
        XCTAssertEqual(outcome(controller)?.cleanup?.board, .refused(.busy), "the refusal is not replaced by \"nothing to cancel\"")
        XCTAssertEqual(hub.recorded(.cancel).count, 2)
    }

    func testAHubThatRefusesTheCancelStillLeavesTheBoardsAnswerVisible() async throws {
        for (code, expected) in [(PowerBaseBLECode.ok, Controller.BoardCancel.taken), (.busy, .refused(.busy))] {
            freshFixtures()
            hub.scriptCancel(.failure(.unauthorized))
            let controller = makeController()
            try await startedAndAccepted(controller)
            board.scriptCancel(code)
            controller.cancel()
            try await eventually { self.failure(controller) != nil }
            XCTAssertEqual(failure(controller), .hub(.unauthorized, board: expected), code.name)
            XCTAssertEqual(board.cancels.count, 1)
            XCTAssertEqual(hub.recorded(.cancel).count, 1)
        }
    }
}
#endif
