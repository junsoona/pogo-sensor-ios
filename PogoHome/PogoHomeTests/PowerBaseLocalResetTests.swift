#if DEBUG
import PowerBaseBLEKit
import XCTest
@testable import PogoHome

// "다른 허브에 연결하기": the real `PowerBaseLocalResetController` against a scripted board and a
// scripted Bluetooth provider (no Bluetooth, no hub -- the controller has no hub to talk to).
//
// The board here is the local reset of pb_ble_admission.c in miniature: one operation it
// remembers, a challenge per session used once, a window, and what it holds. The real C
// implementation is exercised by the package's `LocalResetInteropTests` and the firmware
// repository's tools/test_power_base_reenroll.c; this file is about what the APP does and does
// not send, and what it shows.
//
// Waiting is by what happened, not by time: `foregroundWaiters` says a step is waiting for the
// foreground, `unfinishedRunTasks` that every task of a run came to its end.

/// A board with a re-enrollment button, as far as the controller can see it.
nonisolated final class FakeResetBoard: @unchecked Sendable {
    struct ResetCall: Equatable {
        let session: Int
        let target: String
        let operation: Data
        let challenge: Data
    }

    enum Event: Equatable {
        case open, status, challenge, resetStatus(Data?), reset(Data), close
    }

    let eui64: PowerBaseBLEEUI64
    private let lock = NSLock()

    private var reportedEUI64: PowerBaseBLEEUI64
    private var boardCapabilities: PowerBaseBLECapabilities = [.bridgeEndpointV1, .managementV1, .releaseReceiptV1, .localResetV1]
    private var condition = PowerBaseBLELocalResetStatus.Condition.enrolled
    private var windowSeconds = 120
    private var operation: (id: Data, phase: PowerBaseBLELocalResetStatus.Phase, reason: UInt8)?
    /// What an accepted operation becomes when it is next asked about.
    private var acceptedBecomes: (phase: PowerBaseBLELocalResetStatus.Phase, reason: UInt8) = (.verified, 0)

    private var sessionCount = 0
    private var liveSession = 0
    private var challenge: (session: Int, bytes: Data)?
    private var challengeCounter: UInt8 = 0

    private var events: [Event] = []
    private var resetCalls: [ResetCall] = []
    private var executed = 0
    private var scriptedResetCodes: [PowerBaseBLECode] = []
    private var loseNextResetAnswer: Bool?
    private var resetStatusErrors: [PowerBaseBLEClientError] = []
    private var statusErrors: [PowerBaseBLEClientError] = []
    private var disconnectsAfterAccept = false

    private var holds: [String: Bool] = [:]
    private var held: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(eui64 hex: String = EnrollmentFixtures.eui64) {
        eui64 = PowerBaseBLEEUI64(hex: hex)!
        reportedEUI64 = eui64
    }

    // MARK: What the test reads

    var log: [Event] { lock.withLock { events } }
    /// Every reset command that was written to the board.
    var resets: [ResetCall] { lock.withLock { resetCalls } }
    /// How many resets the board carried out (erased).
    var executedResets: Int { lock.withLock { executed } }
    var openedSessions: Int { lock.withLock { sessionCount } }
    var challengeRequests: Int { lock.withLock { events.filter { $0 == .challenge }.count } }
    var resetStatusRequests: [Data?] {
        lock.withLock { events.compactMap { if case let .resetStatus(id) = $0 { return .some(id) } else { return nil } } }
    }
    var closes: Int { lock.withLock { events.filter { $0 == .close }.count } }
    func heldCount(_ what: String) -> Int { lock.withLock { held[what]?.count ?? 0 } }

    // MARK: What the test sets

    func report(eui64 hex: String) { lock.withLock { reportedEUI64 = PowerBaseBLEEUI64(hex: hex)! } }
    func set(capabilities: PowerBaseBLECapabilities) { lock.withLock { boardCapabilities = capabilities } }
    func set(condition: PowerBaseBLELocalResetStatus.Condition) { lock.withLock { self.condition = condition } }
    /// 0: the window is not open.
    func set(windowSeconds: Int) { lock.withLock { self.windowSeconds = windowSeconds } }
    /// What the board says about an operation it accepted, from the next question on.
    func acceptedOperationBecomes(_ phase: PowerBaseBLELocalResetStatus.Phase, reason: UInt8 = 0) {
        lock.withLock { acceptedBecomes = (phase, reason) }
    }
    /// The board finishes the operation it has: verified, and it is not enrolled any more.
    func finishOperation() {
        lock.withLock {
            guard let current = operation else { return }
            operation = (current.id, .verified, 0)
            condition = .notEnrolled
        }
    }
    /// The board restarted into an ordinary boot: no window, sessions gone; the journal stays.
    func restart() {
        lock.withLock {
            liveSession = 0
            windowSeconds = 0
        }
    }
    func scriptReset(_ codes: PowerBaseBLECode...) { lock.withLock { scriptedResetCodes.append(contentsOf: codes) } }
    /// The next reset command gets no answer and the connection is gone. `reachesBoard`: whether
    /// the board took the command before the answer was lost.
    func loseNextResetAnswer(reachesBoard: Bool) { lock.withLock { loseNextResetAnswer = reachesBoard } }
    func failResetStatus(_ errors: PowerBaseBLEClientError...) { lock.withLock { resetStatusErrors.append(contentsOf: errors) } }
    func failStatus(_ errors: PowerBaseBLEClientError...) { lock.withLock { statusErrors.append(contentsOf: errors) } }
    /// After it accepted a command the board restarts at once: every later request fails.
    func disconnectAfterAccept() { lock.withLock { disconnectsAfterAccept = true } }
    func disconnect() { lock.withLock { liveSession = 0 } }

    /// Requests of this kind ("status", "challenge", "resetStatus", "reset") get their answer only
    /// after `release`: they have left this device and the answer is under way.
    func hold(_ what: String) { lock.withLock { holds[what] = true } }

    func release(_ what: String) {
        let waiting = lock.withLock {
            holds[what] = false
            defer { held[what] = [] }
            return held[what] ?? []
        }
        waiting.forEach { $0.resume() }
    }

    fileprivate func waitWhileHeld(_ what: String) async {
        await withCheckedContinuation { continuation in
            let isHeld = lock.withLock {
                if holds[what] == true { held[what, default: []].append(continuation) }
                return holds[what] == true
            }
            if !isHeld { continuation.resume() }
        }
    }

    // MARK: Sessions

    func openSession() -> FakeResetSession {
        let index = lock.withLock {
            sessionCount += 1
            liveSession = sessionCount
            challenge = nil
            events.append(.open)
            return sessionCount
        }
        return FakeResetSession(board: self, index: index)
    }

    fileprivate var capabilities: PowerBaseBLECapabilities { lock.withLock { boardCapabilities } }

    fileprivate func close(session: Int) {
        lock.withLock {
            events.append(.close)
            if liveSession == session { liveSession = 0 }
        }
    }

    private func requireLive(_ session: Int) throws {
        guard liveSession == session else { throw PowerBaseBLEClientError.noSession }
    }

    fileprivate func status(session: Int, issueChallenge: Bool) throws -> PowerBaseBLEStatus {
        try lock.withLock {
            events.append(issueChallenge ? .challenge : .status)
            try requireLive(session)
            if !statusErrors.isEmpty {
                liveSession = 0
                throw statusErrors.removeFirst()
            }
            var issued: PowerBaseBLEChallenge?
            var flags = PowerBaseBLEStatus.Flags()
            if issueChallenge {
                challengeCounter &+= 1
                let bytes = Data(repeating: challengeCounter, count: 16)
                challenge = (session, bytes)
                issued = PowerBaseBLEChallenge(bytes: bytes, lifetimeSeconds: 60)
                flags.insert(.challengeIssued)
            }
            return PowerBaseBLEStatus(eui64: reportedEUI64, state: condition == .enrolled ? .enrolled : .waiting, flags: flags, challenge: issued)
        }
    }

    fileprivate func resetStatus(session: Int, target: PowerBaseBLEEUI64, operationID: PowerBaseBLEOperationID?) throws -> PowerBaseBLELocalResetStatus {
        try lock.withLock {
            events.append(.resetStatus(operationID?.bytes))
            try requireLive(session)
            guard boardCapabilities.contains(.localResetV1) else { throw PowerBaseBLEClientError.invalidInput("capability") }
            if !resetStatusErrors.isEmpty {
                liveSession = 0
                throw resetStatusErrors.removeFirst()
            }
            guard target == eui64 else {
                liveSession = 0
                throw PowerBaseBLEClientError.refusedByBoard(.wrongTarget)
            }
            // A queued operation is run by the board's worker between two questions.
            if let current = operation, current.phase == .queued {
                operation = (current.id, acceptedBecomes.phase, acceptedBecomes.reason)
                if acceptedBecomes.phase == .verified {
                    condition = .notEnrolled
                    executed += 1
                } else if acceptedBecomes.phase == .inProgress {
                    condition = .resetPending
                }
            }
            var phase: PowerBaseBLELocalResetStatus.Phase?
            var reason: UInt8 = 0
            if let operationID, let current = operation, current.id == operationID.bytes {
                phase = current.phase
                reason = current.reason
            }
            return PowerBaseBLELocalResetStatus(
                eui64: eui64, condition: condition, isWindowOpen: windowSeconds > 0, windowSecondsLeft: windowSeconds,
                operationPhase: phase, operationReason: reason
            )
        }
    }

    fileprivate func reset(
        session: Int, target: PowerBaseBLEEUI64, operationID: PowerBaseBLEOperationID, challenge sent: PowerBaseBLEChallenge
    ) throws -> PowerBaseBLECode {
        try lock.withLock {
            events.append(.reset(operationID.bytes))
            try requireLive(session)
            // Like the real client: a board without the capability is never sent this message.
            guard boardCapabilities.contains(.localResetV1) else { throw PowerBaseBLEClientError.invalidInput("capability") }
            resetCalls.append(ResetCall(session: session, target: target.hex, operation: operationID.bytes, challenge: sent.bytes))
            if let reaches = loseNextResetAnswer {
                loseNextResetAnswer = nil
                if reaches { _ = admit(session: session, target: target, operationID: operationID, challenge: sent) }
                liveSession = 0
                throw PowerBaseBLEClientError.requestFailed(.timeout)
            }
            if !scriptedResetCodes.isEmpty {
                challenge = nil
                return scriptedResetCodes.removeFirst()
            }
            let code = admit(session: session, target: target, operationID: operationID, challenge: sent)
            if code == .accepted, disconnectsAfterAccept { liveSession = 0 }
            return code
        }
    }

    /// pb_ble_admission.c `local_reset_admit()`, without the checks the codec already makes.
    private func admit(session: Int, target: PowerBaseBLEEUI64, operationID: PowerBaseBLEOperationID, challenge sent: PowerBaseBLEChallenge) -> PowerBaseBLECode {
        guard target == eui64 else { return .wrongTarget }
        if let current = operation {
            let same = current.id == operationID.bytes
            switch current.phase {
            case .queued, .inProgress: return same ? .duplicate : .busy
            case .verified: if same { return condition == .notEnrolled ? .duplicate : .requestConflict }
            case .notStarted: if same { return .requestConflict }
            }
        }
        guard windowSeconds > 0 else { return .windowClosed }
        let valid = challenge?.session == session && challenge?.bytes == sent.bytes
        challenge = nil
        guard valid else { return .challengeInvalid }
        switch condition {
        case .enrolled, .unreadable: break
        case .notEnrolled: return .notEnrolled
        case .remoteReleasePending, .resetPending: return .busy
        }
        operation = (operationID.bytes, .queued, 0)
        return .accepted
    }
}

