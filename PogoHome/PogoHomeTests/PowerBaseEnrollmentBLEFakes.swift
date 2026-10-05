#if DEBUG
import Foundation
import PowerBaseBLEKit
import XCTest
@testable import PogoHome

/// The order in which the fakes were called, across the hub and the board.
nonisolated final class EnrollmentEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func add(_ entry: String) { lock.withLock { entries.append(entry) } }
    var all: [String] { lock.withLock { entries } }
    func clear() { lock.withLock { entries.removeAll() } }
}

/// `FakeEnrollmentHub` with every request also written to the shared event log.
nonisolated struct LoggedEnrollmentHub: PowerBaseEnrollmentTransport {
    let hub: FakeEnrollmentHub
    let log: EnrollmentEventLog

    func start(baseURL: URL, credential: HubCredential, eui64: String, pskd: String) async throws -> PowerBaseEnrollmentSession {
        log.add("hub POST")
        return try await hub.start(baseURL: baseURL, credential: credential, eui64: eui64, pskd: pskd)
    }

    func startDeliveringBridgeEndpoint(baseURL: URL, credential: HubCredential, eui64: String, pskd: String) async throws -> PowerBaseEnrollmentSession {
        log.add("hub POST")
        return try await hub.startDeliveringBridgeEndpoint(baseURL: baseURL, credential: credential, eui64: eui64, pskd: pskd)
    }

    func status(baseURL: URL, credential: HubCredential, sessionID: String) async throws -> PowerBaseEnrollmentSession {
        log.add("hub GET")
        return try await hub.status(baseURL: baseURL, credential: credential, sessionID: sessionID)
    }

    func cancel(baseURL: URL, credential: HubCredential, sessionID: String) async throws -> PowerBaseEnrollmentSession {
        log.add("hub DELETE")
        return try await hub.cancel(baseURL: baseURL, credential: credential, sessionID: sessionID)
    }
}

