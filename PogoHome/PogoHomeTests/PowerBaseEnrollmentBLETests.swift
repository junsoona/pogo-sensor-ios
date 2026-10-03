#if DEBUG
import CoreBluetooth
import PowerBaseBLEKit
import XCTest
@testable import PogoHome

/// The DEBUG "BLE 등록 시험" state machine against a scripted hub and a scripted board. Nothing here
/// uses Bluetooth or a network: what is checked is the order and the number of requests, and what
/// is (and is not) shown as success.
@MainActor
final class PowerBaseEnrollmentBLEControllerTests: XCTestCase {
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

    private func makeController(
        target: Controller.Target = EnrollmentFixtures.pairedTarget(), maxReconnects: Int = 3, leaveGrace: Duration = .milliseconds(40)
    ) -> Controller {
        let controller = Controller(
            provider: provider, transport: LoggedEnrollmentHub(hub: hub, log: log), credentials: credentials,
            pollInterval: .milliseconds(10), boardPollInterval: .milliseconds(10), leaveGrace: leaveGrace,
            quietScanPeriod: .milliseconds(30), maxReconnects: maxReconnects
        )
        controller.onCleanupReport = { [weak self] in self?.reports.append($0) }
        controller.targetDidChange(target)
        controller.activate()
        return controller
    }

    private func start(_ controller: Controller, eui64: String = EnrollmentFixtures.eui64, setupCode: String = EnrollmentFixtures.setupCode) {
        controller.start(boardID: FakeBLEBoardProvider.boardID, expectedEUI64: eui64, setupCode: setupCode)
    }