nonisolated struct FakeResetSession: PowerBaseBLEBoardSession {
    let board: FakeResetBoard
    let index: Int

    func capabilities() async -> PowerBaseBLECapabilities { board.capabilities }

    func status(issueChallenge: Bool, requestID: PowerBaseBLERequestID?) async throws -> PowerBaseBLEStatus {
        await board.waitWhileHeld(issueChallenge ? "challenge" : "status")
        return try board.status(session: index, issueChallenge: issueChallenge)
    }

    /// The reset screen never starts a registration: anything written to pb-start but the reset
    /// command would fail the test that sees it.
    func start(
        target: PowerBaseBLEEUI64, requestID: PowerBaseBLERequestID, challenge: PowerBaseBLEChallenge, pskd: String,
        endpoint: PowerBaseBLEBridgeEndpoint
    ) async throws -> PowerBaseBLECode {
        XCTFail("the local reset sends no pb-start registration")
        throw PowerBaseBLEClientError.invalidInput("unexpected")
    }

    func cancel(target: PowerBaseBLEEUI64, requestID: PowerBaseBLERequestID) async throws -> PowerBaseBLECode {
        XCTFail("the local reset sends no pb-cancel")
        throw PowerBaseBLEClientError.invalidInput("unexpected")
    }

    func localResetStatus(target: PowerBaseBLEEUI64, operationID: PowerBaseBLEOperationID?) async throws -> PowerBaseBLELocalResetStatus {
        await board.waitWhileHeld("resetStatus")
        return try board.resetStatus(session: index, target: target, operationID: operationID)
    }

    func localReset(
        target: PowerBaseBLEEUI64, operationID: PowerBaseBLEOperationID, challenge: PowerBaseBLEChallenge,
        confirmation: PowerBaseBLELocalResetConfirmation
    ) async throws -> PowerBaseBLECode {
        // The command was written when this is called; `hold("reset")` keeps its answer back.
        let result = Result { try board.reset(session: index, target: target, operationID: operationID, challenge: challenge) }
        await board.waitWhileHeld("reset")
        return try result.get()
    }

    func close() async {
        board.close(session: index)
    }
}