/// A board waiting for enrollment, as far as the controller can see it: the admission rules of
/// pb_ble_admission.c in miniature (one attempt record, a challenge per session used once, the
/// request id as the attempt's name), plus switches to lose answers and connections.
nonisolated final class FakeBoard: @unchecked Sendable {
    struct StartCall: Equatable {
        let session: Int
        let target: String
        let requestID: Data
        let challenge: Data
        let pskd: String
        /// The bridge endpoint the start carried (every start of the app carries one).
        let endpoint: PowerBaseBLEBridgeEndpoint
    }

    struct CancelCall: Equatable {
        let session: Int
        let target: String
        let requestID: Data
    }

    /// What the second copy of a `pb-start` that reaches the board twice carries.
    enum StartRepeat {
        /// The very same request.
        case same
        /// The same request id with another challenge: other content.
        case otherContent
    }

    typealias AttemptChange = (phase: PowerBaseBLEAttemptPhase, state: PowerBaseBLEEnrollState, result: UInt8)

    private struct Attempt {
        var requestID: Data
        var content: Data
        var phase: PowerBaseBLEAttemptPhase
        var result: UInt8
        var isActive: Bool { phase == .queued || phase == .running }
    }

    let eui64: PowerBaseBLEEUI64
    private let log: EnrollmentEventLog
    private let lock = NSLock()

    private var reportedEUI64: PowerBaseBLEEUI64
    private var state = PowerBaseBLEEnrollState.waiting
    private var code = PowerBaseBLECode.ok
    private var joinerUnavailable = false
    private var boardCapabilities: PowerBaseBLECapabilities = [.bridgeEndpointV1]
    private var foreignAttemptActive = false
    private var attempt: Attempt?
    private var joinerStartCount = 0

    private var sessionCount = 0
    private var liveSession = 0
    private var challenge: (session: Int, bytes: Data)?
    private var challengeCounter: UInt8 = 0

    private var startCalls: [StartCall] = []
    private var cancelCalls: [CancelCall] = []
    private var statusCallCount = 0
    private var challengeRequestCount = 0
    private var closedSessions: [Int] = []

    private var scriptedStartCodes: [PowerBaseBLECode] = []
    private var statusErrors: [PowerBaseBLEClientError] = []
    private var loseNextStartAnswer: Bool?
    private var cancelError: PowerBaseBLEClientError?
    private var holdsStart = false
    private var heldStart: [CheckedContinuation<Void, Never>] = []
    private var holdsChallenges = false
    private var heldChallenges: [CheckedContinuation<Void, Never>] = []
    private var holdsPlainStatus = false
    private var heldPlainStatus: [CheckedContinuation<Void, Never>] = []
    private var repeatedStart: (second: StartRepeat, attemptBecomes: AttemptChange?)?
    private var scriptedCancelCodes: [PowerBaseBLECode] = []

    init(eui64 hex: String = EnrollmentFixtures.eui64, log: EnrollmentEventLog = EnrollmentEventLog()) {
        eui64 = PowerBaseBLEEUI64(hex: hex)!
        reportedEUI64 = eui64
        self.log = log
    }

    // MARK: What the test reads

    var starts: [StartCall] { lock.withLock { startCalls } }
    var cancels: [CancelCall] { lock.withLock { cancelCalls } }
    /// How often the board created an attempt -- what would start a Joiner.
    var joinerStarts: Int { lock.withLock { joinerStartCount } }
    var statusCalls: Int { lock.withLock { statusCallCount } }
    var challengeRequests: Int { lock.withLock { challengeRequestCount } }
    var openedSessions: Int { lock.withLock { sessionCount } }
    var closed: [Int] { lock.withLock { closedSessions } }
    var attemptRequestID: Data? { lock.withLock { attempt?.requestID } }
    var heldStarts: Int { lock.withLock { heldStart.count } }
    var heldChallengeRequests: Int { lock.withLock { heldChallenges.count } }
    var heldPlainStatusRequests: Int { lock.withLock { heldPlainStatus.count } }
    var attemptPhase: PowerBaseBLEAttemptPhase? { lock.withLock { attempt?.phase } }

    // MARK: What the test sets

    /// The EUI-64 the board reports inside the session (to play another board).
    func report(eui64 hex: String) { lock.withLock { reportedEUI64 = PowerBaseBLEEUI64(hex: hex)! } }
    func set(state: PowerBaseBLEEnrollState) { lock.withLock { self.state = state } }
    func setJoinerUnavailable() { lock.withLock { joinerUnavailable = true } }
    /// What the board lists in `proto-ver`. `[]`: firmware from before the bridge endpoint.
    func set(capabilities: PowerBaseBLECapabilities) { lock.withLock { boardCapabilities = capabilities } }
    fileprivate var capabilities: PowerBaseBLECapabilities { lock.withLock { boardCapabilities } }
    /// Another client's attempt is in progress.
    func setForeignAttemptActive(_ active: Bool = true) { lock.withLock { foreignAttemptActive = active } }
    func closeEnrollment() { lock.withLock { code = .closed } }

    /// The attempt this board has moves on.
    func advance(to phase: PowerBaseBLEAttemptPhase, state: PowerBaseBLEEnrollState, result: UInt8 = 0) {
        lock.withLock {
            attempt?.phase = phase
            attempt?.result = result
            self.state = state
            if phase == .enrolled { code = .closed }
        }
    }

    /// The board forgets everything (a reboot).
    func forgetAttempt() { lock.withLock { attempt = nil } }

    /// The connection drops: every request on the current session fails from now on.
    func disconnect() { lock.withLock { liveSession = 0 } }

    /// The next `pb-start` answers with these codes, in order, instead of being judged.
    func scriptStart(_ codes: PowerBaseBLECode...) { lock.withLock { scriptedStartCodes.append(contentsOf: codes) } }

    /// The next `pb-status` requests fail with these errors, in order.
    func failStatus(_ errors: PowerBaseBLEClientError...) { lock.withLock { statusErrors.append(contentsOf: errors) } }

    /// The next `pb-start` gets no answer and the connection is gone. `reachesBoard`: whether the
    /// board took the request before the answer was lost.
    func loseNextStartAnswer(reachesBoard: Bool) { lock.withLock { loseNextStartAnswer = reachesBoard } }

    /// The next `pb-cancel` gets no answer and the connection is gone.
    func failNextCancel(_ error: PowerBaseBLEClientError) { lock.withLock { cancelError = error } }

    /// The next `pb-start` reaches the board twice and only the answer to the second copy reaches
    /// the app: the first copy is judged as usual, `attemptBecomes` then moves the attempt on, and
    /// the second copy is judged by the same rules (`DUPLICATE` or `REQUEST_CONFLICT`).
    func deliverNextStartTwice(_ second: StartRepeat = .same, attemptBecomes: AttemptChange? = nil) {
        lock.withLock { repeatedStart = (second, attemptBecomes) }
    }

    /// The next `pb-cancel` requests answer with these codes, in order, instead of being judged.
    func scriptCancel(_ codes: PowerBaseBLECode...) { lock.withLock { scriptedCancelCodes.append(contentsOf: codes) } }

    func holdStart() { lock.withLock { holdsStart = true } }

    /// A `pb-status` that asks for no challenge gets its answer only after `releasePlainStatus()`.
    func holdPlainStatus() { lock.withLock { holdsPlainStatus = true } }

    func releasePlainStatus() {
        let waiting = lock.withLock {
            holdsPlainStatus = false
            defer { heldPlainStatus.removeAll() }
            return heldPlainStatus
        }
        waiting.forEach { $0.resume() }
    }

    /// A `pb-status` that asks for a challenge gets its answer only after `releaseChallenges()`.
    func holdChallenges() { lock.withLock { holdsChallenges = true } }

    func releaseChallenges() {
        let waiting = lock.withLock {
            holdsChallenges = false
            defer { heldChallenges.removeAll() }
            return heldChallenges
        }
        waiting.forEach { $0.resume() }
    }

    func releaseStart() {
        let waiting = lock.withLock {
            holdsStart = false
            defer { heldStart.removeAll() }
            return heldStart
        }
        waiting.forEach { $0.resume() }
    }

    // MARK: Sessions

    func openSession() -> FakeBoardSession {
        let index = lock.withLock {
            sessionCount += 1
            liveSession = sessionCount
            challenge = nil
            return sessionCount
        }
        return FakeBoardSession(board: self, index: index)
    }

    fileprivate func waitWhileChallengesAreHeld() async {
        await withCheckedContinuation { continuation in
            let held = lock.withLock {
                if holdsChallenges { heldChallenges.append(continuation) }
                return holdsChallenges
            }
            if !held { continuation.resume() }
        }
    }

    fileprivate func waitWhilePlainStatusIsHeld() async {
        await withCheckedContinuation { continuation in
            let held = lock.withLock {
                if holdsPlainStatus { heldPlainStatus.append(continuation) }
                return holdsPlainStatus
            }
            if !held { continuation.resume() }
        }
    }

    fileprivate func close(session: Int) {
        lock.withLock {
            closedSessions.append(session)
            if liveSession == session { liveSession = 0 }
        }
    }

    private func requireLive(_ session: Int) throws {
        guard liveSession == session else { throw PowerBaseBLEClientError.noSession }
    }

    fileprivate func status(session: Int, issueChallenge: Bool, requestID: PowerBaseBLERequestID?) throws -> PowerBaseBLEStatus {
        log.add(issueChallenge ? "board status+challenge" : "board status")
        return try lock.withLock {
            statusCallCount += 1
            try requireLive(session)
            if !statusErrors.isEmpty {
                let error = statusErrors.removeFirst()
                liveSession = 0
                throw error
            }
            var flags = PowerBaseBLEStatus.Flags()
            if attempt?.isActive == true || foreignAttemptActive { flags.insert(.attemptActive) }
            if joinerUnavailable { flags.insert(.joinerUnavailable) }
            var phase = PowerBaseBLEAttemptPhase.none
            var result: UInt8 = 0
            if let requestID, let attempt, attempt.requestID == requestID.bytes {
                flags.insert(.requestMatch)
                phase = attempt.phase
                result = attempt.result
            }
            var issued: PowerBaseBLEChallenge?
            if issueChallenge, code == .ok {
                challengeRequestCount += 1
                challengeCounter &+= 1
                let bytes = Data(repeating: challengeCounter, count: 16)
                challenge = (session, bytes)
                issued = PowerBaseBLEChallenge(bytes: bytes, lifetimeSeconds: 60)
                flags.insert(.challengeIssued)
            }
            return PowerBaseBLEStatus(
                code: code, eui64: reportedEUI64, state: state, lastResult: 0, flags: flags, requestPhase: phase,
                requestResult: result, attempt: UInt32(joinerStartCount), challenge: issued
            )
        }
    }

    fileprivate func start(
        session: Int, target: PowerBaseBLEEUI64, requestID: PowerBaseBLERequestID, challenge sent: PowerBaseBLEChallenge, pskd: String,
        endpoint: PowerBaseBLEBridgeEndpoint
    ) async throws -> PowerBaseBLECode {
        log.add("board start")
        try lock.withLock {
            try requireLive(session)
            // Like the real client: a board without the capability is never sent this message.
            guard boardCapabilities.contains(.bridgeEndpointV1) else { throw PowerBaseBLEClientError.invalidInput("capability") }
            startCalls.append(StartCall(session: session, target: target.hex, requestID: requestID.bytes, challenge: sent.bytes, pskd: pskd, endpoint: endpoint))
        }
        await withCheckedContinuation { continuation in
            let held = lock.withLock {
                if holdsStart { heldStart.append(continuation) }
                return holdsStart
            }
            if !held { continuation.resume() }
        }
        return try lock.withLock {
            if let reaches = loseNextStartAnswer {
                loseNextStartAnswer = nil
                if reaches { _ = admit(session: session, target: target, requestID: requestID, challenge: sent, pskd: pskd, endpoint: endpoint) }
                liveSession = 0
                throw PowerBaseBLEClientError.requestFailed(.timeout)
            }
            if !scriptedStartCodes.isEmpty {
                let scripted = scriptedStartCodes.removeFirst()
                // A new request uses up the session's challenge whatever the answer is.
                challenge = nil
                return scripted
            }
            if let repeated = repeatedStart {
                repeatedStart = nil
                // The first copy; its answer is the one that never arrives.
                _ = admit(session: session, target: target, requestID: requestID, challenge: sent, pskd: pskd, endpoint: endpoint)
                if let change = repeated.attemptBecomes {
                    attempt?.phase = change.phase
                    attempt?.result = change.result
                    state = change.state
                }
                var second = sent
                if repeated.second == .otherContent {
                    second = PowerBaseBLEChallenge(bytes: Data(sent.bytes.map { $0 ^ 0xFF }), lifetimeSeconds: sent.lifetimeSeconds) ?? sent
                }
                let answer = admit(session: session, target: target, requestID: requestID, challenge: second, pskd: pskd, endpoint: endpoint)
                // An enrolled board closes BLE enrollment for this boot.
                if repeated.attemptBecomes?.phase == .enrolled { code = .closed }
                return answer
            }
            return admit(session: session, target: target, requestID: requestID, challenge: sent, pskd: pskd, endpoint: endpoint)
        }
    }

    /// pb_ble_admission.c `start_admit()`, without the checks the codec already makes.
    private func admit(
        session: Int, target: PowerBaseBLEEUI64, requestID: PowerBaseBLERequestID, challenge sent: PowerBaseBLEChallenge, pskd: String,
        endpoint: PowerBaseBLEBridgeEndpoint
    ) -> PowerBaseBLECode {
        guard code == .ok else { return .closed }
        // The endpoint is part of what makes a request "the same request".
        let content = target.bytes + sent.bytes + Data(pskd.utf8) + endpoint.address + Data([UInt8(endpoint.port >> 8), UInt8(endpoint.port & 0xff)])
        if let attempt, attempt.requestID == requestID.bytes {
            return attempt.isActive && attempt.content == content ? .duplicate : .requestConflict
        }
        let valid = challenge?.session == session && challenge?.bytes == sent.bytes
        challenge = nil
        guard target == eui64 else { return .wrongTarget }
        guard valid else { return .challengeInvalid }
        guard !joinerUnavailable else { return .unavailable }
        guard attempt?.isActive != true, !foreignAttemptActive else { return .busy }
        guard state == .waiting else { return .notWaiting }
        attempt = Attempt(requestID: requestID.bytes, content: content, phase: .queued, result: 0)
        joinerStartCount += 1
        return .accepted
    }

    fileprivate func cancel(session: Int, target: PowerBaseBLEEUI64, requestID: PowerBaseBLERequestID) throws -> PowerBaseBLECode {
        log.add("board cancel")
        return try lock.withLock {
            try requireLive(session)
            cancelCalls.append(CancelCall(session: session, target: target.hex, requestID: requestID.bytes))
            if let error = cancelError {
                cancelError = nil
                liveSession = 0
                throw error
            }
            if !scriptedCancelCodes.isEmpty { return scriptedCancelCodes.removeFirst() }
            guard code == .ok else { return .closed }
            guard var current = attempt, current.requestID == requestID.bytes, current.isActive else { return .noSuchAttempt }
            current.phase = .cancelled
            current.result = 13
            attempt = current
            state = .waiting
            return .ok
        }
    }
}