    /// A run that reached "the board has the request; the hub is waiting".
    private func startedAndAccepted(_ controller: Controller) async throws {
        hub.scriptStart(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        hub.scriptStatus(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
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

    /// Lets queued tasks (a late answer, a request that should not happen) run.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(80))
    }

    // MARK: - The whole way

    func testAuthenticateThenHubThenOneStartThenOnlyTheHubsHeartbeatIsSuccess() async throws {
        hub.scriptStart(.success(EnrollmentFixtures.session(.preparing)))
        hub.scriptStatus(.success(EnrollmentFixtures.session(.preparing)), .success(EnrollmentFixtures.session(.preparing)),
                         .success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        let controller = makeController()
        XCTAssertTrue(controller.canStart)

        start(controller, eui64: EnrollmentFixtures.eui64.uppercased(), setupCode: "  " + EnrollmentFixtures.setupCode.lowercased() + "\n")
        XCTAssertEqual(controller.phase, .authenticating)
        XCTAssertTrue(hub.recorded.isEmpty, "nothing goes to the hub before the board is authenticated")

        try await eventually { self.isJoining(controller) }
        XCTAssertEqual(provider.opens, [.init(boardID: FakeBLEBoardProvider.boardID, eui64: EnrollmentFixtures.eui64, setupCode: EnrollmentFixtures.setupCode)],
                       "user name = the confirmed EUI-64 in lower case; password = the code, trimmed and upper-cased only")
        let post = try XCTUnwrap(hub.recorded(.start).first)
        XCTAssertEqual(hub.recorded(.start).count, 1)
        XCTAssertEqual(post.eui64, EnrollmentFixtures.eui64, "the authenticated EUI-64")
        XCTAssertEqual(post.baseURL, EnrollmentFixtures.urlA)
        XCTAssertEqual(post.token, "token-A")
        XCTAssertEqual(post.pinnedCertificate, String(repeating: "c", count: 64))
        let pskd = try XCTUnwrap(post.pskd)
        XCTAssertTrue(ThreadPSKd.isValid(pskd) && pskd.count == 12)
        XCTAssertNotEqual(pskd, EnrollmentFixtures.setupCode, "the setup code and the PSKd are different things")

        XCTAssertEqual(board.starts.count, 1, "exactly one pb-start")
        XCTAssertEqual(board.starts.first?.pskd, pskd, "the same PSKd for the hub and the board")
        XCTAssertEqual(board.starts.first?.target, EnrollmentFixtures.eui64)
        XCTAssertEqual(board.starts.first?.requestID.count, 16)
        XCTAssertNotEqual(board.starts.first?.requestID, Data(count: 16))
        XCTAssertEqual(board.joinerStarts, 1)

        // The order: board first, then the hub, then (only once the hub waits) the challenge and the start.
        let events = log.all
        let post0 = try XCTUnwrap(events.firstIndex(of: "hub POST"))
        let challenge0 = try XCTUnwrap(events.firstIndex(of: "board status+challenge"))
        let start0 = try XCTUnwrap(events.firstIndex(of: "board start"))
        XCTAssertEqual(Array(events.prefix(3)), ["board open", "board status", "hub POST"])
        XCTAssertGreaterThanOrEqual(events[post0..<challenge0].filter { $0 == "hub GET" }.count, 3, "the hub was preparing, preparing, then waiting")
        XCTAssertEqual(start0, challenge0 + 1, "the challenge is fetched right before the start, not earlier")

        // The board's progress is progress.
        board.advance(to: .running, state: .joining)
        try await eventually { controller.boardProgress == .joining }
        board.advance(to: .running, state: .attaching)
        try await eventually { controller.boardProgress == .attaching }
        board.advance(to: .enrolled, state: .enrolled, result: 17)
        try await eventually { controller.boardProgress == .enrolled }
        try await settle()
        XCTAssertTrue(isJoining(controller), "ACCEPTED, joining, attaching and enrolled are never success")
        XCTAssertNil(outcome(controller))

        hub.scriptStatus(.success(EnrollmentFixtures.session(.heartbeatReceived)))
        try await eventually { self.outcome(controller) != nil }
        XCTAssertEqual(outcome(controller)?.session.state, .heartbeatReceived)
        XCTAssertEqual(outcome(controller)?.delivery, .accepted)
        XCTAssertEqual(outcome(controller)?.boardProgress, .enrolled)
        XCTAssertFalse(controller.isBusy)
        XCTAssertTrue(hub.recorded(.cancel).isEmpty)
        XCTAssertTrue(board.cancels.isEmpty, "an enrolled board is not asked to cancel anything")
        XCTAssertEqual(board.starts.count, 1)
        XCTAssertEqual(hub.recorded(.start).count, 1)

        let polls = hub.recorded(.status).count
        let statusCalls = board.statusCalls
        try await settle()
        XCTAssertEqual(hub.recorded(.status).count, polls, "polling stops at the final state")
        XCTAssertEqual(board.statusCalls, statusCalls)
    }

    func testNothingIsSentToTheBoardWhileTheHubPrepares() async throws {
        hub.scriptStart(.success(EnrollmentFixtures.session(.preparing)))
        hub.scriptStatus(.success(EnrollmentFixtures.session(.preparing)))
        let controller = makeController()
        start(controller)
        try await eventually { self.hub.recorded(.status).count >= 5 }
        if case .preparingHub = controller.phase {} else { XCTFail("\(controller.phase)") }
        XCTAssertTrue(board.starts.isEmpty, "no pb-start while the hub is preparing")
        XCTAssertEqual(board.challengeRequests, 0, "and no challenge fetched ahead of time")
        XCTAssertEqual(board.statusCalls, 1, "only the identity check")
        controller.leave()
    }

    func testAHubSessionThatEndsWhilePreparingNeverReachesTheBoard() async throws {
        for final in [PowerBaseEnrollmentSession.State.failed, .expired, .cancelled] {
            log.clear()
            let hub = FakeEnrollmentHub()
            self.hub = hub
            let board = FakeBoard(log: log)
            self.board = board
            provider = FakeBLEBoardProvider(board: board, log: log)
            hub.scriptStart(.success(EnrollmentFixtures.session(.preparing)))
            hub.scriptStatus(.success(EnrollmentFixtures.session(.preparing)), .success(EnrollmentFixtures.session(final, error: final == .failed ? "commissioner_rejected" : nil)))
            let controller = makeController()
            start(controller)
            try await eventually { self.outcome(controller) != nil }
            XCTAssertEqual(outcome(controller)?.session.state, final)
            XCTAssertEqual(outcome(controller)?.delivery, .notSent)
            XCTAssertTrue(board.starts.isEmpty, "\(final): nothing was delivered")
            XCTAssertEqual(board.challengeRequests, 0)
            XCTAssertTrue(board.cancels.isEmpty)
        }
    }

    func testRepeatedEventsNeverPostOrStartTwice() async throws {
        let controller = makeController()
        try await startedAndAccepted(controller)
        // Whatever a view may do while a run is under way.
        for _ in 0..<5 {
            start(controller)
            controller.activate()
            controller.screenDidAppear()
            controller.targetDidChange(EnrollmentFixtures.pairedTarget())
            controller.sceneDidBecomeActive()
            controller.startScanning()
            controller.askHubAgain()
        }
        try await eventually { self.hub.recorded(.status).count >= 6 }
        XCTAssertEqual(hub.recorded(.start).count, 1, "one POST")
        XCTAssertEqual(board.starts.count, 1, "one pb-start")
        XCTAssertEqual(board.joinerStarts, 1)
        XCTAssertEqual(provider.opens.count, 1, "one authentication")
        XCTAssertTrue(isJoining(controller))
        controller.leave()
    }

    func testHubExpiryAfterTheBoardTookTheRequestIsNotSuccess() async throws {
        let controller = makeController()
        try await startedAndAccepted(controller)
        board.advance(to: .enrolled, state: .enrolled, result: 17)
        try await eventually { controller.boardProgress == .enrolled }
        hub.scriptStatus(.success(EnrollmentFixtures.session(.expired, joinerEntry: "removed")))
        try await eventually { self.outcome(controller) != nil }
        XCTAssertEqual(outcome(controller)?.session.state, .expired, "the board may have joined; the hub did not confirm it")
        XCTAssertEqual(outcome(controller)?.boardProgress, .enrolled)
        XCTAssertTrue(board.cancels.isEmpty, "the enrolled board's marker, Dataset and Thread link are left alone")
        XCTAssertTrue(hub.recorded(.cancel).isEmpty)
    }

    // MARK: - Nothing reaches the hub unless the right board is authenticated

    func testAWrongSetupCodeSendsNothingToTheHubAndIsNotRetried() async throws {
        provider.openErrors = [.client(.authenticationFailed)]
        let controller = makeController()
        start(controller)
        try await eventually { self.failure(controller) != nil }
        XCTAssertEqual(failure(controller), .authenticationFailed)
        try await settle()
        XCTAssertEqual(provider.opens.count, 1, "no second handshake: each failure counts against the board's five")
        XCTAssertTrue(hub.recorded.isEmpty)
        XCTAssertTrue(board.starts.isEmpty)
        XCTAssertFalse(controller.isBusy)
    }

    func testEveryWayOfNotGettingASessionSendsNothingToTheHub() async throws {
        let cases: [(PowerBaseBLEOpenError, Controller.Failure)] = [
            (.client(.handshakeRefused), .handshakeRefused),
            (.client(.boardProofMismatch), .boardProofMismatch),
            (.client(.unsupportedVersion(.securityVersion(0))), .protocolMismatch("securityVersion(0)")),
            (.client(.unsupportedVersion(.securityVersion(1))), .protocolMismatch("securityVersion(1)")),
            (.client(.unsupportedVersion(.securityPatchVersion(2))), .protocolMismatch("securityPatchVersion(2)")),
            (.client(.unsupportedVersion(.enrollmentProtocol(2))), .protocolMismatch("enrollmentProtocol(2)")),
            (.client(.handshakeMalformed("device_nonce")), .protocolMismatch("device_nonce")),
            (.gattMismatch("duplicate endpoint"), .protocolMismatch("duplicate endpoint")),
            (.connectionFailed("timeout"), .connectionFailed("timeout")),
            (.client(.handshakeInterrupted(.disconnected)), .connectionFailed("handshake")),
            (.boardNotFound, .boardNotFound),
        ]
        for (error, expected) in cases {
            provider.openErrors = [error]
            let controller = makeController()
            start(controller)
            try await eventually { self.failure(controller) != nil }
            XCTAssertEqual(failure(controller), expected)
        }
        try await settle()
        XCTAssertEqual(provider.opens.count, cases.count, "one attempt each")
        XCTAssertTrue(hub.recorded.isEmpty)
        XCTAssertTrue(board.starts.isEmpty)
    }

    func testABoardThatReportsAnotherEUI64SendsNothingToTheHub() async throws {
        board.report(eui64: "00124b0001a2ffff")
        let controller = makeController()
        start(controller)
        try await eventually { self.failure(controller) != nil }
        XCTAssertEqual(failure(controller), .differentBoard(actual: "00124b0001a2ffff"))
        try await settle()
        XCTAssertTrue(hub.recorded.isEmpty)
        XCTAssertTrue(board.starts.isEmpty)
        XCTAssertEqual(board.closed, [1], "the connection is closed")
    }

    func testARowAdvertisingAnotherEUI64IsNotEvenConnected() async throws {
        let controller = makeController()
        start(controller, eui64: "00124b0001a2ffff")
        XCTAssertEqual(controller.phase, .failed(.advertisedNameMismatch))
        try await settle()
        XCTAssertTrue(provider.opens.isEmpty, "no handshake is spent on the wrong board")
        XCTAssertTrue(hub.recorded.isEmpty)
    }

    func testARowWithoutANameIsConnectedAndJudgedByItsAuthenticatedEUI64() async throws {
        provider.boards = [PowerBaseBLEDiscoveredBoard(id: FakeBLEBoardProvider.boardID, name: nil, advertisedEUI64: nil, rssi: -70)]
        hub.scriptStart(.success(EnrollmentFixtures.session(.cancelled)))
        let controller = makeController()
        start(controller)
        try await eventually { self.outcome(controller) != nil }
        XCTAssertEqual(provider.opens.first?.eui64, EnrollmentFixtures.eui64, "the EUI-64 the tester typed is the user name")
        XCTAssertEqual(hub.recorded(.start).count, 1)
    }

    func testBluetoothProblemsSendNothing() async throws {
        for state in [PowerBaseBLEAvailability.denied, .restricted, .poweredOff, .unsupported, .unknown, .resetting] {
            provider.availability = state
            let controller = makeController()
            XCTAssertEqual(controller.availability, state)
            XCTAssertFalse(controller.canStart, "\(state)")
            start(controller)
            XCTAssertEqual(controller.phase, .failed(.bluetooth(state)))
        }
        try await settle()
        XCTAssertTrue(provider.opens.isEmpty)
        XCTAssertTrue(hub.recorded.isEmpty)
    }

    func testMalformedInputSendsNothing() async throws {
        let controller = makeController()
        for bad in ["00:12:4b:00:01:a2:b3:c4", "*", "0000000000000000", ""] {
            start(controller, eui64: bad)
            XCTAssertEqual(controller.phase, .failed(.invalidEUI64), bad)
        }
        for bad in ["", "MFRGGZDFMZTWQ2LKNNWG23TPO", "MFRGGZDFMZTWQ2LKNNWG23TPOA2", "MFRGG-ZDFMZTWQ2LKNNWG23TPO", "MFRGG ZDFMZTWQ2LKNNWG23TPOA", "0FRGGZDFMZTWQ2LKNNWG23TPOA"] {
            start(controller, setupCode: bad)
            XCTAssertEqual(controller.phase, .failed(.invalidSetupCode), bad)
        }
        try await settle()
        XCTAssertTrue(provider.opens.isEmpty, "a code that is not a setup code never costs the board a handshake")
        XCTAssertTrue(hub.recorded.isEmpty)
    }

    func testIneligibleSourcesAndAMissingCredentialSendNothing() async throws {
        let cases: [(Controller.Target, Controller.Ineligibility)] = [
            (.init(hubID: nil, baseURL: nil, isSimulated: true, isPaired: false), .simulatedData),
            (.init(hubID: nil, baseURL: EnrollmentFixtures.urlA, isSimulated: false, isPaired: false), .typedAddress),
            (.init(hubID: EnrollmentFixtures.hubA, baseURL: nil, isSimulated: false, isPaired: true), .noAddress),
            (.init(hubID: EnrollmentFixtures.hubA, baseURL: EnrollmentFixtures.urlA, isSimulated: false, isPaired: false), .notPaired),
        ]
        for (target, reason) in cases {
            let controller = makeController(target: target)
            XCTAssertEqual(controller.ineligibility, reason)
            XCTAssertFalse(controller.canStart)
            start(controller)
            XCTAssertEqual(controller.phase, .idle)
        }
        try credentials.deleteCredential(forHubID: EnrollmentFixtures.hubA)
        let controller = makeController()
        start(controller)
        XCTAssertEqual(controller.phase, .failed(.credentialUnavailable))
        try await settle()
        XCTAssertTrue(provider.opens.isEmpty, "not even Bluetooth is used")
        XCTAssertTrue(hub.recorded.isEmpty)
    }

    func testABoardThatCannotTakeAStartSendsNothingToTheHub() async throws {
        let setups: [((FakeBoard) -> Void, Controller.Failure)] = [
            ({ $0.setForeignAttemptActive() }, .boardBusy),
            ({ $0.set(state: .joining) }, .boardNotWaiting("joining")),
            ({ $0.set(state: .enrolled) }, .boardNotWaiting("enrolled")),
            ({ $0.closeEnrollment() }, .boardClosed),
            ({ $0.setJoinerUnavailable() }, .boardUnavailable),
            ({ $0.failStatus(.malformedResponse(.field("state"))) }, .protocolMismatch("field(\"state\")")),
            ({ $0.failStatus(.refusedByBoard(.unsupportedVersion)) }, .protocolMismatch("UNSUPPORTED_VERSION")),
        ]
        for (setup, expected) in setups {
            let board = FakeBoard(log: log)
            setup(board)
            self.board = board
            provider = FakeBLEBoardProvider(board: board, log: log)
            let controller = makeController()
            start(controller)
            try await eventually { self.failure(controller) != nil }
            XCTAssertEqual(failure(controller), expected)
            XCTAssertTrue(board.starts.isEmpty)
        }
        try await settle()
        XCTAssertTrue(hub.recorded.isEmpty)
    }

    func testNoSecureRandomnessSendsNothingToTheHub() async throws {
        let controller = Controller(provider: provider, transport: hub, credentials: credentials, pollInterval: .milliseconds(10), randomBytes: { _ in nil })
        controller.targetDidChange(EnrollmentFixtures.pairedTarget())
        controller.activate()
        start(controller)
        try await eventually { self.failure(controller) != nil }
        XCTAssertEqual(failure(controller), .randomnessUnavailable)
        XCTAssertTrue(hub.recorded.isEmpty)
        XCTAssertTrue(board.starts.isEmpty)
    }

    // MARK: - The hub's answers

    func testAnotherDevicesSessionOrAnOnlineBaseRefusesTheStartAndTheBoardGetsNothing() async throws {
        for error in [PowerBaseEnrollmentError.enrollmentInProgress(ownSession: nil), .powerBaseAlreadyConnected, .enrollmentDisabled, .unauthorized,
                      .certificateMismatch, .unavailable("startup"), .internalError, .rejected("invalid_pskd")] {
            let hub = FakeEnrollmentHub()
            self.hub = hub
            let board = FakeBoard(log: log)
            self.board = board
            provider = FakeBLEBoardProvider(board: board, log: log)
            hub.scriptStart(.failure(error))
            let controller = makeController()
            start(controller)
            try await eventually { self.failure(controller) != nil }
            XCTAssertEqual(failure(controller), .hub(error, board: nil))
            try await settle()
            XCTAssertTrue(board.starts.isEmpty, "\(error)")
            XCTAssertEqual(hub.recorded.count, 1, "the POST only: there is no session to cancel")
            XCTAssertEqual(board.closed, [1])
        }
    }

    func testThisDevicesEarlierSessionIsFollowedAndItsUnknownPSKdIsNeverDelivered() async throws {
        let earlier = EnrollmentFixtures.session(.waitingForHeartbeat, id: EnrollmentFixtures.otherSessionID)
        hub.scriptStart(.failure(.enrollmentInProgress(ownSession: earlier)))
        hub.scriptStatus(.success(earlier))
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled, id: EnrollmentFixtures.otherSessionID)))
        let controller = makeController()
        start(controller)
        try await eventually { if case .earlierHubSession = controller.phase { true } else { false } }
        try await eventually { self.hub.recorded(.status).count >= 4 }
        XCTAssertEqual(hub.recorded(.status).first?.sessionID, EnrollmentFixtures.otherSessionID)
        XCTAssertTrue(board.starts.isEmpty, "the hub waits for a PSKd this run does not have: the board gets nothing")
        XCTAssertEqual(board.challengeRequests, 0)
        XCTAssertEqual(board.closed, [1], "the Bluetooth session is over")
        XCTAssertFalse(controller.canStart, "no new start while that session runs")
        start(controller)
        XCTAssertEqual(hub.recorded(.start).count, 1)

        controller.cancel()
        try await eventually { self.outcome(controller) != nil }
        XCTAssertEqual(outcome(controller)?.session.state, .cancelled)
        XCTAssertEqual(hub.recorded(.cancel).map(\.sessionID), [EnrollmentFixtures.otherSessionID], "this device's own session, by its id")
        XCTAssertEqual(outcome(controller)?.cleanup?.board, .notNeeded)
        XCTAssertTrue(board.cancels.isEmpty)
        XCTAssertTrue(controller.canStart, "after the explicit cancel a new run may start")
    }