/// Bluetooth as the controller sees it. An opening sends four commands, like the real one: the
/// connection, `proto-ver` and the two handshake messages; before each it asks the caller's permit.
@MainActor
final class FakeResetProvider: PowerBaseBLEBoardProviding {
    enum OpenStep: CaseIterable {
        case connect, version, handshake0, handshake1
    }

    struct Open: Equatable {
        let boardID: UUID
        let eui64: String
        let setupCode: String
    }

    static let boardID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    var availability = PowerBaseBLEAvailability.poweredOn
    var boards: [PowerBaseBLEDiscoveredBoard]
    var onChange: (() -> Void)?

    let board: FakeResetBoard
    private(set) var opens: [Open] = []
    private(set) var sentSteps: [OpenStep] = []
    private(set) var scanStarts = 0
    private(set) var scanStops = 0
    var openErrors: [PowerBaseBLEOpenError] = []
    /// Every opening stops after this command went out, until `releaseHeld()`.
    var holdsOpensAfter: OpenStep?
    private var held: [CheckedContinuation<Void, Never>] = []

    init(board: FakeResetBoard) {
        self.board = board
        boards = [PowerBaseBLEDiscoveredBoard(id: Self.boardID, name: "POGO-PB-" + board.eui64.hex.uppercased(), advertisedEUI64: board.eui64.hex, rssi: -52)]
    }

    var heldCount: Int { held.count }

    func releaseHeld() {
        holdsOpensAfter = nil
        let waiting = held
        held = []
        waiting.forEach { $0.resume() }
    }

    private(set) var activations = 0
    /// Searches that went on after a pause (`resumeScanning`): the boards seen so far are kept.
    private(set) var scanResumes = 0

    func set(availability: PowerBaseBLEAvailability) {
        self.availability = availability
        onChange?()
    }

    func activate() { activations += 1 }

    func startScanning() {
        scanStarts += 1
        onChange?()
    }

    func resumeScanning() {
        scanResumes += 1
        onChange?()
    }

    func stopScanning() { scanStops += 1 }

    func shutdown() {}

    func openSession(
        boardID: UUID, eui64: PowerBaseBLEEUI64, setupCode: String, permit: @escaping PowerBaseBLESendPermit
    ) async throws -> any PowerBaseBLEBoardSession {
        opens.append(Open(boardID: boardID, eui64: eui64.hex, setupCode: setupCode))
        for step in OpenStep.allCases {
            do {
                try await permit()
            } catch {
                throw PowerBaseBLEOpenError.cancelled
            }
            sentSteps.append(step)
            if holdsOpensAfter == step {
                await withCheckedContinuation { held.append($0) }
            }
        }
        if !openErrors.isEmpty { throw openErrors.removeFirst() }
        guard availability == .poweredOn else { throw PowerBaseBLEOpenError.bluetoothUnavailable(availability) }
        return board.openSession()
    }
}

@MainActor
final class PowerBaseLocalResetControllerTests: XCTestCase {
    typealias Controller = PowerBaseLocalResetController

    private var board: FakeResetBoard!
    private var provider: FakeResetProvider!

    override func setUp() {
        board = FakeResetBoard()
        provider = FakeResetProvider(board: board)
    }