nonisolated struct FakeBoardSession: PowerBaseBLEBoardSession {
    let board: FakeBoard
    let index: Int

    func status(issueChallenge: Bool, requestID: PowerBaseBLERequestID?) async throws -> PowerBaseBLEStatus {
        if issueChallenge {
            await board.waitWhileChallengesAreHeld()
        } else {
            await board.waitWhilePlainStatusIsHeld()
        }
        return try board.status(session: index, issueChallenge: issueChallenge, requestID: requestID)
    }

    func capabilities() async -> PowerBaseBLECapabilities { board.capabilities }

    func start(
        target: PowerBaseBLEEUI64, requestID: PowerBaseBLERequestID, challenge: PowerBaseBLEChallenge, pskd: String,
        endpoint: PowerBaseBLEBridgeEndpoint
    ) async throws -> PowerBaseBLECode {
        try await board.start(session: index, target: target, requestID: requestID, challenge: challenge, pskd: pskd, endpoint: endpoint)
    }

    func cancel(target: PowerBaseBLEEUI64, requestID: PowerBaseBLERequestID) async throws -> PowerBaseBLECode {
        try board.cancel(session: index, target: target, requestID: requestID)
    }

    func close() async {
        board.close(session: index)
    }
}

/// Bluetooth as the controller sees it: a state, a scan list, and `openSession` answering from a
/// script (by default: a session with `board`). Every open is recorded with what it was given.
///
/// An opening sends four commands, like the real one: the connection, `proto-ver` and the two
/// handshake messages. Before each it asks the caller's permit; `sentSteps` is what went out.
@MainActor
final class FakeBLEBoardProvider: PowerBaseBLEBoardProviding {
    struct Open: Equatable {
        let boardID: UUID
        let eui64: String
        let setupCode: String
    }