    func testAPostWithoutAnAnswerIsNotRepeatedByItselfAndBlocksANewStart() async throws {
        hub.scriptStart(.failure(.unreachable("timeout")))
        let controller = makeController()
        start(controller)
        try await eventually { controller.phase == .hubUncertain }
        try await settle()
        XCTAssertEqual(hub.recorded(.start).count, 1, "no second POST on its own")
        XCTAssertTrue(hub.recorded(.status).isEmpty)
        XCTAssertTrue(board.starts.isEmpty, "and nothing for the board")
        XCTAssertTrue(controller.isBusy)
        XCTAssertFalse(controller.canStart, "a duplicate start is blocked")
        start(controller)
        try await settle()
        XCTAssertEqual(hub.recorded(.start).count, 1)
        XCTAssertEqual(provider.opens.count, 1)

        // The tester asks again: the same EUI-64 and the same PSKd, accepted this time.
        hub.scriptStart(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        hub.scriptStatus(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        controller.askHubAgain()
        try await eventually { self.isJoining(controller) }
        let posts = hub.recorded(.start)
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts[0].pskd, posts[1].pskd, "the original PSKd, not a new one")
        XCTAssertEqual(posts[0].eui64, posts[1].eui64)
        XCTAssertEqual(board.starts.map(\.pskd), [posts[0].pskd!])
        controller.leave()
    }

    func testAskingAgainFindsASessionWhosePSKdIsNotCertainAndDeliversNothing() async throws {
        hub.scriptStart(.failure(.badResponse("session")))
        let controller = makeController()
        start(controller)
        try await eventually { controller.phase == .hubUncertain }
        let existing = EnrollmentFixtures.session(.waitingForHeartbeat)
        hub.scriptStart(.failure(.enrollmentInProgress(ownSession: existing)))
        hub.scriptStatus(.success(existing))
        controller.askHubAgain()
        try await eventually { if case .earlierHubSession = controller.phase { true } else { false } }
        try await settle()
        XCTAssertTrue(board.starts.isEmpty)
        controller.leave()
    }

    func testCancellingAnUncertainPostSaysThatNothingCouldBeCancelled() async throws {
        hub.scriptStart(.failure(.unreachable("timeout")))
        let controller = makeController()
        start(controller)
        try await eventually { controller.phase == .hubUncertain }
        controller.cancel()
        try await eventually { self.failure(controller) != nil }
        XCTAssertEqual(failure(controller), .stopped(.init(hub: .unknownSession, board: .notNeeded)), "not hidden: a session may exist on the hub")
        XCTAssertTrue(hub.recorded(.cancel).isEmpty, "no session id, no DELETE")
        XCTAssertTrue(board.cancels.isEmpty)
        try await eventually { self.board.closed == [1] }
    }

    func testAHubThatCanNoLongerBeAskedEndsTheRunAndStillCancelsTheBoard() async throws {
        let controller = makeController()
        try await startedAndAccepted(controller)
        hub.scriptStatus(.failure(.unauthorized))
        try await eventually { self.failure(controller) != nil }
        XCTAssertEqual(failure(controller), .hub(.unauthorized, board: .taken))
        XCTAssertEqual(board.cancels.count, 1)
        XCTAssertTrue(hub.recorded(.cancel).isEmpty, "no DELETE to a hub that refused this device")
    }

    func testAHubThatIsUnreachableForAMomentIsStillFollowed() async throws {
        let controller = makeController()
        try await startedAndAccepted(controller)
        hub.scriptStatus(.failure(.unreachable("timeout")))
        try await eventually { controller.pollProblem == .unreachable("timeout") }
        XCTAssertTrue(isJoining(controller))
        hub.scriptStatus(.success(EnrollmentFixtures.session(.heartbeatReceived)))
        try await eventually { self.outcome(controller)?.session.state == .heartbeatReceived }
        XCTAssertNil(controller.pollProblem)
        XCTAssertEqual(board.starts.count, 1)
    }

    // MARK: - Delivering

    func testALostConnectionWhileTheHubPreparesMeansAuthenticatingAgainAndCheckingTheBoardAgain() async throws {
        hub.scriptStart(.success(EnrollmentFixtures.session(.preparing)))
        hub.scriptStatus(.success(EnrollmentFixtures.session(.preparing)))
        let controller = makeController()
        start(controller)
        try await eventually { !self.hub.recorded(.status).isEmpty }
        board.disconnect()
        hub.scriptStatus(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        try await eventually { self.isJoining(controller) }
        XCTAssertEqual(provider.opens.count, 2, "authenticated again")
        XCTAssertEqual(provider.opens[1], provider.opens[0], "as the same board, with the same code")
        XCTAssertEqual(board.starts.count, 1)
        XCTAssertEqual(board.starts.first?.session, 2, "with a challenge of the new session")
        controller.leave()
    }

    func testAnotherBoardAfterAuthenticatingAgainGetsNothingAndTheHubSessionIsCancelled() async throws {
        hub.scriptStart(.success(EnrollmentFixtures.session(.preparing)))
        hub.scriptStatus(.success(EnrollmentFixtures.session(.preparing)))
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        let controller = makeController()
        start(controller)
        try await eventually { !self.hub.recorded(.status).isEmpty }
        board.disconnect()
        board.report(eui64: "00124b0001a2ffff")
        hub.scriptStatus(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        try await eventually { self.failure(controller) != nil }
        XCTAssertEqual(failure(controller), .boardProblem(.differentBoard(actual: "00124b0001a2ffff"), cleanup: .init(hub: .cancelled(EnrollmentFixtures.session(.cancelled)), board: .notNeeded)))
        XCTAssertTrue(board.starts.isEmpty, "the PSKd is not handed to another board")
        XCTAssertEqual(hub.recorded(.cancel).map(\.sessionID), [EnrollmentFixtures.sessionID])
    }

    func testAnExpiredOrInvalidChallengeIsReplacedAndTheSameRequestIsSent() async throws {
        board.scriptStart(.challengeExpired, .challengeInvalid)
        let controller = makeController()
        try await startedAndAccepted(controller)
        XCTAssertEqual(board.starts.count, 3)
        XCTAssertEqual(Set(board.starts.map(\.requestID)).count, 1, "always the one request id")
        XCTAssertEqual(Set(board.starts.map(\.pskd)).count, 1)
        XCTAssertEqual(Set(board.starts.map(\.challenge)).count, 3, "a fresh challenge each time")
        XCTAssertEqual(board.joinerStarts, 1)
        XCTAssertEqual(hub.recorded(.start).count, 1)
        controller.leave()
    }

    func testAChallengeThatKeepsFailingEndsTheRunAndCancelsTheHubSession() async throws {
        board.scriptStart(.challengeExpired, .challengeExpired, .challengeExpired, .challengeExpired)
        hub.scriptStart(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        hub.scriptStatus(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        let controller = makeController()
        start(controller)
        try await eventually { self.failure(controller) != nil }
        guard case let .boardRefused(code, cleanup) = failure(controller) else { return XCTFail("\(controller.phase)") }
        XCTAssertEqual(code, .challengeExpired)
        XCTAssertEqual(cleanup.hub, .cancelled(EnrollmentFixtures.session(.cancelled)))
        XCTAssertEqual(board.starts.count, 3, "bounded")
        XCTAssertEqual(board.joinerStarts, 0)
    }

    func testABusyBoardOrARefusedStartCancelsTheHubSessionAndStartsNothing() async throws {
        let cases: [(PowerBaseBLECode, (Controller.Failure) -> Bool)] = [
            (.busy, { if case .boardProblem(.busy, _) = $0 { true } else { false } }),
            (.notWaiting, { if case .boardProblem(.notWaiting, _) = $0 { true } else { false } }),
            (.closed, { if case .boardProblem(.closed, _) = $0 { true } else { false } }),
            (.unavailable, { if case .boardProblem(.unavailable, _) = $0 { true } else { false } }),
            (.wrongTarget, { if case .boardRefused(.wrongTarget, _) = $0 { true } else { false } }),
            (.invalidPSKd, { if case .boardRefused(.invalidPSKd, _) = $0 { true } else { false } }),
            (.malformed, { if case .boardRefused(.malformed, _) = $0 { true } else { false } }),
            (.unsupportedVersion, { if case .boardRefused(.unsupportedVersion, _) = $0 { true } else { false } }),
            (.internalError, { if case .boardRefused(.internalError, _) = $0 { true } else { false } }),
        ]
        for (code, matches) in cases {
            let hub = FakeEnrollmentHub()
            self.hub = hub
            let board = FakeBoard(log: log)
            self.board = board
            provider = FakeBLEBoardProvider(board: board, log: log)
            board.scriptStart(code)
            hub.scriptStart(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
            hub.scriptStatus(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
            hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
            let controller = makeController()
            start(controller)
            try await eventually { self.failure(controller) != nil }
            XCTAssertTrue(matches(try XCTUnwrap(failure(controller))), "\(code): \(controller.phase)")
            XCTAssertEqual(board.starts.count, 1, "\(code): not sent again")
            XCTAssertEqual(board.joinerStarts, 0)
            XCTAssertEqual(hub.recorded(.cancel).map(\.sessionID), [EnrollmentFixtures.sessionID], "\(code): this run's own hub session is cancelled")
            XCTAssertEqual(hub.recorded(.start).count, 1)
        }
    }

    func testABoardThatBecameBusyBeforeDeliveryGetsNoStart() async throws {
        hub.scriptStart(.success(EnrollmentFixtures.session(.preparing)))
        hub.scriptStatus(.success(EnrollmentFixtures.session(.preparing)))
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        let controller = makeController()
        start(controller)
        try await eventually { !self.hub.recorded(.status).isEmpty }
        board.setForeignAttemptActive()
        hub.scriptStatus(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        try await eventually { self.failure(controller) != nil }
        guard case let .boardProblem(problem, cleanup) = failure(controller) else { return XCTFail("\(controller.phase)") }
        XCTAssertEqual(problem, .busy)
        XCTAssertEqual(cleanup.board, .notNeeded, "nothing was started, so nothing is cancelled on the board")
        XCTAssertTrue(board.starts.isEmpty)
        XCTAssertTrue(board.cancels.isEmpty, "another client's attempt is never cancelled")
        XCTAssertEqual(hub.recorded(.cancel).count, 1)
    }

    // `REQUEST_CONFLICT`: see `PowerBaseEnrollmentBLEFollowUpTests`.

    // MARK: - Lost answers and lost connections

    func testAStartWhoseAnswerIsLostIsLookedUpByItsRequestIDAndNotSentAgain() async throws {
        board.loseNextStartAnswer(reachesBoard: true)
        let controller = makeController()
        try await startedAndAccepted(controller)
        XCTAssertEqual(board.starts.count, 1, "the board had it: no second pb-start")
        XCTAssertEqual(board.joinerStarts, 1)
        XCTAssertEqual(provider.opens.count, 2, "one new connection to ask")
        XCTAssertEqual(board.attemptRequestID, board.starts.first?.requestID)
        XCTAssertEqual(hub.recorded(.start).count, 1, "and no second hub session")
        board.advance(to: .running, state: .joining)
        try await eventually { controller.boardProgress == .joining }
        controller.leave()
    }

    func testAStartThatNeverReachedTheBoardIsSentAgainUnderTheSameRequestID() async throws {
        board.loseNextStartAnswer(reachesBoard: false)
        let controller = makeController()
        try await startedAndAccepted(controller)
        XCTAssertEqual(board.starts.count, 2)
        XCTAssertEqual(board.starts[0].requestID, board.starts[1].requestID, "the original request id")
        XCTAssertEqual(board.starts[0].pskd, board.starts[1].pskd, "the original PSKd")
        XCTAssertNotEqual(board.starts[0].challenge, board.starts[1].challenge, "a challenge of the new session")
        XCTAssertEqual(board.joinerStarts, 1, "one Joiner")
        XCTAssertEqual(hub.recorded(.start).count, 1)
        controller.leave()
    }

    func testAStartThatMayHaveArrivedAndCannotBeCheckedIsShownAsUncertainAndBlocksAnotherStart() async throws {
        board.loseNextStartAnswer(reachesBoard: true)
        board.holdStart()
        hub.scriptStart(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        hub.scriptStatus(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        let controller = makeController(maxReconnects: 2)
        start(controller)
        try await eventually { self.board.heldStarts == 1 }
        // The start is on its way; its answer never comes and the board can't be reached again.
        provider.alwaysFailOpens = .connectionFailed("timeout")
        board.releaseStart()
        try await eventually { if case .deliveryUncertain = controller.phase { true } else { false } }
        XCTAssertEqual(provider.opens.count, 3, "the first connection and two bounded attempts")
        try await eventually { self.hub.recorded(.status).count >= 4 }
        XCTAssertEqual(provider.opens.count, 3, "no endless reconnecting")
        XCTAssertEqual(board.starts.count, 1, "no new request id, no second start")
        XCTAssertEqual(hub.recorded(.start).count, 1, "no second POST")
        XCTAssertTrue(controller.isBusy)
        XCTAssertFalse(controller.canStart)
        XCTAssertTrue(hub.recorded(.cancel).isEmpty, "the hub session is kept: the board may be joining")

        hub.scriptStatus(.success(EnrollmentFixtures.session(.heartbeatReceived)))
        try await eventually { self.outcome(controller) != nil }
        XCTAssertEqual(outcome(controller)?.session.state, .heartbeatReceived, "the hub's word still decides")
        XCTAssertEqual(outcome(controller)?.delivery, .uncertain)
    }

    func testAStartThatWasNeverSentAndCannotBeSentEndsTheRunAndCancelsTheHubSession() async throws {
        hub.scriptStart(.success(EnrollmentFixtures.session(.preparing)))
        hub.scriptStatus(.success(EnrollmentFixtures.session(.preparing)))
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        let controller = makeController(maxReconnects: 2)
        start(controller)
        try await eventually { !self.hub.recorded(.status).isEmpty }
        board.disconnect()
        provider.alwaysFailOpens = .connectionFailed("timeout")
        hub.scriptStatus(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        try await eventually { self.failure(controller) != nil }
        XCTAssertEqual(failure(controller), .boardUnreachable(cleanup: .init(hub: .cancelled(EnrollmentFixtures.session(.cancelled)), board: .notNeeded)))
        XCTAssertEqual(provider.opens.count, 3)
        XCTAssertTrue(board.starts.isEmpty)
    }

    func testAnAuthenticationRefusedOnReconnectIsNeverTriedAgain() async throws {
        hub.scriptStart(.success(EnrollmentFixtures.session(.preparing)))
        hub.scriptStatus(.success(EnrollmentFixtures.session(.preparing)))
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        let controller = makeController()
        start(controller)
        try await eventually { !self.hub.recorded(.status).isEmpty }
        board.disconnect()
        provider.alwaysFailOpens = .client(.authenticationFailed)
        hub.scriptStatus(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        try await eventually { self.failure(controller) != nil }
        guard case let .boardProblem(problem, _) = failure(controller) else { return XCTFail("\(controller.phase)") }
        XCTAssertEqual(problem, .authenticationFailed)
        XCTAssertEqual(provider.opens.count, 2, "one refused handshake, not three")
    }

    func testADisconnectRightAfterAcceptedIsNotAFailureAndTheOriginalRequestIsLookedUp() async throws {
        let controller = makeController()
        try await startedAndAccepted(controller)
        board.disconnect()
        board.advance(to: .running, state: .attaching)
        try await eventually { controller.boardProgress == .attaching }
        XCTAssertEqual(provider.opens.count, 2, "authenticated again to ask")
        XCTAssertTrue(isJoining(controller), "a dropped connection does not end the run")
        XCTAssertEqual(board.starts.count, 1, "and does not start anything")
        XCTAssertEqual(hub.recorded(.start).count, 1)
        XCTAssertTrue(board.cancels.isEmpty)
        controller.leave()
    }

    func testABoardThatShutBluetoothDownAfterEnrollingIsNeitherSuccessNorFailure() async throws {
        let controller = makeController(maxReconnects: 2)
        try await startedAndAccepted(controller)
        // The board enrolls and its Bluetooth is gone before the app hears "enrolled".
        board.disconnect()
        provider.alwaysFailOpens = .connectionFailed("timeout")
        try await eventually { controller.boardProgress == .unreachable }
        XCTAssertEqual(provider.opens.count, 3, "bounded reconnects")
        try await settle()
        XCTAssertEqual(provider.opens.count, 3)
        XCTAssertTrue(isJoining(controller), "still waiting for the hub")
        XCTAssertTrue(hub.recorded(.cancel).isEmpty)
        hub.scriptStatus(.success(EnrollmentFixtures.session(.heartbeatReceived)))
        try await eventually { self.outcome(controller) != nil }
        XCTAssertEqual(outcome(controller)?.session.state, .heartbeatReceived)
        XCTAssertEqual(outcome(controller)?.boardProgress, .unreachable)
    }

    func testReconnectingStopsOnceTheHubIsFinal() async throws {
        let controller = makeController(maxReconnects: 50)
        try await startedAndAccepted(controller)
        board.disconnect()
        provider.alwaysFailOpens = .connectionFailed("timeout")
        hub.scriptStatus(.success(EnrollmentFixtures.session(.expired)))
        try await eventually { self.outcome(controller) != nil }
        try await settle()
        let opens = provider.opens.count
        try await settle()
        XCTAssertEqual(provider.opens.count, opens, "no reconnect after the hub's final state")
    }

    func testAFailedBoardAttemptEndsTheRunAndCancelsTheHubSession() async throws {
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        let controller = makeController()
        try await startedAndAccepted(controller)
        board.advance(to: .failed, state: .waiting, result: 8)
        try await eventually { self.failure(controller) != nil }
        guard case let .boardAttemptFailed(result, cleanup) = failure(controller) else { return XCTFail("\(controller.phase)") }
        XCTAssertEqual(result, 8, "joiner_security")
        XCTAssertEqual(cleanup.hub, .cancelled(EnrollmentFixtures.session(.cancelled)))
        XCTAssertEqual(cleanup.board, .nothingToCancel, "NO_SUCH_ATTEMPT: the attempt had ended")
        XCTAssertEqual(hub.recorded(.cancel).count, 1)
    }

    func testAHeartbeatThatWinsTheRaceAgainstACleanUpIsShownAsTheHubSaysIt() async throws {
        hub.scriptCancel(.failure(.sessionAlreadyFinal(EnrollmentFixtures.session(.heartbeatReceived))))
        let controller = makeController()
        try await startedAndAccepted(controller)
        board.advance(to: .failed, state: .waiting, result: 15)
        try await eventually { self.outcome(controller) != nil }
        XCTAssertEqual(outcome(controller)?.session.state, .heartbeatReceived, "the hub's final state, not the app's guess")
    }

    func testABoardThatForgotTheRequestIsShownAndTheHubIsStillFollowed() async throws {
        let controller = makeController()
        try await startedAndAccepted(controller)
        board.forgetAttempt()
        try await eventually { controller.boardProgress == .forgotten }
        XCTAssertTrue(isJoining(controller))
        XCTAssertEqual(board.starts.count, 1, "never started again on its own")
        controller.leave()
    }

    // MARK: - Cancel

    func testCancelAsksTheBoardByRequestIDAndTheHubBySessionID() async throws {
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled, joinerEntry: "removing")))
        let controller = makeController()
        try await startedAndAccepted(controller)
        controller.cancel()
        controller.cancel()
        XCTAssertEqual(controller.phase, .cancelling)
        try await eventually { self.outcome(controller) != nil }
        XCTAssertEqual(outcome(controller)?.session.state, .cancelled)
        XCTAssertEqual(outcome(controller)?.cleanup?.board, .taken)
        XCTAssertEqual(board.cancels.count, 1, "a second tap sends nothing")
        XCTAssertEqual(board.cancels.first?.requestID, board.starts.first?.requestID, "this run's own request id")
        XCTAssertEqual(board.cancels.first?.target, EnrollmentFixtures.eui64)
        let delete = try XCTUnwrap(hub.recorded(.cancel).first)
        XCTAssertEqual(hub.recorded(.cancel).count, 1)
        XCTAssertEqual(delete.sessionID, EnrollmentFixtures.sessionID, "this run's own session")
        XCTAssertEqual(delete.baseURL, EnrollmentFixtures.urlA)
        XCTAssertEqual(delete.token, "token-A")
        XCTAssertFalse(controller.isBusy)

        let polls = hub.recorded(.status).count
        try await settle()
        XCTAssertEqual(hub.recorded(.status).count, polls)
        XCTAssertEqual(board.starts.count, 1)
    }

    func testACancelThatCannotReachTheBoardStillCancelsTheHubAndSaysSo() async throws {
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        let controller = makeController()
        try await startedAndAccepted(controller)
        board.disconnect()
        provider.alwaysFailOpens = .connectionFailed("timeout")
        controller.cancel()
        try await eventually { self.outcome(controller) != nil }
        XCTAssertEqual(outcome(controller)?.session.state, .cancelled)
        XCTAssertEqual(outcome(controller)?.cleanup?.board, .notDelivered, "not hidden")
        XCTAssertEqual(hub.recorded(.cancel).count, 1)
    }

    func testACancelWithoutASessionMakesOneMoreConnectionForIt() async throws {
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        let controller = makeController()
        try await startedAndAccepted(controller)
        board.failNextCancel(.requestFailed(.timeout))
        controller.cancel()
        try await eventually { self.outcome(controller) != nil }
        // The first cancel got no answer; one new session; the second one reaches the board.
        XCTAssertEqual(board.cancels.count, 2)
        XCTAssertEqual(Set(board.cancels.map(\.requestID)).count, 1)
        XCTAssertEqual(provider.opens.count, 2)
    }

    func testACancelThatCannotReachTheHubStillCancelsTheBoardAndKeepsFollowingTheSession() async throws {
        hub.scriptCancel(.failure(.unreachable("timeout")))
        let controller = makeController()
        try await startedAndAccepted(controller)
        controller.cancel()
        try await eventually { if case .earlierHubSession = controller.phase { true } else { false } }
        XCTAssertEqual(board.cancels.count, 1, "the board was asked whatever happened at the hub")
        XCTAssertEqual(controller.pollProblem, nil, "the session answers again")
        XCTAssertTrue(controller.canCancel, "and can be cancelled again")
        XCTAssertFalse(controller.canStart)

        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        controller.cancel()
        try await eventually { self.outcome(controller) != nil }
        XCTAssertEqual(outcome(controller)?.session.state, .cancelled)
        XCTAssertEqual(hub.recorded(.cancel).count, 2)
        XCTAssertEqual(board.cancels.count, 1, "the board is not asked twice")
        XCTAssertEqual(board.starts.count, 1)
    }

    func testCancelLosingTheRaceShowsTheHubsFinalState() async throws {
        hub.scriptCancel(.failure(.sessionAlreadyFinal(EnrollmentFixtures.session(.heartbeatReceived))))
        let controller = makeController()
        try await startedAndAccepted(controller)
        board.advance(to: .enrolled, state: .enrolled, result: 17)
        try await eventually { controller.boardProgress == .enrolled }
        provider.alwaysFailOpens = .connectionFailed("timeout")
        controller.cancel()
        try await eventually { self.outcome(controller) != nil }
        XCTAssertEqual(outcome(controller)?.session.state, .heartbeatReceived, "the hub's word, not the tap")
        XCTAssertEqual(outcome(controller)?.cleanup?.board, .notDelivered, "the enrolled board's Bluetooth is gone; nothing of it was touched")
    }

    func testCancelWhileAuthenticatingSendsNothingToTheHub() async throws {
        provider.holdsOpens = true
        let controller = makeController()
        start(controller)
        try await eventually { self.provider.heldCount == 1 }
        controller.cancel()
        provider.releaseHeld()
        try await eventually { self.failure(controller) != nil }
        XCTAssertEqual(failure(controller), .stopped(.init(hub: .notNeeded, board: .notNeeded)))
        try await settle()
        XCTAssertTrue(hub.recorded.isEmpty)
        XCTAssertEqual(board.closed, [1], "the session that arrived late is closed")
        XCTAssertEqual(board.statusCalls, 0)
    }

    // MARK: - Leaving, another source, late answers

    func testLeavingCleansUpOnTheOriginalHubAndBoardAndReportsIt() async throws {
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        let controller = makeController()
        try await startedAndAccepted(controller)
        controller.leave()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNil(controller.boardProgress)
        try await eventually { self.reports.count == 1 }
        XCTAssertEqual(reports.first?.eui64, EnrollmentFixtures.eui64)
        XCTAssertEqual(reports.first?.cleanup, .init(hub: .cancelled(EnrollmentFixtures.session(.cancelled)), board: .taken))
        XCTAssertEqual(board.cancels.map(\.requestID), board.starts.map(\.requestID))
        let delete = try XCTUnwrap(hub.recorded(.cancel).first)
        XCTAssertEqual(delete.baseURL, EnrollmentFixtures.urlA)
        XCTAssertEqual(delete.token, "token-A")
        XCTAssertEqual(delete.sessionID, EnrollmentFixtures.sessionID)

        let polls = hub.recorded(.status).count
        let statusCalls = board.statusCalls
        try await settle()
        XCTAssertEqual(hub.recorded(.status).count, polls, "no poll after leaving")
        XCTAssertEqual(board.statusCalls, statusCalls)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertGreaterThanOrEqual(provider.scanStops, 1)
    }

    func testLeavingWithALostConnectionDoesNotReconnectAndReportsThatTheBoardWasNotReached() async throws {
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        let controller = makeController(maxReconnects: 0)
        try await startedAndAccepted(controller)
        board.disconnect()
        try await eventually { controller.boardProgress == .unreachable }
        let opens = provider.opens.count
        controller.leave()
        try await eventually { self.reports.count == 1 }
        XCTAssertEqual(reports.first?.cleanup.board, .notDelivered)
        XCTAssertEqual(provider.opens.count, opens, "no setup code is kept for a connection after leaving")
        XCTAssertEqual(hub.recorded(.cancel).count, 1, "the hub side is still cleaned up")
    }

    func testAViewThatDisappearsAndComesRightBackIsNotAnExit() async throws {
        let controller = makeController(leaveGrace: .milliseconds(150))
        try await startedAndAccepted(controller)
        controller.screenDidDisappear()
        controller.screenDidAppear()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(isJoining(controller), "a rebuilt view keeps its run")
        XCTAssertTrue(hub.recorded(.cancel).isEmpty)
        XCTAssertTrue(board.cancels.isEmpty)

        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        controller.screenDidDisappear()
        try await eventually { controller.phase == .idle }
        try await eventually { self.reports.count == 1 }
        XCTAssertEqual(hub.recorded(.cancel).count, 1, "a real exit cleans up")
        XCTAssertEqual(board.cancels.count, 1)
    }

    func testAPostAnswerThatArrivesAfterLeavingIsNotShownAndItsSessionIsCancelled() async throws {
        hub.holdStarts()
        hub.scriptStart(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        hub.scriptStatus(.success(EnrollmentFixtures.session(.heartbeatReceived)))
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        let controller = makeController()
        start(controller)
        try await eventually { self.hub.heldCount == 1 }
        controller.leave()
        XCTAssertEqual(controller.phase, .idle)
        hub.releaseHeld()
        try await eventually { self.reports.count == 1 }
        XCTAssertEqual(controller.phase, .idle, "the late answer never reaches the next screen")
        XCTAssertEqual(hub.recorded(.cancel).map(\.sessionID), [EnrollmentFixtures.sessionID], "the session nobody follows is cancelled on its hub")
        XCTAssertEqual(reports.first?.cleanup.board, .notNeeded)
        try await settle()
        XCTAssertTrue(board.starts.isEmpty, "and nothing is delivered for it")
        XCTAssertTrue(hub.recorded(.status).isEmpty)
    }

    func testAStartAnswerThatArrivesAfterLeavingIsFollowedByTheCancelNotTheOtherWayRound() async throws {
        board.holdStart()
        hub.scriptStart(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        hub.scriptStatus(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        let controller = makeController()
        start(controller)
        try await eventually { self.board.heldStarts == 1 }
        controller.leave()
        try await settle()
        XCTAssertTrue(board.cancels.isEmpty, "the cancel waits for the start under way")
        board.releaseStart()
        try await eventually { self.reports.count == 1 }
        XCTAssertEqual(reports.first?.cleanup.board, .taken, "the attempt the late start created is cancelled")
        XCTAssertEqual(board.cancels.map(\.requestID), board.starts.map(\.requestID))
        XCTAssertEqual(controller.phase, .idle)
    }

    func testAnotherHubEndsTheRunCleansUpOnTheOriginalOneAndIgnoresWhatComesLater() async throws {
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        let controller = makeController()
        try await startedAndAccepted(controller)
        hub.scriptStatus(.success(EnrollmentFixtures.session(.heartbeatReceived)))
        controller.targetDidChange(EnrollmentFixtures.pairedTarget(hubID: EnrollmentFixtures.hubB, url: EnrollmentFixtures.urlB))
        XCTAssertEqual(controller.phase, .failed(.sourceChanged))
        try await eventually { self.reports.count == 1 }
        XCTAssertEqual(controller.phase, .failed(.sourceChanged), "a late heartbeat_received is not shown for the new source")
        let delete = try XCTUnwrap(hub.recorded(.cancel).first)
        XCTAssertEqual(delete.baseURL, EnrollmentFixtures.urlA)
        XCTAssertEqual(delete.token, "token-A", "the original hub's credential")
        XCTAssertEqual(board.cancels.count, 1)
        try await settle()
        XCTAssertFalse(hub.recorded.contains { $0.baseURL == EnrollmentFixtures.urlB || $0.token == "token-B" }, "nothing goes to the other hub")
    }

    func testSimulatedDataEndsTheRunTheSameWay() async throws {
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        let controller = makeController()
        try await startedAndAccepted(controller)
        controller.targetDidChange(.init(hubID: nil, baseURL: nil, isSimulated: true, isPaired: false))
        XCTAssertEqual(controller.phase, .failed(.sourceChanged))
        try await eventually { self.reports.count == 1 }
        XCTAssertEqual(hub.recorded(.cancel).first?.baseURL, EnrollmentFixtures.urlA)
        XCTAssertEqual(board.cancels.count, 1)
    }

    func testTheSameHubAtANewAddressCarriesOnThereWithTheSamePin() async throws {
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        let controller = makeController()
        try await startedAndAccepted(controller)
        controller.targetDidChange(EnrollmentFixtures.pairedTarget(url: EnrollmentFixtures.urlAMoved))
        let before = hub.recorded(.status).count
        try await eventually { self.hub.recorded(.status).count > before + 1 }
        let latest = try XCTUnwrap(hub.recorded(.status).last)
        XCTAssertEqual(latest.baseURL, EnrollmentFixtures.urlAMoved)
        XCTAssertEqual(latest.pinnedCertificate, String(repeating: "c", count: 64), "a new address is no reason to trust another certificate")
        XCTAssertEqual(latest.token, "token-A")
        XCTAssertTrue(isJoining(controller))
        XCTAssertEqual(hub.recorded(.start).count, 1)
        XCTAssertEqual(board.starts.count, 1)

        controller.cancel()
        try await eventually { self.outcome(controller) != nil }
        XCTAssertEqual(hub.recorded(.cancel).first?.baseURL, EnrollmentFixtures.urlAMoved)
        XCTAssertEqual(hub.recorded(.cancel).first?.pinnedCertificate, String(repeating: "c", count: 64))
    }

    func testAnotherHubClearsThePreviousHubsResult() async throws {
        hub.scriptStart(.success(EnrollmentFixtures.session(.expired)))
        let controller = makeController()
        start(controller)
        try await eventually { self.outcome(controller) != nil }
        controller.targetDidChange(EnrollmentFixtures.pairedTarget(hubID: EnrollmentFixtures.hubB, url: EnrollmentFixtures.urlB))
        XCTAssertEqual(controller.phase, .idle)
    }

    // MARK: - Background

    func testTheBackgroundSendsNoBluetoothCommandAndComingBackAsksTheHubFirst() async throws {
        hub.scriptStart(.success(EnrollmentFixtures.session(.preparing)))
        hub.scriptStatus(.success(EnrollmentFixtures.session(.preparing)))
        let controller = makeController()
        start(controller)
        try await eventually { !self.hub.recorded(.status).isEmpty }

        controller.sceneDidEnterBackground()
        hub.scriptStatus(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        try await settle()
        let hubRequests = hub.recorded.count
        let boardRequests = board.statusCalls
        try await settle()
        XCTAssertEqual(hub.recorded.count, hubRequests, "nothing is asked while in the background")
        XCTAssertEqual(board.statusCalls, boardRequests)
        XCTAssertTrue(board.starts.isEmpty)
        XCTAssertTrue(controller.isBusy, "the run is kept, not cancelled")
        XCTAssertTrue(hub.recorded(.cancel).isEmpty)

        log.clear()
        controller.sceneDidBecomeActive()
        try await eventually { self.isJoining(controller) }
        let events = log.all
        XCTAssertEqual(events.first, "hub GET", "the hub is asked before anything goes to the board")
        XCTAssertEqual(events.filter { $0 == "board start" }.count, 1)
        XCTAssertEqual(hub.recorded(.start).count, 1, "coming back is not a new start")
        XCTAssertEqual(board.starts.count, 1)
        XCTAssertEqual(provider.opens.count, 1)
        controller.leave()
    }

    func testGoingToTheBackgroundBetweenTheChallengeAndTheStartSendsNoStartUntilTheAppIsBack() async throws {
        board.holdChallenges()
        hub.scriptStart(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        hub.scriptStatus(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        let controller = makeController()
        start(controller)
        // The challenge request is on its way when the app goes to the background.
        try await eventually { self.board.heldChallengeRequests == 1 }
        controller.sceneDidEnterBackground()
        board.releaseChallenges()
        try await settle()
        XCTAssertEqual(board.challengeRequests, 1, "that one request was already out")
        XCTAssertTrue(board.starts.isEmpty, "but the start is a new command: not sent in the background")
        XCTAssertTrue(controller.isBusy)

        log.clear()
        controller.sceneDidBecomeActive()
        try await eventually { self.isJoining(controller) }
        XCTAssertEqual(log.all.first, "hub GET", "hub first")
        XCTAssertEqual(board.starts.count, 1)
        XCTAssertEqual(board.challengeRequests, 2, "with a fresh challenge, not the one from before the background")
        XCTAssertNotEqual(board.starts.first?.challenge, Data(repeating: 1, count: 16))
        XCTAssertEqual(hub.recorded(.start).count, 1)
        controller.leave()
    }

    func testComingBackAfterAcceptedAsksTheHubBeforeTheBoardAndStartsNothing() async throws {
        let controller = makeController()
        try await startedAndAccepted(controller)
        controller.sceneDidEnterBackground()
        try await settle()
        // The connection did not survive the background.
        board.disconnect()
        board.advance(to: .running, state: .attaching)
        let statusCalls = board.statusCalls
        let opens = provider.opens.count
        try await settle()
        XCTAssertEqual(board.statusCalls, statusCalls, "no Bluetooth command in the background")
        XCTAssertEqual(provider.opens.count, opens)

        log.clear()
        controller.sceneDidBecomeActive()
        try await eventually { controller.boardProgress == .attaching }
        let events = log.all
        let firstBoard = try XCTUnwrap(events.firstIndex { $0.hasPrefix("board") })
        XCTAssertTrue(events[..<firstBoard].contains("hub GET"), "hub first: \(events.prefix(4))")
        XCTAssertEqual(board.starts.count, 1, "the original request is looked up, nothing is started")
        XCTAssertEqual(hub.recorded(.start).count, 1)
        controller.leave()
    }

    func testAHubThatFinishedDuringTheBackgroundEndsTheRunAndTheBoardIsLeftAlone() async throws {
        let controller = makeController()
        try await startedAndAccepted(controller)
        controller.sceneDidEnterBackground()
        try await settle()
        board.disconnect()
        hub.scriptStatus(.success(EnrollmentFixtures.session(.heartbeatReceived)))
        controller.sceneDidBecomeActive()
        try await eventually { self.outcome(controller) != nil }
        XCTAssertEqual(outcome(controller)?.session.state, .heartbeatReceived)
        XCTAssertEqual(board.starts.count, 1)
        XCTAssertTrue(board.cancels.isEmpty)
        try await settle()
        let opens = provider.opens.count
        let statusCalls = board.statusCalls
        try await settle()
        XCTAssertEqual(provider.opens.count, opens, "no reconnect once the hub is final")
        XCTAssertEqual(board.statusCalls, statusCalls, "and no further question to the board")
    }

    // MARK: - Scanning

    func testScanningStatesAndThatARunStopsTheScan() async throws {
        provider.boards = []
        let controller = makeController()
        XCTAssertFalse(controller.isScanning)
        controller.startScanning()
        XCTAssertTrue(controller.isScanning)
        XCTAssertFalse(controller.foundNothingSoFar, "still searching")
        try await eventually { controller.foundNothingSoFar }
        XCTAssertTrue(controller.isScanning, "searching goes on")

        provider.boards = [PowerBaseBLEDiscoveredBoard(id: FakeBLEBoardProvider.boardID, name: "POGO-PB-00124B0001A2B3C4", advertisedEUI64: EnrollmentFixtures.eui64, rssi: -60)]
        provider.onChange?()
        XCTAssertEqual(controller.boards.count, 1)
        XCTAssertFalse(controller.foundNothingSoFar)

        provider.set(availability: .poweredOff)
        XCTAssertEqual(controller.availability, .poweredOff)
        XCTAssertFalse(controller.canStart)
        provider.set(availability: .poweredOn)

        hub.scriptStart(.success(EnrollmentFixtures.session(.cancelled)))
        let stops = provider.scanStops
        start(controller)
        XCTAssertFalse(controller.isScanning)
        XCTAssertGreaterThan(provider.scanStops, stops)
        let scans = provider.scanStarts
        controller.startScanning()
        XCTAssertEqual(provider.scanStarts, scans, "no scanning during a run")
        try await eventually { self.outcome(controller) != nil }
    }

    // MARK: - Secrets

    func testNoStateTheScreenCanShowContainsTheSetupCodeOrThePSKd() async throws {
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        let controller = makeController()
        var seen: [String] = []
        hub.scriptStart(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        hub.scriptStatus(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        start(controller)
        seen.append(String(reflecting: controller.phase))
        try await eventually { self.isJoining(controller) }
        seen.append(String(reflecting: controller.phase) + String(reflecting: controller.boardProgress))
        controller.cancel()
        try await eventually { self.outcome(controller) != nil }
        seen.append(String(reflecting: controller.phase))

        provider.openErrors = [.client(.authenticationFailed)]
        start(controller)
        try await eventually { self.failure(controller) != nil }
        seen.append(String(reflecting: controller.phase))

        let pskd = try XCTUnwrap(hub.recorded(.start).first?.pskd)
        for text in seen {
            XCTAssertFalse(text.contains(EnrollmentFixtures.setupCode), text)
            XCTAssertFalse(text.contains(pskd), text)
            XCTAssertFalse(text.contains("token-A"), text)
        }
        // And nothing of it was written anywhere the app keeps things.
        let defaults = UserDefaults.standard.dictionaryRepresentation().description
        XCTAssertFalse(defaults.contains(EnrollmentFixtures.setupCode))
        XCTAssertFalse(defaults.contains(pskd))
    }
}

/// The request/answer rules of the real Bluetooth side (`PowerBaseEnrollmentBLEExchanger`), driven
/// by hand instead of by CoreBluetooth: what a late, repeated or misplaced callback may do.
@MainActor
final class PowerBaseEnrollmentBLEExchangerTests: XCTestCase {
    private final class FakeIO: PowerBaseBLEEndpointIO {
        var maximumWriteLength = 512
        var writes: [(endpoint: PowerBaseBLEProtocol.Endpoint, payload: Data)] = []
        var reads: [PowerBaseBLEProtocol.Endpoint] = []

        func write(_ payload: Data, to endpoint: PowerBaseBLEProtocol.Endpoint) { writes.append((endpoint, payload)) }
        func read(_ endpoint: PowerBaseBLEProtocol.Endpoint) { reads.append(endpoint) }
    }

    private var io: FakeIO!
    private var closes = 0

    override func setUp() async throws {
        io = FakeIO()
        closes = 0
    }

    private func makeExchanger(timeout: Duration = .seconds(5)) -> PowerBaseEnrollmentBLEExchanger {
        PowerBaseEnrollmentBLEExchanger(io: io, exchangeTimeout: timeout, handshakeTimeout: timeout) { [weak self] in self?.closes += 1 }
    }

    /// Starts an exchange and waits until its write has gone out.
    private func begin(
        _ exchanger: PowerBaseEnrollmentBLEExchanger, _ endpoint: PowerBaseBLEProtocol.Endpoint, _ payload: Data
    ) async throws -> Task<Data, Error> {
        let writes = io.writes.count
        let task = Task { try await exchanger.exchange(endpoint: endpoint, payload: payload) }
        try await eventually { self.io.writes.count == writes + 1 }
        return task
    }

    private func error(of task: Task<Data, Error>) async -> PowerBaseBLELinkError? {
        do {
            _ = try await task.value
            return nil
        } catch {
            return error as? PowerBaseBLELinkError
        }
    }

    func testARequestIsOneWholeWriteThenOneReadOfTheSameEndpoint() async throws {
        let exchanger = makeExchanger()
        // The size of Security 2's first message: far more than one ATT packet.
        let request = Data((0..<414).map { UInt8(truncatingIfNeeded: $0) })
        let task = try await begin(exchanger, .session, request)
        XCTAssertEqual(io.writes.count, 1, "never split over several writes")
        XCTAssertEqual(io.writes.first?.payload, request)
        XCTAssertEqual(io.writes.first?.endpoint, .session)
        XCTAssertTrue(io.reads.isEmpty, "no read before the write is confirmed")

        exchanger.didWrite(.session, .written)
        XCTAssertEqual(io.reads, [.session])
        let answer = Data(repeating: 7, count: 416)
        exchanger.didRead(.session, value: answer)
        let received = try await task.value
        XCTAssertEqual(received, answer)
        XCTAssertTrue(exchanger.isOpen)
        XCTAssertEqual(closes, 0)
    }

    func testAMessageThatDoesNotFitIsRefusedAndNothingIsWritten() async throws {
        let exchanger = makeExchanger()
        for (limit, length) in [(512, 513), (182, 414), (512, 0)] {
            io.maximumWriteLength = limit
            do {
                _ = try await exchanger.exchange(endpoint: .session, payload: Data(count: length))
                XCTFail("accepted \(length) bytes with a limit of \(limit)")
            } catch {
                XCTAssertEqual(error as? PowerBaseBLELinkError, .messageTooLong(length: length, limit: limit))
            }
        }
        io.maximumWriteLength = 4096
        do {
            _ = try await exchanger.exchange(endpoint: .session, payload: Data(count: 513))
            XCTFail("more than the board's attribute limit")
        } catch {
            XCTAssertEqual(error as? PowerBaseBLELinkError, .messageTooLong(length: 513, limit: 512), "the board refuses values over 512 bytes")
        }
        XCTAssertTrue(io.writes.isEmpty, "a clear error instead of a partial request")
        XCTAssertTrue(exchanger.isOpen)
    }

    func testTheBoardsRefusalOfAWriteLeavesTheConnectionUsable() async throws {
        let exchanger = makeExchanger()
        let refused = try await begin(exchanger, .session, Data([1, 2, 3]))
        exchanger.didWrite(.session, .rejected)
        let failure = await error(of: refused)
        XCTAssertEqual(failure, .rejected)
        XCTAssertTrue(io.reads.isEmpty, "a refused write is not read back")
        XCTAssertTrue(exchanger.isOpen)

        let next = try await begin(exchanger, .version, Data([4]))
        exchanger.didWrite(.version, .written)
        exchanger.didRead(.version, value: Data([9]))
        let answer = try await next.value
        XCTAssertEqual(answer, Data([9]))
    }

    func testARequestWithoutAnAnswerInTimeClosesTheConnectionAndLateCallbacksChangeNothing() async throws {
        let exchanger = makeExchanger(timeout: .milliseconds(40))
        let slow = try await begin(exchanger, .status, Data([1]))
        let failure = await error(of: slow)
        XCTAssertEqual(failure, .timeout)
        XCTAssertFalse(exchanger.isOpen)
        XCTAssertEqual(closes, 1, "the connection is ended")

        // The answer arrives after all.
        exchanger.didWrite(.status, .written)
        exchanger.didRead(.status, value: Data([5]))
        XCTAssertTrue(io.reads.isEmpty, "a late write confirmation starts no read")
        XCTAssertEqual(closes, 1)

        // Nothing more is sent on this connection, so the late answer can never be taken for a later one.
        do {
            _ = try await exchanger.exchange(endpoint: .status, payload: Data([2]))
            XCTFail("a closed exchanger sent a request")
        } catch {
            XCTAssertEqual(error as? PowerBaseBLELinkError, .disconnected)
        }
        XCTAssertEqual(io.writes.count, 1)
    }

    func testAnswersForAnotherEndpointOrAnotherStepAreIgnored() async throws {
        let exchanger = makeExchanger()
        let task = try await begin(exchanger, .start, Data([1]))
        // A stale read result for this endpoint, before the write was confirmed.
        exchanger.didRead(.start, value: Data([0xEE]))
        // Reports for endpoints nobody is waiting on.
        exchanger.didWrite(.status, .written)
        exchanger.didRead(.status, value: Data([0xEE]))
        exchanger.didWrite(.cancel, .rejected)
        XCTAssertTrue(io.reads.isEmpty)

        exchanger.didWrite(.start, .written)
        XCTAssertEqual(io.reads, [.start])
        exchanger.didRead(.cancel, value: Data([0xEE]))
        exchanger.didRead(.start, value: Data([0x42]))
        let answer = try await task.value
        XCTAssertEqual(answer, Data([0x42]), "only the read that followed this write counts")
    }

    func testRepeatedCallbacksCompleteTheRequestExactlyOnce() async throws {
        let exchanger = makeExchanger()
        let task = try await begin(exchanger, .status, Data([1]))
        exchanger.didWrite(.status, .written)
        exchanger.didWrite(.status, .written)
        exchanger.didWrite(.status, .rejected)
        XCTAssertEqual(io.reads, [.status], "one read")
        exchanger.didRead(.status, value: Data([1]))
        // A second resume of the same continuation would crash the test process.
        exchanger.didRead(.status, value: Data([2]))
        exchanger.didWrite(.status, .failed)
        exchanger.close(.disconnected)
        exchanger.close(.timeout)
        let answer = try await task.value
        XCTAssertEqual(answer, Data([1]))
        XCTAssertEqual(closes, 1, "closing twice ends the connection once")
    }

    func testADisconnectFailsTheRequestUnderWayOnce() async throws {
        let exchanger = makeExchanger()
        let task = try await begin(exchanger, .start, Data([1]))
        exchanger.didWrite(.start, .written)
        exchanger.close(.disconnected)
        exchanger.didRead(.start, value: Data([3]))
        let failure = await error(of: task)
        XCTAssertEqual(failure, .disconnected, "the answer is lost; it is not made up from a late callback")
        XCTAssertEqual(closes, 1)
    }

    func testATransportFailureOrAnOversizedAnswerClosesTheConnection() async throws {
        var exchanger = makeExchanger()
        var task = try await begin(exchanger, .status, Data([1]))
        exchanger.didWrite(.status, .failed)
        var failure = await error(of: task)
        XCTAssertEqual(failure, .failed("write"))
        XCTAssertFalse(exchanger.isOpen)

        exchanger = makeExchanger()
        task = try await begin(exchanger, .status, Data([1]))
        exchanger.didWrite(.status, .written)
        exchanger.didRead(.status, value: nil)
        failure = await error(of: task)
        XCTAssertEqual(failure, .failed("read"))
        XCTAssertFalse(exchanger.isOpen)

        exchanger = makeExchanger()
        task = try await begin(exchanger, .status, Data([1]))
        exchanger.didWrite(.status, .written)
        exchanger.didRead(.status, value: Data(count: 513))
        failure = await error(of: task)
        XCTAssertEqual(failure, .failed("read"), "longer than any value the board can hold")
        XCTAssertEqual(closes, 3)
    }

    func testOnlyOneRequestIsUnderWayAtATime() async throws {
        let exchanger = makeExchanger()
        let first = try await begin(exchanger, .status, Data([1]))
        do {
            _ = try await exchanger.exchange(endpoint: .start, payload: Data([2]))
            XCTFail("a second request went out")
        } catch {
            XCTAssertEqual(error as? PowerBaseBLELinkError, .failed("busy"))
        }
        XCTAssertEqual(io.writes.count, 1)
        exchanger.didWrite(.status, .written)
        exchanger.didRead(.status, value: Data([8]))
        let answer = try await first.value
        XCTAssertEqual(answer, Data([8]), "the first one is untouched")
    }
}

/// How the real Bluetooth side judges a board's GATT service -- without any Bluetooth.
final class PowerBaseEnrollmentBLEGATTTests: XCTestCase {
    private typealias Characteristic = (uuid: String, description: String?, properties: CBCharacteristicProperties)

    private func service(_ change: (inout [Characteristic]) -> Void = { _ in }) -> [Characteristic] {
        var characteristics: [Characteristic] = PowerBaseBLEProtocol.Endpoint.allCases.map {
            ($0.characteristicUUID, $0.rawValue, [.read, .write])
        }
        change(&characteristics)
        return characteristics
    }

    private func mismatch(_ characteristics: [Characteristic]) -> String? {
        if case let .failure(.gattMismatch(detail)) = PowerBaseEnrollmentBLEConnection.endpoints(from: characteristics) { return detail }
        return nil
    }

    func testEndpointsAreFoundByDescriptionWhateverTheOrder() throws {
        let forward = try PowerBaseEnrollmentBLEConnection.endpoints(from: service()).get()
        XCTAssertEqual(forward.count, 5)
        let reversed = service { $0.reverse() }
        let backward = try PowerBaseEnrollmentBLEConnection.endpoints(from: reversed).get()
        for endpoint in PowerBaseBLEProtocol.Endpoint.allCases {
            XCTAssertEqual(reversed[try XCTUnwrap(backward[endpoint])].description, endpoint.rawValue, "by description, not by position")
        }
        // CoreBluetooth prints UUIDs in upper case; the firmware documents them in lower case.
        XCTAssertNotNil(try? PowerBaseEnrollmentBLEConnection.endpoints(from: service { $0 = $0.map { ($0.uuid.lowercased(), $0.description, $0.properties) } }).get())
    }

    func testAMissingDuplicatedOrUnknownDescriptionIsRefused() {
        XCTAssertEqual(mismatch(service { $0.removeLast() }), "missing endpoint")
        XCTAssertEqual(mismatch(service { $0[1].description = $0[0].description }), "duplicate endpoint")
        XCTAssertEqual(mismatch(service { $0[2].description = nil }), "unknown endpoint", "no readable description")
        XCTAssertEqual(mismatch(service { $0[2].description = "" }), "unknown endpoint")
        XCTAssertEqual(mismatch(service { $0[2].description = "pb-status " }), "unknown endpoint", "exact names only")
        XCTAssertEqual(mismatch(service { $0[0].description = "my prov-session" }), "unknown endpoint", "not a substring match")
        XCTAssertEqual(mismatch(service { $0.append(("2E8AFF63-9FFB-4868-BC63-064A14069755", "pb-factory-reset", [.read, .write])) }), "unknown endpoint")
        XCTAssertEqual(mismatch([]), "missing endpoint")
    }

    func testADescriptionOnTheWrongCharacteristicOrOneThatCannotBeReadAndWrittenIsRefused() {
        XCTAssertEqual(mismatch(service {
            let first = $0[0].description
            $0[0].description = $0[1].description
            $0[1].description = first
        }), "endpoint UUID", "two descriptions swapped")
        XCTAssertEqual(mismatch(service { $0[3].properties = [.read] }), "endpoint properties")
        XCTAssertEqual(mismatch(service { $0[3].properties = [.write] }), "endpoint properties")
        XCTAssertEqual(mismatch(service { $0[3].properties = [.read, .writeWithoutResponse, .notify] }), "endpoint properties")
    }
}
#endif