    private func makeController(randomBytes: @escaping (Int) -> [UInt8]? = PowerBaseBLERandom.system, maximumPolls: Int = 20) -> Controller {
        let controller = Controller(
            provider: provider, quietScanPeriod: .milliseconds(20), pollInterval: .milliseconds(5), maximumPolls: maximumPolls, randomBytes: randomBytes
        )
        controller.activate()
        controller.startScanning()
        return controller
    }

    private func verify(_ controller: Controller, eui64: String = EnrollmentFixtures.eui64, setupCode: String = EnrollmentFixtures.setupCode) {
        controller.verify(boardID: FakeResetProvider.boardID, expectedEUI64: eui64, setupCode: setupCode)
    }

    /// Authenticated, window open, the confirmation is shown. Nothing was sent to pb-start.
    private func awaitingConfirmation(_ controller: Controller) async throws {
        verify(controller)
        try await eventually { controller.phase == .awaitingConfirmation }
        XCTAssertTrue(board.resets.isEmpty)
    }

    private func drained(_ controller: Controller) async throws {
        try await eventually { controller.unfinishedRunTasks == 0 }
    }

    // MARK: - The whole way

    func testVerifyThenConfirmThenTheBoardsVerifiedIsReady() async throws {
        let controller = makeController()
        XCTAssertTrue(controller.canVerify)
        verify(controller, eui64: EnrollmentFixtures.eui64.uppercased(), setupCode: "  " + EnrollmentFixtures.setupCode.lowercased() + "\n")
        XCTAssertEqual(controller.phase, .connecting)
        try await eventually { controller.phase == .awaitingConfirmation }

        XCTAssertEqual(provider.opens, [.init(boardID: FakeResetProvider.boardID, eui64: EnrollmentFixtures.eui64, setupCode: EnrollmentFixtures.setupCode)],
                       "one connection, with the normalised code")
        XCTAssertEqual(board.log, [.open, .status, .resetStatus(nil)], "who the board is, then what it holds -- and nothing else")
        XCTAssertEqual(controller.boardIdentifier, EnrollmentFixtures.eui64)
        XCTAssertEqual(controller.windowSecondsLeft, 120)
        XCTAssertTrue(controller.canConfirm)
        XCTAssertFalse(controller.hasUnresolvedOperation, "authenticating sent no command")
        XCTAssertEqual(board.challengeRequests, 0, "no challenge is even asked for before the confirmation")

        controller.confirmReset()
        XCTAssertEqual(controller.phase, .resetting)
        try await eventually { controller.phase == .ready(.resetVerified) }
        try await drained(controller)
        try await eventually { self.board.closes == 1 }

        XCTAssertEqual(board.resets.count, 1, "exactly one command")
        XCTAssertEqual(board.executedResets, 1)
        XCTAssertEqual(board.resets[0].target, EnrollmentFixtures.eui64)
        XCTAssertEqual(board.resets[0].challenge, Data(repeating: 1, count: 16), "with the challenge of this session, asked right before")
        let operation = board.resets[0].operation
        XCTAssertEqual(operation.count, 16)
        XCTAssertEqual(board.log, [.open, .status, .resetStatus(nil), .challenge, .reset(operation), .resetStatus(operation), .close],
                       "the board is asked about the SAME operation it was sent, and the connection ends")
        XCTAssertFalse(controller.hasUnresolvedOperation)
        XCTAssertFalse(controller.isBusy)
    }

    func testAcceptedIsNotReadyAndAnOperationInProgressIsNotVerified() async throws {
        board.acceptedOperationBecomes(.inProgress, reason: 0)
        let controller = makeController(maximumPolls: 3)
        try await awaitingConfirmation(controller)
        board.hold("resetStatus")
        controller.confirmReset()
        try await eventually { self.board.heldCount("resetStatus") == 1 }
        XCTAssertEqual(board.resets.count, 1, "the command was accepted")
        XCTAssertEqual(controller.phase, .resetting, "accepted is shown as 'resetting', not as done")
        board.release("resetStatus")
        try await eventually { controller.phase == .uncertain(.boardStillWorking) }
        XCTAssertEqual(board.resetStatusRequests.count, 1 + 3, "asked a bounded number of times, the command never again")
        XCTAssertEqual(board.resets.count, 1)
        XCTAssertTrue(controller.hasUnresolvedOperation)

        // A step failed on the board: it says so, and that is not "verified" either.
        board = FakeResetBoard()
        provider = FakeResetProvider(board: board)
        board.acceptedOperationBecomes(.inProgress, reason: 7)
        let second = makeController()
        try await awaitingConfirmation(second)
        second.confirmReset()
        try await eventually { second.phase == .uncertain(.boardStillWorking) }
        XCTAssertEqual(board.resets.count, 1)
    }

    // MARK: - Nothing without the confirmation

    func testAuthenticationAloneSendsNoResetWhateverHappensNext() async throws {
        let controller = makeController()
        try await awaitingConfirmation(controller)
        // Declined.
        controller.declineConfirmation()
        XCTAssertEqual(controller.phase, .idle)
        try await eventually { self.board.closes == 1 }
        XCTAssertTrue(board.resets.isEmpty)
        XCTAssertEqual(board.challengeRequests, 0)
        XCTAssertFalse(controller.hasUnresolvedOperation)

        // The screen is left while the confirmation is shown.
        try await awaitingConfirmation(controller)
        controller.leave()
        XCTAssertEqual(controller.phase, .idle, "nothing was sent: there is nothing to be uncertain about")
        try await eventually { self.board.closes == 2 }
        XCTAssertTrue(board.resets.isEmpty)

        // The hub the app reads changes while the confirmation is shown.
        try await awaitingConfirmation(controller)
        controller.targetDidChange(PowerBaseHubTarget(hubID: "hub-b", baseURL: URL(string: "https://hub-b.example"), isSimulated: false, isPaired: true))
        XCTAssertEqual(controller.phase, .idle, "the confirmation was for a screen that named another hub")
        controller.confirmReset()
        try await drained(controller)
        XCTAssertTrue(board.resets.isEmpty, "a confirmation that comes after that sends nothing")
        XCTAssertEqual(board.executedResets, 0)
    }