    enum OpenStep: CaseIterable {
        case connect, version, handshake0, handshake1
    }

    static let boardID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    var availability = PowerBaseBLEAvailability.poweredOn
    var boards: [PowerBaseBLEDiscoveredBoard]
    var onChange: (() -> Void)?

    let board: FakeBoard
    private let log: EnrollmentEventLog
    private(set) var opens: [Open] = []
    private(set) var activations = 0
    private(set) var scanStarts = 0
    private(set) var scanStops = 0
    private(set) var shutdowns = 0
    /// Each open takes the next error; when none is left, the open succeeds.
    var openErrors: [PowerBaseBLEOpenError] = []
    /// From now on every open fails with this.
    var alwaysFailOpens: PowerBaseBLEOpenError?
    /// Every opening stops after its last command went out -- the handshake's answer is under
    /// way -- until `releaseHeld()`.
    var holdsOpens = false
    /// Every opening stops after this command went out, until `releaseHeld()`.
    var holdsOpensAfter: OpenStep?
    /// The commands the openings sent, in order.
    private(set) var sentSteps: [OpenStep] = []
    private var held: [CheckedContinuation<Void, Never>] = []

    init(board: FakeBoard, log: EnrollmentEventLog = EnrollmentEventLog()) {
        self.board = board
        self.log = log
        boards = [PowerBaseBLEDiscoveredBoard(id: Self.boardID, name: "POGO-PB-" + board.eui64.hex.uppercased(), advertisedEUI64: board.eui64.hex, rssi: -52)]
    }