    func testConfirmIsOnlyPossibleWhileTheConfirmationIsShown() async throws {
        let controller = makeController()
        controller.confirmReset()
        XCTAssertEqual(controller.phase, .idle)
        verify(controller)
        controller.confirmReset() // while connecting
        try await eventually { controller.phase == .awaitingConfirmation }
        XCTAssertTrue(board.resets.isEmpty)
        XCTAssertEqual(board.challengeRequests, 0)
    }

    func testNoSecureRandomnessSendsNothing() async throws {
        let controller = makeController(randomBytes: { _ in nil })
        try await awaitingConfirmation(controller)
        controller.confirmReset()
        XCTAssertEqual(controller.phase, .failed(.randomnessUnavailable))
        try await drained(controller)
        XCTAssertTrue(board.resets.isEmpty)
        XCTAssertEqual(board.challengeRequests, 0)
    }

    // MARK: - The wrong board, an old board, a board with nothing to reset

    func testADifferentBoardIsNotAskedAnythingMore() async throws {
        board.report(eui64: "00124b0001a2b3c5")
        let controller = makeController()
        verify(controller)
        try await eventually { controller.phase == .failed(.differentBoard) }
        XCTAssertEqual(board.log, [.open, .status, .close], "the advertised name was only a hint: nothing after the board's own word")
        XCTAssertTrue(board.resets.isEmpty)
        XCTAssertNil(controller.boardIdentifier)
    }

    func testABoardWithoutTheCapabilityIsSentNothingInItsPlace() async throws {
        board.set(capabilities: [.bridgeEndpointV1, .managementV1, .releaseReceiptV1])
        let controller = makeController()
        verify(controller)
        try await eventually { controller.phase == .failed(.boardNeedsUpdate) }
        XCTAssertEqual(board.log, [.open, .status, .close], "no reset status, no reset, no start, no cancel")
        XCTAssertTrue(board.resets.isEmpty)
    }

    func testABoardThatHoldsNothingIsReadyWithoutAnyReset() async throws {
        board.set(condition: .notEnrolled)
        board.set(windowSeconds: 0)
        let controller = makeController()
        verify(controller)
        try await eventually { controller.phase == .ready(.alreadyNotEnrolled) }
        XCTAssertEqual(board.log, [.open, .status, .resetStatus(nil), .close])
        XCTAssertTrue(board.resets.isEmpty, "an already reset board is not reset again")
        XCTAssertFalse(controller.canConfirm)
    }

    func testWithoutTheButtonsWindowNothingIsOfferedOrSent() async throws {
        board.set(windowSeconds: 0)
        let controller = makeController()
        verify(controller)
        try await eventually { controller.phase == .failed(.windowNotOpen) }
        XCTAssertFalse(controller.canConfirm)
        controller.confirmReset()
        try await drained(controller)
        XCTAssertTrue(board.resets.isEmpty)

        board.set(windowSeconds: 120)
        board.set(condition: .remoteReleasePending)
        controller.acknowledgeResult()
        controller.startScanning()
        verify(controller)
        try await eventually { controller.phase == .failed(.removalInProgress) }
        board.set(condition: .resetPending)
        controller.acknowledgeResult()
        controller.startScanning()
        verify(controller)
        try await eventually { controller.phase == .failed(.boardBusy) }
        XCTAssertTrue(board.resets.isEmpty)
    }

    func testTheWindowClosingBetweenTheCheckAndTheConfirmationChangesNothing() async throws {
        let controller = makeController()
        try await awaitingConfirmation(controller)
        board.set(windowSeconds: 0) // the two minutes ran out while the user read the question
        controller.confirmReset()
        try await eventually { controller.phase == .failed(.windowNotOpen) }
        XCTAssertEqual(board.resets.count, 1, "the command was sent")
        XCTAssertEqual(board.executedResets, 0, "and the board refused it")
        XCTAssertFalse(controller.hasUnresolvedOperation, "a refusal is an outcome: nothing is left open")
    }

    func testRefusalsAreOutcomesAndNothingIsLeftOpen() async throws {
        for (code, expected) in [
            (PowerBaseBLECode.busy, Controller.Failure.boardBusy), (.wrongTarget, .differentBoard), (.closed, .boardLocked),
            (.challengeExpired, .other), (.challengeInvalid, .other), (.requestConflict, .other), (.malformed, .other),
        ] {
            board = FakeResetBoard()
            provider = FakeResetProvider(board: board)
            board.scriptReset(code)
            let controller = makeController()
            try await awaitingConfirmation(controller)
            controller.confirmReset()
            try await eventually { controller.phase == .failed(expected) }
            XCTAssertFalse(controller.hasUnresolvedOperation, "\(code)")
            XCTAssertEqual(board.resets.count, 1, "\(code): not sent again")
        }
        board = FakeResetBoard()
        provider = FakeResetProvider(board: board)
        board.scriptReset(.notEnrolled)
        let controller = makeController()
        try await awaitingConfirmation(controller)
        controller.confirmReset()
        try await eventually { controller.phase == .ready(.alreadyNotEnrolled) }
    }

    // MARK: - Wrong codes and no connection

    func testOpeningFailuresAreNamedAndNothingIsSent() async throws {
        let cases: [(PowerBaseBLEOpenError, Controller.Failure)] = [
            (.client(.authenticationFailed), .wrongSetupCode), (.client(.boardProofMismatch), .wrongSetupCode), (.client(.handshakeRefused), .boardLocked),
            (.connectionFailed("timeout"), .boardUnreachable), (.gattMismatch("service"), .boardNeedsUpdate), (.boardNotFound, .boardNotFound),
            (.bluetoothUnavailable(.poweredOff), .bluetooth(.poweredOff)),
        ]
        for (error, expected) in cases {
            provider.openErrors = [error]
            let controller = makeController()
            verify(controller)
            try await eventually { controller.phase == .failed(expected) }
        }
        XCTAssertEqual(board.openedSessions, 0)
        XCTAssertTrue(board.resets.isEmpty)

        let controller = makeController()
        verify(controller, setupCode: "NOT-A-CODE")
        XCTAssertEqual(controller.phase, .failed(.invalidSetupCode))
        verify(controller, eui64: "00124b0001a2b3c5")
        XCTAssertEqual(controller.phase, .failed(.boardNotFound), "a board that was not in the scan")
        XCTAssertEqual(provider.opens.count, cases.count, "neither of those connected")
    }

    // MARK: - A lost answer: asked about, never sent again

    func testALostAnswerIsUncertainAndCheckingAsksAboutTheSameOperation() async throws {
        board.loseNextResetAnswer(reachesBoard: true)
        let controller = makeController()
        try await awaitingConfirmation(controller)
        controller.confirmReset()
        try await eventually { controller.phase == .uncertain(.answerLost) }
        XCTAssertTrue(controller.hasUnresolvedOperation)
        XCTAssertEqual(controller.unresolvedBoardIdentifier, EnrollmentFixtures.eui64)
        XCTAssertFalse(controller.canConfirm)
        let operation = board.resets[0].operation

        // Nothing leaves "uncertain" but the board's own answer.
        controller.acknowledgeResult()
        XCTAssertEqual(controller.phase, .uncertain(.answerLost))
        controller.confirmReset()
        XCTAssertEqual(board.resets.count, 1)

        // The board carried it out and restarted. "결과 확인": a new connection, a question.
        board.finishOperation()
        board.restart()
        controller.startScanning()
        verify(controller)
        try await eventually { controller.phase == .ready(.resetVerified) }
        XCTAssertEqual(board.resetStatusRequests.last ?? nil, operation, "the question names the operation that was sent")
        XCTAssertEqual(board.resets.count, 1, "no second command was sent: not automatically, not by checking")
        XCTAssertEqual(board.openedSessions, 2)
        XCTAssertFalse(controller.hasUnresolvedOperation)
    }

    func testACommandThatNeverArrivedIsSaidToBeNotStarted() async throws {
        board.loseNextResetAnswer(reachesBoard: false)
        let controller = makeController()
        try await awaitingConfirmation(controller)
        controller.confirmReset()
        try await eventually { controller.phase == .uncertain(.answerLost) }

        controller.startScanning()
        verify(controller)
        try await eventually { controller.phase == .failed(.resetNotStarted) }
        XCTAssertEqual(board.resets.count, 1, "checking sent no command, although the window is still open")
        XCTAssertEqual(board.executedResets, 0)
        XCTAssertFalse(controller.hasUnresolvedOperation, "the outcome is known: a new attempt is the user's own, explicit step")

        // And that step is a new operation, confirmed again.
        controller.acknowledgeResult()
        controller.startScanning()
        verify(controller)
        try await eventually { controller.phase == .awaitingConfirmation }
        XCTAssertEqual(board.resets.count, 1, "authenticating again sent nothing")
        controller.confirmReset()
        try await eventually { controller.phase == .ready(.resetVerified) }
        XCTAssertEqual(board.resets.count, 2)
        XCTAssertNotEqual(board.resets[0].operation, board.resets[1].operation, "another operation id")
    }

    func testTheBoardRestartingRightAfterItAcceptedIsUncertainNotDone() async throws {
        board.disconnectAfterAccept()
        let controller = makeController()
        try await awaitingConfirmation(controller)
        controller.confirmReset()
        try await eventually { controller.phase == .uncertain(.answerLost) }
        XCTAssertTrue(controller.hasUnresolvedOperation)

        // The check cannot reach the board yet: still uncertain, with why.
        provider.openErrors = [.connectionFailed("timeout")]
        controller.startScanning()
        verify(controller)
        try await eventually { controller.phase == .uncertain(.checkFailed(.boardUnreachable)) }
        XCTAssertTrue(controller.hasUnresolvedOperation)
        // A wrong code on the way does not turn it into "failed, nothing happened" either.
        provider.openErrors = [.client(.authenticationFailed)]
        verify(controller)
        try await eventually { controller.phase == .uncertain(.checkFailed(.wrongSetupCode)) }
        verify(controller, setupCode: "short")
        XCTAssertEqual(controller.phase, .uncertain(.checkFailed(.invalidSetupCode)))

        board.finishOperation()
        board.restart()
        verify(controller)
        try await eventually { controller.phase == .ready(.resetVerified) }
        XCTAssertEqual(board.resets.count, 1)
    }