    var heldCount: Int { held.count }

    func releaseHeld() {
        holdsOpens = false
        holdsOpensAfter = nil
        let waiting = held
        held = []
        waiting.forEach { $0.resume() }
    }

    func set(availability: PowerBaseBLEAvailability) {
        self.availability = availability
        onChange?()
    }

    func activate() { activations += 1 }

    func startScanning() {
        scanStarts += 1
        onChange?()
    }

    func stopScanning() { scanStops += 1 }

    func shutdown() { shutdowns += 1 }

    func openSession(
        boardID: UUID, eui64: PowerBaseBLEEUI64, setupCode: String, permit: @escaping PowerBaseBLESendPermit
    ) async throws -> any PowerBaseBLEBoardSession {
        log.add("board open")
        opens.append(Open(boardID: boardID, eui64: eui64.hex, setupCode: setupCode))
        for step in OpenStep.allCases {
            do {
                try await permit()
            } catch {
                throw PowerBaseBLEOpenError.cancelled
            }
            sentSteps.append(step)
            if holdsOpensAfter == step || (holdsOpens && step == .handshake1) {
                await withCheckedContinuation { held.append($0) }
            }
        }
        if let alwaysFailOpens { throw alwaysFailOpens }
        if !openErrors.isEmpty { throw openErrors.removeFirst() }
        guard availability == .poweredOn else { throw PowerBaseBLEOpenError.bluetoothUnavailable(availability) }
        return board.openSession()
    }
}

extension EnrollmentFixtures {
    /// A made-up setup code in the prepare tool's form (26 base32 characters). Not a real one.
    static let setupCode = "MFRGGZDFMZTWQ2LKNNWG23TPOA"
}
#endif