    func testTheBoardStillWorkingIsFollowedOnTheNextCheck() async throws {
        board.acceptedOperationBecomes(.inProgress, reason: 8)
        let controller = makeController()
        try await awaitingConfirmation(controller)
        controller.confirmReset()
        try await eventually { controller.phase == .uncertain(.boardStillWorking) }

        // The board carried on at its next boot.
        board.finishOperation()
        board.restart()
        controller.startScanning()
        verify(controller)
        try await eventually { controller.phase == .ready(.resetVerified) }
        XCTAssertEqual(board.resets.count, 1)

        // Verified once, then registered again elsewhere: the old operation says nothing about now.
        board = FakeResetBoard()
        provider = FakeResetProvider(board: board)
        board.loseNextResetAnswer(reachesBoard: true)
        let second = makeController()
        try await awaitingConfirmation(second)
        second.confirmReset()
        try await eventually { second.phase == .uncertain(.answerLost) }
        board.finishOperation()
        board.restart()
        board.set(condition: .enrolled) // somebody registered it again meanwhile
        second.startScanning()
        verify(second)
        try await eventually { second.phase == .failed(.windowNotOpen) }
        XCTAssertFalse(second.hasUnresolvedOperation)
        XCTAssertEqual(board.resets.count, 1)
    }

    func testAnUnresolvedOperationIsOnlyAskedOfTheBoardItWentTo() async throws {
        board.loseNextResetAnswer(reachesBoard: true)
        let controller = makeController()
        try await awaitingConfirmation(controller)
        controller.confirmReset()
        try await eventually { controller.phase == .uncertain(.answerLost) }

        // Another board answers under the same scan entry.
        board.report(eui64: "00124b0001a2b3c5")
        controller.startScanning()
        verify(controller)
        try await eventually { controller.phase == .uncertain(.checkFailed(.differentBoard)) }
        XCTAssertTrue(controller.hasUnresolvedOperation)
        XCTAssertEqual(board.resets.count, 1)
    }

    // MARK: - Leaving, and what was only scheduled

    func testLeavingRightAfterTheConfirmationSendsNothing() async throws {
        let controller = makeController()
        try await awaitingConfirmation(controller)
        controller.confirmReset() // the task is queued ...
        controller.leave()        // ... and the screen is gone before it runs
        XCTAssertEqual(controller.phase, .idle)
        try await drained(controller)
        XCTAssertTrue(board.resets.isEmpty, "a command that was only scheduled is not sent")
        XCTAssertEqual(board.challengeRequests, 0)
        XCTAssertFalse(controller.hasUnresolvedOperation)
    }

    func testLeavingWhileTheChallengeIsUnderWaySendsNoCommand() async throws {
        board.hold("challenge")
        let controller = makeController()
        try await awaitingConfirmation(controller)
        controller.confirmReset()
        try await eventually { self.board.heldCount("challenge") == 1 }
        controller.leave()
        XCTAssertEqual(controller.phase, .idle)
        board.release("challenge")
        try await drained(controller)
        XCTAssertTrue(board.resets.isEmpty, "the challenge's late answer starts nothing")
        XCTAssertFalse(controller.hasUnresolvedOperation)
    }

    func testLeavingAfterTheCommandWasSentIsNotShownAsCancelled() async throws {
        board.hold("reset")
        let controller = makeController()
        try await awaitingConfirmation(controller)
        controller.confirmReset()
        try await eventually { self.board.heldCount("reset") == 1 }
        XCTAssertEqual(board.resets.count, 1, "the command left this device")

        controller.leave()
        XCTAssertEqual(controller.phase, .uncertain(.answerLost), "not idle, not cancelled: its outcome is unknown")
        XCTAssertTrue(controller.hasUnresolvedOperation)
        board.release("reset")
        try await drained(controller)
        XCTAssertEqual(controller.phase, .uncertain(.answerLost), "the late answer of the ended run changes nothing on the screen")
        XCTAssertEqual(board.resetStatusRequests.count, 1, "and the ended run asked nothing more")

        // Coming back: the same operation is asked about.
        let operation = board.resets[0].operation
        controller.startScanning()
        verify(controller)
        try await eventually { controller.phase == .ready(.resetVerified) }
        XCTAssertEqual(board.resetStatusRequests.last ?? nil, operation)
        XCTAssertEqual(board.resets.count, 1)
    }

    func testAHubChangeAfterTheCommandWasSentKeepsFollowingIt() async throws {
        board.hold("reset")
        let controller = makeController()
        try await awaitingConfirmation(controller)
        controller.confirmReset()
        try await eventually { self.board.heldCount("reset") == 1 }
        controller.targetDidChange(PowerBaseHubTarget(hubID: "hub-b", baseURL: URL(string: "https://hub-b.example"), isSimulated: false, isPaired: true))
        XCTAssertEqual(controller.phase, .uncertain(.answerLost), "the board does not care which hub is shown; the outcome stays open")
        XCTAssertTrue(controller.hasUnresolvedOperation)
        board.release("reset")
        try await drained(controller)
        XCTAssertEqual(board.resets.count, 1)
    }

    func testALateAnswerOfAnEndedRunDoesNotOverwriteTheNextRun() async throws {
        board.hold("resetStatus")
        let controller = makeController()
        verify(controller)
        try await eventually { self.board.heldCount("resetStatus") == 1 } // the first run's question is under way
        controller.leave()
        XCTAssertEqual(controller.phase, .idle)

        // A second run, against a board that now holds nothing.
        board.set(condition: .notEnrolled)
        controller.startScanning()
        verify(controller)
        try await eventually { self.board.heldCount("resetStatus") == 2 }
        XCTAssertEqual(controller.phase, .checking)
        board.release("resetStatus") // both answers arrive
        try await eventually { controller.phase == .ready(.alreadyNotEnrolled) }
        try await drained(controller)
        XCTAssertEqual(controller.phase, .ready(.alreadyNotEnrolled), "only the current run's answer is shown")
        XCTAssertTrue(board.resets.isEmpty)
    }

    // MARK: - The background

    func testNothingNewStartsInTheBackground() async throws {
        let controller = makeController()
        controller.sceneDidEnterBackground()
        verify(controller)
        try await eventually { controller.foregroundWaiters == 1 }
        XCTAssertTrue(provider.sentSteps.isEmpty, "not even the connection")
        controller.sceneDidBecomeActive()
        try await eventually { controller.phase == .awaitingConfirmation }
        XCTAssertEqual(provider.sentSteps, [.connect, .version, .handshake0, .handshake1])

        // Each message of the opening waits.
        for step in FakeResetProvider.OpenStep.allCases.dropLast() {
            board = FakeResetBoard()
            provider = FakeResetProvider(board: board)
            provider.holdsOpensAfter = step
            let opening = makeController()
            verify(opening)
            try await eventually { self.provider.heldCount == 1 }
            opening.sceneDidEnterBackground()
            provider.releaseHeld()
            try await eventually { opening.foregroundWaiters == 1 }
            XCTAssertEqual(provider.sentSteps.last, step, "the message after \(step) waits")
            XCTAssertEqual(board.openedSessions, 0)
            opening.sceneDidBecomeActive()
            try await eventually { opening.phase == .awaitingConfirmation }
        }
    }

    func testStatusTheChallengeTheCommandAndEveryQuestionWaitForTheForeground() async throws {
        // The board's status and the reset status, after the opening.
        provider.holdsOpensAfter = .handshake1
        let controller = makeController()
        verify(controller)
        try await eventually { self.provider.heldCount == 1 }
        controller.sceneDidEnterBackground()
        provider.releaseHeld()
        try await eventually { controller.foregroundWaiters == 1 }
        XCTAssertEqual(board.log, [.open], "no status in the background")
        board.hold("status")
        controller.sceneDidBecomeActive()
        try await eventually { self.board.heldCount("status") == 1 }
        controller.sceneDidEnterBackground()
        board.release("status") // an answer that is under way is still taken ...
        try await eventually { controller.foregroundWaiters == 1 }
        XCTAssertEqual(board.log, [.open, .status], "... and the next question waits")
        controller.sceneDidBecomeActive()
        try await eventually { controller.phase == .awaitingConfirmation }

        // The confirmation in the background: no challenge.
        controller.sceneDidEnterBackground()
        controller.confirmReset()
        try await eventually { controller.foregroundWaiters == 1 }
        XCTAssertEqual(board.challengeRequests, 0)
        board.hold("challenge")
        controller.sceneDidBecomeActive()
        try await eventually { self.board.heldCount("challenge") == 1 }
        // The challenge is under way; the command must wait.
        controller.sceneDidEnterBackground()
        board.release("challenge")
        try await eventually { controller.foregroundWaiters == 1 }
        XCTAssertTrue(board.resets.isEmpty, "the reset command is not sent in the background")
        XCTAssertFalse(controller.hasUnresolvedOperation)
        board.hold("reset")
        controller.sceneDidBecomeActive()
        try await eventually { self.board.heldCount("reset") == 1 }
        XCTAssertEqual(board.resets.count, 1)
        // The command is under way; the question about it must wait.
        controller.sceneDidEnterBackground()
        board.release("reset")
        try await eventually { controller.foregroundWaiters == 1 }
        XCTAssertEqual(board.resetStatusRequests.count, 1, "only the one from before the confirmation")
        controller.sceneDidBecomeActive()
        try await eventually { controller.phase == .ready(.resetVerified) }
        XCTAssertEqual(board.resets.count, 1)
        try await drained(controller)
        XCTAssertEqual(controller.foregroundWaiters, 0)
    }

    func testARunThatEndsWhileItWaitsForTheForegroundStartsNothingLater() async throws {
        let controller = makeController()
        try await awaitingConfirmation(controller)
        controller.sceneDidEnterBackground()
        controller.confirmReset()
        try await eventually { controller.foregroundWaiters == 1 }
        controller.leave()
        XCTAssertEqual(controller.foregroundWaiters, 0, "ending a run wakes what waited for it")
        controller.sceneDidBecomeActive()
        try await drained(controller)
        XCTAssertTrue(board.resets.isEmpty)
        XCTAssertEqual(board.challengeRequests, 0)
        XCTAssertEqual(controller.phase, .idle)
    }

    // MARK: - The same board again

    func testEveryRunOpensItsOwnConnectionAndClosesIt() async throws {
        let controller = makeController()
        try await awaitingConfirmation(controller)
        controller.declineConfirmation()
        controller.startScanning()
        try await awaitingConfirmation(controller)
        controller.confirmReset()
        try await eventually { controller.phase == .ready(.resetVerified) }
        try await eventually { self.board.closes == 2 }
        XCTAssertEqual(provider.opens.count, 2, "the same board, connected again through the provider (which waits for the previous end)")
        XCTAssertEqual(provider.opens[0].boardID, provider.opens[1].boardID)
        XCTAssertEqual(board.openedSessions, 2)
    }

    // MARK: - The scan

    func testWhileACommandIsUnresolvedOnlyItsBoardIsOffered() {
        let other = PowerBaseBLEDiscoveredBoard(id: UUID(), name: "POGO-PB-00124B0001A2B3C5", advertisedEUI64: "00124b0001a2b3c5", rssi: -40)
        let mine = PowerBaseBLEDiscoveredBoard(id: FakeResetProvider.boardID, name: nil, advertisedEUI64: EnrollmentFixtures.eui64, rssi: -70)
        var state = PowerBaseReenrollScreenState(boards: [other, mine])
        XCTAssertEqual(PowerBaseReenrollPresentation.selectableBoards(state).count, 2)
        state.hasUnresolvedOperation = true
        state.unresolvedBoardIdentifier = EnrollmentFixtures.eui64
        XCTAssertEqual(PowerBaseReenrollPresentation.selectableBoards(state), [mine])
    }
}
#endif
