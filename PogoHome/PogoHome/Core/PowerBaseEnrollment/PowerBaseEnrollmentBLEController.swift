#if DEBUG
import Foundation
import Observation
import PowerBaseBLEKit

/// The DEBUG-only "BLE 등록 시험": hands a one-time Thread Joiner passphrase (PSKd) to an unenrolled
/// spare Power Base over Bluetooth, after the hub the app follows agreed to let that board join,
/// and shows what the board and the hub report until the hub's session ends. Not a registration
/// feature; the USB-console test (`PowerBaseEnrollmentController`) is untouched and separate.
///
/// The order, which nothing in the UI can change (firmware repository, docs/power-base.md "앱이
/// 지켜야 할 순서"):
///
/// 1. **Authenticate the board.** Security 2 with the EUI-64 the tester confirmed as the user
///    name and the board's setup code as the password, once. Then `pb-status` inside the session
///    must report that same EUI-64. The advertised name is only how the tester picked a row.
/// 2. **Ask the hub.** `POST` with the authenticated EUI-64 and a fresh PSKd -- only to the paired
///    hub picked in "Find hubs", with this device's own credential and the certificate pinned at
///    pairing (the same rules and transport as the USB test).
/// 3. **Wait for the hub.** Nothing goes to the board while the session is `preparing`. If the
///    session ends first, nothing goes to the board at all.
/// 4. **Deliver.** Once the hub says `waiting_for_heartbeat`: a fresh challenge from the current
///    Security 2 session (authenticating again first if the connection was lost meanwhile), then
///    `pb-start` with that PSKd and one request id. Exactly one start per run, whatever the UI does.
/// 5. **Follow.** The board's `ACCEPTED`, `joining`, `attaching` and `enrolled` are progress. The
///    only success is the hub's `heartbeat_received` for this session.
///
/// Rules this type enforces:
/// - **One driver.** A run is one task that walks the steps above; views only call `start`,
///   `cancel` and the lifecycle methods, so re-evaluating a view body can't post or start twice.
/// - **Nothing late applies.** Every run has a generation. Ending a run (final state, cancel,
///   leaving, another source) starts a new generation; an answer for an old one changes nothing
///   on screen. A hub session that an old run created is still cancelled by that run's clean-up.
/// - **A lost answer is not a "no".** A `POST` without an answer is never repeated on its own: the
///   run stops as "uncertain", keeps its PSKd, and the tester asks again explicitly (the hub
///   answers a repeated `POST` from the same device with the session it already has). A `pb-start`
///   without an answer keeps its request id: after authenticating again, `pb-status` says whether
///   the board has it; only if it does not is the same request (same id) sent again.
/// - **A refusal is not a "yes" either.** `REQUEST_CONFLICT` only says the board knows the request
///   id -- as an attempt that has ended, or as one with other content. What the board has under
///   it is read from `pb-status` (phase and result, not the match flag alone); the request is
///   never repeated under a new id or with a new PSKd.
/// - **Nothing new starts in the background.** Before every new command -- connecting, each
///   message of the handshake, `pb-status`, `pb-start`, the `POST`, each poll -- the run waits
///   until the app is in the foreground. A request that already left this device is waited for.
///   Once a hub session exists, coming back asks the hub before the board hears anything.
/// - **An unknown PSKd is never delivered.** A session of this device that already runs on the
///   hub (`409`) was started with a PSKd this run doesn't have: it is followed and can be
///   cancelled, and the board gets nothing.
/// - **Clean-up is by name.** Cancelling, leaving the screen and switching the source ask the
///   original hub (its address, this device's credential, the pinned certificate) to cancel this
///   run's own session and ask the board to cancel this run's own request id. Either is tried even
///   when the other fails, and what could not be delivered is reported, not hidden. A board that
///   is already enrolled is never touched by this (`pb-cancel` cannot remove its marker, Dataset
///   or Thread link).
/// - **Secrets stay in memory.** The setup code and the PSKd live only in the run and are
///   dropped with it. They are never shown, copied, logged, stored or put into an error. Swift and
///   the Security 2 code release their copies; nothing here can overwrite them.
@MainActor
@Observable
final class PowerBaseEnrollmentBLEController {
    typealias Target = PowerBaseEnrollmentController.Target
    typealias Ineligibility = PowerBaseEnrollmentController.Ineligibility

    /// What became of the request to the board to cancel this run's attempt.
    nonisolated enum BoardCancel: Equatable, Sendable {
        /// No `pb-start` was ever sent: there is nothing to cancel.
        case notNeeded
        /// The board took the cancel (`OK`).
        case taken
        /// `NO_SUCH_ATTEMPT`: the board has no attempt it could cancel under this request id (it
        /// ended, the board enrolled, or the request never arrived).
        case nothingToCancel
        /// The board answered and did not take the cancel (`BUSY`, `CLOSED`, `WRONG_TARGET`, …).
        /// That says nothing about its attempt: a board that closed BLE enrollment after too many
        /// failed handshakes carries on with a Joiner it already runs.
        case refused(PowerBaseBLECode)
        /// The cancel was sent and no usable answer came back: the board may or may not have
        /// taken it.
        case unconfirmed
        /// The board could not be reached. Its attempt, if it has one, ends by its own time limits.
        case notDelivered
    }

    /// What became of the request to the hub to cancel this run's session.
    nonisolated enum HubCancel: Equatable, Sendable {
        /// No session was ever asked for.
        case notNeeded
        case cancelled(PowerBaseEnrollmentSession)
        /// The session had ended first; this is the hub's final state.
        case alreadyFinal(PowerBaseEnrollmentSession)
        /// The request did not get through. The session ends at the hub's own deadline.
        case notDelivered(PowerBaseEnrollmentError)
        /// A `POST` got no answer, so it is unknown whether a session exists; without its id
        /// nothing can be cancelled.
        case unknownSession
    }

    nonisolated struct Cleanup: Equatable, Sendable {
        var hub: HubCancel
        var board: BoardCancel
    }

    /// What the board last said about this run's request. Never a success by itself.
    nonisolated enum BoardProgress: Equatable, Sendable {
        /// `ACCEPTED` / `DUPLICATE`: the board has the request. (`REQUEST_CONFLICT` is not this.)
        case accepted
        case queued
        case joining
        case attaching
        /// Attached and recorded on the board. The hub's heartbeat is still a separate matter.
        case enrolled
        case failed(result: UInt8)
        case cancelled
        /// The board doesn't know this request id (any more).
        case forgotten
        /// The Bluetooth connection ended and could not be made again. Normal right after the
        /// board enrolls (it shuts Bluetooth down); otherwise the board carries on by itself.
        case unreachable
    }

    nonisolated enum Delivery: Equatable, Sendable {
        case notSent
        case accepted
        /// `pb-start` was sent, the answer was lost, and the board could not be asked afterwards.
        case uncertain
    }

    nonisolated struct Outcome: Equatable, Sendable {
        /// The hub's final state -- the only thing that decides success.
        var session: PowerBaseEnrollmentSession
        var delivery: Delivery
        var boardProgress: BoardProgress?
        /// Set when this run cleaned up (explicit cancel).
        var cleanup: Cleanup?
    }

    nonisolated enum Phase: Equatable, Sendable {
        case idle
        /// Connecting, checking the GATT service and `proto-ver`, Security 2, then `pb-status`.
        case authenticating
        /// The `POST` is under way.
        case requestingHub
        /// The `POST` got no answer. Nothing was sent to the board; a new start is blocked until
        /// the tester asks the hub again or cancels.
        case hubUncertain
        /// The hub is `preparing`. Nothing has been sent to the board.
        case preparingHub(PowerBaseEnrollmentSession)
        /// The hub is `waiting_for_heartbeat`; the challenge and `pb-start` are under way.
        case delivering(PowerBaseEnrollmentSession)
        /// The board has the request; see `boardProgress`. The hub is still waiting.
        case joining(PowerBaseEnrollmentSession)
        /// `pb-start` may or may not have reached the board. The hub's session is followed.
        case deliveryUncertain(PowerBaseEnrollmentSession)
        /// A session of this device with a PSKd this run doesn't have. Followed; can be cancelled.
        case earlierHubSession(PowerBaseEnrollmentSession)
        /// Cleaning up on the hub and the board.
        case cancelling
        case finished(Outcome)
        case failed(Failure)
    }

    nonisolated enum Failure: Equatable, Sendable {
        // Nothing was sent anywhere.
        case invalidEUI64
        case invalidSetupCode
        /// The picked board advertises another EUI-64 than the one the tester confirmed.
        case advertisedNameMismatch
        case randomnessUnavailable
        case credentialUnavailable
        case bluetooth(PowerBaseBLEAvailability)
        case boardNotFound

        // The board was contacted; the hub was not.
        case connectionFailed(String)
        /// The GATT service or `proto-ver` isn't the specified one.
        case protocolMismatch(String)
        /// The board refused the proof: wrong setup code, or not the board with this EUI-64.
        case authenticationFailed
        /// The board refused to start a handshake: BLE enrollment is closed or locked for this boot.
        case handshakeRefused
        /// The board could not prove it knows this EUI-64's verifier.
        case boardProofMismatch
        /// The authenticated board reports another EUI-64 than the expected one.
        case differentBoard(actual: String)
        case boardNotWaiting(String)
        /// Another BLE-started attempt is in progress on the board.
        case boardBusy
        case boardClosed
        /// The board cannot run a Joiner.
        case boardUnavailable

        // A hub session existed; `cleanup` says what became of it and of the board's attempt.
        case hub(PowerBaseEnrollmentError, board: BoardCancel?)
        case boardRefused(PowerBaseBLECode, cleanup: Cleanup)
        /// The board could not be reached to deliver the request.
        case boardUnreachable(cleanup: Cleanup)
        case boardProblem(Problem, cleanup: Cleanup)
        /// The board's attempt ended without enrolling (`result` is a `pb_enroll_result_t`).
        case boardAttemptFailed(result: UInt8, cleanup: Cleanup)
        /// Cancelled before any hub session existed.
        case stopped(Cleanup)
        case sourceChanged
    }

    /// A problem with the board found while a hub session already existed.
    nonisolated enum Problem: Equatable, Sendable {
        case differentBoard(actual: String)
        case notWaiting(String)
        case busy
        case closed
        case unavailable
        case protocolMismatch(String)
        case authenticationFailed
    }

    /// What a clean-up after leaving the screen or switching the source did, for the screen that
    /// is shown afterwards.
    nonisolated struct CleanupReport: Equatable, Sendable {
        var eui64: String
        var cleanup: Cleanup
    }

    // MARK: - State

    private(set) var phase: Phase = .idle
    private(set) var boardProgress: BoardProgress?
    /// When the hub's window ends, from its last `expires_in_ms` (guidance only).
    private(set) var expiresAround: Date?
    /// A problem while following the hub's session that may clear up.
    private(set) var pollProblem: PowerBaseEnrollmentError?
    private(set) var target: Target = .none
    private(set) var availability: PowerBaseBLEAvailability = .unknown
    private(set) var boards: [PowerBaseBLEDiscoveredBoard] = []
    private(set) var isScanning = false
    /// Scanning has gone on for a while without finding any board.
    private(set) var foundNothingSoFar = false
    /// The app is in the background: no Bluetooth command and no request to the hub is started
    /// until it is active again.
    private(set) var isSuspended = false

    var ineligibility: Ineligibility? { target.ineligibility }

    var isBusy: Bool {
        switch phase {
        case .authenticating, .requestingHub, .hubUncertain, .preparingHub, .delivering, .joining, .deliveryUncertain,
             .earlierHubSession, .cancelling:
            return true
        case .idle, .finished, .failed:
            return false
        }
    }

    var canStart: Bool { ineligibility == nil && !isBusy && availability == .poweredOn }

    var canCancel: Bool { isBusy && phase != .cancelling }

    /// The run under way. The credential, the setup code and the PSKd stay here, out of every view.
    private struct Run {
        let generation: Int
        let hubID: String
        var baseURL: URL
        let credential: HubCredential
        var sessionID: String?
        /// A `POST` was sent, so a session may exist on the hub even without an answer.
        var postSent = false
        /// What the board said to this run's cancel before the hub session had to be followed
        /// again (the cancel did not reach the hub). The board is not asked a second time.
        var earlierBoardCancel: BoardCancel?

        // Absent when only an earlier hub session is followed.
        var bluetooth: Bluetooth?
    }

    private struct Bluetooth {
        let boardID: UUID
        let eui64: PowerBaseBLEEUI64
        let setupCode: String
        var pskd: String?
        var requestID: PowerBaseBLERequestID?
        var board: (any PowerBaseBLEBoardSession)?
        /// A `pb-start` left this device: the board may have an attempt under this request id.
        var startSent = false
        /// The last `pb-start` got no answer and the board has not been asked about it since.
        var startUnanswered = false
        var delivery = Delivery.notSent
        var reconnects = 0
        /// Authenticating again failed in a way a retry can't fix (or must not be retried).
        var reconnectForbidden = false
    }

    private let provider: PowerBaseBLEBoardProviding
    private let transport: PowerBaseEnrollmentTransport
    private let credentials: HubCredentialStoring
    private let pollInterval: Duration
    private let boardPollInterval: Duration
    private let leaveGrace: Duration
    private let quietScanPeriod: Duration
    private let maxReconnects: Int
    private let randomBytes: (Int) -> [UInt8]?
    private let now: () -> Date
    /// Called when a clean-up that no screen shows any more (leaving, another source) is done.
    var onCleanupReport: ((CleanupReport) -> Void)?

    private var run: Run?
    private var generation = 0
    /// The driver returns the id of a hub session whose `POST` answer arrived after its run ended.
    private var driver: Task<String?, Never>?
    private var monitor: Task<Void, Never>?
    private var leaveTask: Task<Void, Never>?
    private var quietScanTask: Task<Void, Never>?
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []
    /// How often the app went to the background. A delivery compares it to tell that the app was
    /// away in between, even if it is back by now.
    private var suspensions = 0
    /// Closed while the app is in the background and until the hub has been asked once after it.
    private var boardGateClosed = false
    private var boardGateWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        provider: PowerBaseBLEBoardProviding,
        transport: PowerBaseEnrollmentTransport = URLSessionPowerBaseEnrollmentTransport(),
        credentials: HubCredentialStoring = KeychainHubCredentialStore(),
        pollInterval: Duration = .seconds(1),
        boardPollInterval: Duration = .seconds(2),
        leaveGrace: Duration = .milliseconds(600),
        quietScanPeriod: Duration = .seconds(8),
        maxReconnects: Int = 3,
        randomBytes: @escaping (Int) -> [UInt8]? = SecureRandomBytes.system,
        now: @escaping () -> Date = Date.init
    ) {
        self.provider = provider
        self.transport = transport
        self.credentials = credentials
        self.pollInterval = pollInterval
        self.boardPollInterval = boardPollInterval
        self.leaveGrace = leaveGrace
        self.quietScanPeriod = quietScanPeriod
        self.maxReconnects = maxReconnects
        self.randomBytes = randomBytes
        self.now = now
    }

    // MARK: - Bluetooth and scanning

    /// Starts using Bluetooth (the system asks for permission the first time). Does not scan.
    func activate() {
        provider.onChange = { [weak self] in self?.providerDidChange() }
        provider.activate()
        providerDidChange()
    }

    /// Looks for boards. Ignored while a run is under way.
    func startScanning() {
        guard !isBusy else { return }
        isScanning = true
        foundNothingSoFar = false
        provider.startScanning()
        providerDidChange()
        quietScanTask?.cancel()
        let period = quietScanPeriod
        quietScanTask = Task { [weak self] in
            guard (try? await Task.sleep(for: period)) != nil, let self, self.isScanning, self.boards.isEmpty else { return }
            self.foundNothingSoFar = true
        }
    }

    func stopScanning() {
        isScanning = false
        foundNothingSoFar = false
        quietScanTask?.cancel()
        quietScanTask = nil
        provider.stopScanning()
    }

    private func providerDidChange() {
        availability = provider.availability
        boards = provider.boards
        if !boards.isEmpty { foundNothingSoFar = false }
    }

    // MARK: - Source

    /// The app now reads `newTarget`. The same hub at another address keeps its session there
    /// (same credential, same pinned certificate); anything else ends the run, cleans up on the
    /// original hub and board, and drops every result that belonged to the previous hub.
    func targetDidChange(_ newTarget: Target) {
        let previous = target
        target = newTarget
        if let run, ineligibility == nil, newTarget.hubID == run.hubID, let address = newTarget.baseURL {
            self.run?.baseURL = address
            return
        }
        guard newTarget.hubID != previous.hubID || ineligibility != nil else { return }
        if isBusy {
            abandon(showing: .failed(.sourceChanged))
        } else if phase != .idle {
            // A finished or failed test of the previous hub isn't this hub's.
            phase = .idle
            boardProgress = nil
        }
    }

    // MARK: - Lifecycle of the screen and the app

    /// The screen is visible (again).
    func screenDidAppear() {
        leaveTask?.cancel()
        leaveTask = nil
    }

    /// The screen went away. Treated as leaving only if it does not come back within a moment: a
    /// view that is rebuilt disappears and appears again at once, and that is not an exit.
    func screenDidDisappear() {
        leaveTask?.cancel()
        let grace = leaveGrace
        leaveTask = Task { [weak self] in
            guard (try? await Task.sleep(for: grace)) != nil else { return }
            self?.leave()
        }
    }

    /// The screen was really left: stop at once, clean up what runs, stop using Bluetooth.
    func leave() {
        leaveTask?.cancel()
        leaveTask = nil
        stopScanning()
        if isBusy {
            abandon(showing: .idle)
        } else {
            phase = .idle
            boardProgress = nil
        }
    }

    /// The app went to the background. Nothing is cancelled and nothing new is started: no
    /// Bluetooth command and no request to the hub until `sceneDidBecomeActive()`. A request that
    /// already left this device is still waited for.
    func sceneDidEnterBackground() {
        guard !isSuspended else { return }
        isSuspended = true
        suspensions += 1
        // Only closed when a hub loop will open it again.
        boardGateClosed = run?.sessionID != nil
    }

    /// Back in the foreground: the run carries on with what it kept, asking the hub first.
    func sceneDidBecomeActive() {
        guard isSuspended else { return }
        isSuspended = false
        let waiters = resumeWaiters
        resumeWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// Waits until the app is in the foreground. `false`: run `current` ended meanwhile (ending
    /// a run wakes everything that waits here), so nothing more may be started for it.
    private func waitUntilActive(_ current: Int) async -> Bool {
        while isSuspended, isCurrent(current) {
            await withCheckedContinuation { resumeWaiters.append($0) }
        }
        return isCurrent(current)
    }

    /// For the board monitor: active again, and the hub has been asked since. `false`: the run
    /// ended meanwhile.
    private func waitForBoardGate(_ current: Int) async -> Bool {
        while isCurrent(current) {
            if isSuspended {
                await withCheckedContinuation { resumeWaiters.append($0) }
            } else if boardGateClosed {
                await withCheckedContinuation { boardGateWaiters.append($0) }
            } else {
                return true
            }
        }
        return false
    }

    /// The app is, or has been, in the background since `turn` (a value of `suspensions`).
    private func wasInterrupted(since turn: Int) -> Bool {
        isSuspended || suspensions != turn
    }

    /// When an opening of a Bluetooth session may send its next command.
    private nonisolated enum OpenRule: Sendable {
        /// No hub session exists yet: wait for the foreground, then carry on with the same opening.
        case whenActive
        /// The board monitor: wait for the foreground and for the hub's answer after it.
        case afterHub
        /// Delivering, inside the hub loop: only while the app has stayed in the foreground since
        /// `turn`. Otherwise the opening is given up, so that the hub is asked first.
        case uninterrupted(since: Int)
    }

    /// What the provider asks before each new command of an opening for run `current`. Throws when
    /// the command must not be sent: the run ended, or (while delivering) the app was away.
    private func permit(_ current: Int, _ rule: OpenRule) -> PowerBaseBLESendPermit {
        { [weak self] in
            guard let self else { throw CancellationError() }
            let allowed: Bool
            switch rule {
            case .whenActive: allowed = await self.waitUntilActive(current)
            case .afterHub: allowed = await self.waitForBoardGate(current)
            case let .uninterrupted(turn): allowed = self.isCurrent(current) && !self.wasInterrupted(since: turn)
            }
            guard allowed else { throw CancellationError() }
        }
    }

    private func openBoardGate() {
        guard boardGateClosed, !isSuspended else { return }
        boardGateClosed = false
        let waiters = boardGateWaiters
        boardGateWaiters = []
        waiters.forEach { $0.resume() }
    }

    // MARK: - Actions

    /// Starts a run for the board `boardID` (a scan result), which the tester expects to be the
    /// board with EUI-64 `expectedEUI64` and setup code `setupCode`. Ignored while a run is under
    /// way, while the source isn't eligible, or while Bluetooth isn't on.
    func start(boardID: UUID, expectedEUI64: String, setupCode: String) {
        guard !isBusy, ineligibility == nil, let hubID = target.hubID, let baseURL = target.baseURL else { return }
        guard availability == .poweredOn else {
            phase = .failed(.bluetooth(availability))
            return
        }
        guard let normalized = PowerBaseEUI64.normalized(expectedEUI64), let eui64 = PowerBaseBLEEUI64(hex: normalized) else {
            phase = .failed(.invalidEUI64)
            return
        }
        guard let code = PowerBaseSetupCode.normalized(setupCode) else {
            phase = .failed(.invalidSetupCode)
            return
        }
        guard let board = boards.first(where: { $0.id == boardID }) else {
            phase = .failed(.boardNotFound)
            return
        }
        // The name proves nothing, but a name that says another board means the wrong row was
        // picked -- and a handshake with it would cost that board one of its five tries.
        if let advertised = board.advertisedEUI64, advertised != eui64.hex {
            phase = .failed(.advertisedNameMismatch)
            return
        }
        let credential: HubCredential
        do {
            guard let stored = try credentials.credential(forHubID: hubID), stored.hubID.lowercased() == hubID.lowercased() else {
                phase = .failed(.credentialUnavailable)
                return
            }
            credential = stored
        } catch {
            phase = .failed(.credentialUnavailable)
            return
        }

        stopScanning()
        generation += 1
        let current = generation
        run = Run(
            generation: current, hubID: hubID, baseURL: baseURL, credential: credential,
            bluetooth: Bluetooth(boardID: boardID, eui64: eui64, setupCode: code)
        )
        boardProgress = nil
        expiresAround = nil
        pollProblem = nil
        phase = .authenticating
        driver = Task { [weak self] in await self?.authenticateAndAsk(current) }
    }

    /// After a `POST` without an answer: asks the hub again, with the same EUI-64 and the same
    /// PSKd. The hub either accepts it now (then it had no session) or answers with the session it
    /// already has -- whose PSKd this run cannot be sure of, so that one is only followed.
    func askHubAgain() {
        guard phase == .hubUncertain, let run else { return }
        let current = run.generation
        driver = Task { [weak self] in await self?.ask(current) }
    }

    /// Stops the run and cleans up: the hub is asked to cancel this run's session and the board to
    /// cancel this run's request. A second tap while that is under way does nothing.
    func cancel() {
        guard canCancel, let snapshot = detach() else { return }
        phase = .cancelling
        let ended = generation
        Task { [weak self, provider, transport] in
            let cleanup = await Self.cleanUp(snapshot, reconnectWith: provider, transport: transport)
            self?.cancelDidFinish(cleanup, snapshot: snapshot, generation: ended)
        }
    }

    // MARK: - Step 1 and 2: the board, then the hub

    private func isCurrent(_ current: Int) -> Bool {
        current == generation && run?.generation == current && !Task.isCancelled
    }

    private func authenticateAndAsk(_ current: Int) async -> String? {
        guard isCurrent(current), let bluetooth = run?.bluetooth else { return nil }
        let board: any PowerBaseBLEBoardSession
        do {
            board = try await provider.openSession(
                boardID: bluetooth.boardID, eui64: bluetooth.eui64, setupCode: bluetooth.setupCode, permit: permit(current, .whenActive)
            )
        } catch {
            if isCurrent(current) { fail(current, Self.failure(for: error)) }
            return nil
        }
        guard isCurrent(current) else {
            await board.close()
            return nil
        }
        run?.bluetooth?.board = board

        // The board's own word for who it is, inside the session. A new command: it waits for the
        // foreground like the handshake's messages did.
        guard await waitUntilActive(current) else { return nil }
        let status: PowerBaseBLEStatus
        do {
            status = try await board.status(issueChallenge: false, requestID: nil)
        } catch {
            if isCurrent(current) { fail(current, Self.failure(forRequest: error)) }
            return nil
        }
        guard isCurrent(current) else { return nil }
        if let problem = Self.problem(in: status, expected: bluetooth.eui64) {
            fail(current, Self.failure(for: problem))
            return nil
        }

        // Only now, with the right board on the line, are the secrets for the hub made.
        guard let pskd = ThreadPSKd.generate(randomBytes: randomBytes), let requestID = PowerBaseBLERequestID.random(randomBytes) else {
            fail(current, .randomnessUnavailable)
            return nil
        }
        run?.bluetooth?.pskd = pskd
        run?.bluetooth?.requestID = requestID
        return await ask(current)
    }

    /// The `POST`, and what follows from its answer.
    private func ask(_ current: Int) async -> String? {
        // A hub session is never asked for in the background.
        guard await waitUntilActive(current), let run, let bluetooth = run.bluetooth, let pskd = bluetooth.pskd else { return nil }
        phase = .requestingHub
        self.run?.postSent = true
        // In a task of its own: ending the run cancels the driver, and a POST cut off half-way
        // would leave a session nobody knows the id of. This one always runs to its answer.
        let post = Task { [transport, eui64 = bluetooth.eui64.hex] in
            try await transport.start(baseURL: run.baseURL, credential: run.credential, eui64: eui64, pskd: pskd)
        }
        let result = await post.result
        guard isCurrent(current) else {
            // The run ended while the POST was under way: its clean-up cancels this session.
            if case let .success(accepted) = result, !accepted.state.isFinal { return accepted.sessionID }
            return nil
        }
        switch result {
        case let .success(session):
            self.run?.sessionID = session.sessionID
            await follow(current, from: session)
        case let .failure(PowerBaseEnrollmentError.enrollmentInProgress(own?)):
            // This device's session from an earlier start. Its PSKd is not this run's: the board
            // gets nothing, and the Bluetooth session is over.
            let board = bluetooth.board
            self.run?.bluetooth = nil
            self.run?.sessionID = own.sessionID
            boardProgress = nil
            Task { await board?.close() }
            await follow(current, from: own)
        case let .failure(error):
            let error = error as? PowerBaseEnrollmentError ?? .unreachable("HTTP")
            switch error {
            case .unreachable, .badResponse:
                // No usable answer: the hub may or may not have a session now.
                phase = .hubUncertain
            default:
                // The hub said no: there is no session.
                self.run?.postSent = false
                fail(current, .hub(error, board: nil))
            }
        }
        return nil
    }

    // MARK: - Step 3 to 5: following the hub, delivering once, watching the board

    private func follow(_ current: Int, from first: PowerBaseEnrollmentSession) async {
        var session = first
        while isCurrent(current) {
            if session.state.isFinal {
                finish(current, session)
                return
            }
            expiresAround = now().addingTimeInterval(TimeInterval(session.expiresInMs) / 1000)
            guard let bluetooth = run?.bluetooth else {
                phase = .earlierHubSession(session)
                guard let next = await nextHubState(current, after: session) else { return }
                session = next
                continue
            }

            switch (session.state, bluetooth.delivery) {
            case (.waitingForHeartbeat, .notSent):
                phase = .delivering(session)
                switch await deliver(current) {
                case let .accepted(progress):
                    run?.bluetooth?.delivery = .accepted
                    boardProgress = progress
                    phase = .joining(session)
                    startMonitoringBoard(current)
                case let .attemptEnded(progress, result):
                    // The board had the request, and its attempt is over without enrolling.
                    run?.bluetooth?.delivery = .accepted
                    boardProgress = progress
                    endWithCleanup(current, .boardAttemptFailed(result: result, cleanup: Self.pendingCleanup))
                    return
                case .uncertain:
                    run?.bluetooth?.delivery = .uncertain
                    phase = .deliveryUncertain(session)
                case .postponed:
                    break
                case let .failed(problem, code):
                    endWithCleanup(current, problem: problem, code: code)
                    return
                case .stale:
                    return
                }
            case (_, .accepted):
                phase = .joining(session)
            case (_, .uncertain):
                phase = .deliveryUncertain(session)
            case (_, .notSent):
                phase = .preparingHub(session)
            }

            guard let next = await nextHubState(current, after: session) else { return }
            session = next
        }
    }

    /// Waits a poll interval (and for the app to be active) and asks the hub. `nil`: the run is no
    /// longer this one, or it ended here.
    private func nextHubState(_ current: Int, after session: PowerBaseEnrollmentSession) async -> PowerBaseEnrollmentSession? {
        while isCurrent(current) {
            guard (try? await Task.sleep(for: pollInterval)) != nil else { return nil }
            guard await waitUntilActive(current), let run, let sessionID = run.sessionID else { return nil }
            do {
                let answer = try await transport.status(baseURL: run.baseURL, credential: run.credential, sessionID: sessionID)
                guard isCurrent(current) else { return nil }
                pollProblem = nil
                openBoardGate()
                return answer
            } catch {
                guard isCurrent(current) else { return nil }
                openBoardGate()
                let error = error as? PowerBaseEnrollmentError ?? .unreachable("HTTP")
                if error.isTransient {
                    pollProblem = error
                } else {
                    // 401, 404, a changed certificate…: the session can't be followed any more.
                    endWithCleanup(current, .hub(error, board: nil))
                    return nil
                }
            }
        }
        return nil
    }

    private enum DeliveryResult {
        /// The board has the request; the progress is what it said about it.
        case accepted(BoardProgress)
        /// The board had the request and its attempt ended without enrolling.
        case attemptEnded(BoardProgress, result: UInt8)
        case uncertain
        /// The app is, or was meanwhile, in the background: the hub is asked first, then again.
        case postponed
        case failed(Problem?, PowerBaseBLECode?)
        case stale
    }

    /// The challenge and the one `pb-start`. Returns `.accepted` only when the board said it has
    /// the request: `ACCEPTED` or `DUPLICATE` to the start, or, asked by request id, an attempt
    /// that is queued, running or enrolled.
    private func deliver(_ current: Int) async -> DeliveryResult {
        // Right after the hub's answer. If the app is away at any time before this is done, the
        // rest waits for the hub's next answer.
        let turn = suspensions
        var challengeRetries = 0
        // The board answered this run's start with `REQUEST_CONFLICT`.
        var conflicted = false
        while true {
            guard isCurrent(current), let bluetooth = run?.bluetooth, let requestID = bluetooth.requestID, let pskd = bluetooth.pskd else { return .stale }
            if wasInterrupted(since: turn) { return .postponed }

            // A session: the one from step 1, or a new one if that connection is gone.
            let board: any PowerBaseBLEBoardSession
            if let live = bluetooth.board {
                board = live
            } else {
                switch await reconnect(current, .uninterrupted(since: turn)) {
                case let .connected(session): board = session
                case .stale: return .stale
                case .suspended: return .postponed
                case let .failed(problem):
                    // Never sent: nothing started. Sent before, answer lost, and now no way to ask.
                    return bluetooth.startSent ? .uncertain : .failed(problem, nil)
                }
                if wasInterrupted(since: turn) { return .postponed }
            }

            // A challenge of this session -- and, in the same answer, what the board has under
            // this request id (a start whose answer was lost, or one it answered with a conflict).
            let status: PowerBaseBLEStatus
            do {
                status = try await board.status(issueChallenge: !conflicted, requestID: requestID)
            } catch {
                guard isCurrent(current) else { return .stale }
                dropBoardSession()
                if let problem = Self.unrecoverable(error) { return bluetooth.startSent ? .uncertain : .failed(problem, nil) }
                continue
            }
            guard isCurrent(current) else { return .stale }
            guard status.eui64 == bluetooth.eui64 else { return .failed(.differentBoard(actual: status.eui64.hex), nil) }
            // The board has said what it has under this request id.
            run?.bluetooth?.startUnanswered = false
            switch Self.requestState(in: status) {
            case let .active(progress):
                return .accepted(progress)
            case .enrolled:
                return .accepted(.enrolled)
            case let .failed(result):
                return .attemptEnded(.failed(result: result), result: result)
            case let .cancelled(result):
                return .attemptEnded(.cancelled, result: result)
            case .unknown:
                break
            }
            // The board has nothing under this request id.
            if conflicted { return .failed(nil, .requestConflict) }
            if let problem = Self.problem(in: status, expected: bluetooth.eui64) { return .failed(problem, nil) }
            guard let challenge = status.challenge else { return .failed(.protocolMismatch("challenge"), nil) }
            if wasInterrupted(since: turn) { return .postponed }

            run?.bluetooth?.startSent = true
            let code: PowerBaseBLECode
            do {
                code = try await board.start(target: bluetooth.eui64, requestID: requestID, challenge: challenge, pskd: pskd)
            } catch {
                guard isCurrent(current) else { return .stale }
                // The answer is lost; the board may have the request. The next round asks it by
                // request id on a new session, and sends the same request again only if it doesn't.
                run?.bluetooth?.startUnanswered = true
                dropBoardSession()
                if Self.unrecoverable(error) != nil { return .uncertain }
                continue
            }
            guard isCurrent(current) else { return .stale }
            switch code {
            case .accepted, .duplicate:
                return .accepted(.accepted)
            case .requestConflict:
                // Not an acceptance. The board knows this request id, but not as the request it
                // was just sent: an attempt under it has ended, or one is under way with other
                // content. This id only ever travelled with this run's board and PSKd, so "other
                // content" can only be an earlier copy of this start with an earlier challenge.
                // Which of these it is, the next round reads from `pb-status` -- without a new
                // challenge, without a second start and never under a new request id.
                conflicted = true
            case .challengeExpired, .challengeInvalid:
                challengeRetries += 1
                if challengeRetries > 2 { return .failed(nil, code) }
            case .busy:
                return .failed(.busy, nil)
            case .closed:
                return .failed(.closed, nil)
            case .unavailable:
                return .failed(.unavailable, nil)
            case .notWaiting:
                return .failed(.notWaiting("-"), nil)
            default:
                return .failed(nil, code)
            }
        }
    }

    private enum Reconnect {
        case connected(any PowerBaseBLEBoardSession)
        case failed(Problem?)
        /// The app is, or was meanwhile, in the background: no Bluetooth command now.
        case suspended
        case stale
    }

    /// Connects and authenticates again, a limited number of times per run. A refusal of the
    /// credentials is never tried twice. `rule` says what the opening does about the background.
    private func reconnect(_ current: Int, _ rule: OpenRule) async -> Reconnect {
        while isCurrent(current), let bluetooth = run?.bluetooth {
            if isAway(rule) { return .suspended }
            guard !bluetooth.reconnectForbidden, bluetooth.reconnects < maxReconnects else { return .failed(nil) }
            run?.bluetooth?.reconnects += 1
            do {
                let board = try await provider.openSession(
                    boardID: bluetooth.boardID, eui64: bluetooth.eui64, setupCode: bluetooth.setupCode, permit: permit(current, rule)
                )
                guard isCurrent(current) else {
                    await board.close()
                    return .stale
                }
                run?.bluetooth?.board = board
                return .connected(board)
            } catch {
                guard isCurrent(current) else { return .stale }
                if case .uninterrupted = rule, isAway(rule) {
                    // Given up because the app went away, not failed: it doesn't use up a try.
                    run?.bluetooth?.reconnects -= 1
                    return .suspended
                }
                switch Self.failure(for: error) {
                case .connectionFailed, .boardNotFound, .bluetooth:
                    continue
                case .authenticationFailed, .handshakeRefused, .boardProofMismatch:
                    run?.bluetooth?.reconnectForbidden = true
                    return .failed(.authenticationFailed)
                case let .protocolMismatch(detail):
                    run?.bluetooth?.reconnectForbidden = true
                    return .failed(.protocolMismatch(detail))
                default:
                    run?.bluetooth?.reconnectForbidden = true
                    return .failed(nil)
                }
            }
        }
        return .stale
    }

    private func isAway(_ rule: OpenRule) -> Bool {
        if case let .uninterrupted(turn) = rule { return wasInterrupted(since: turn) }
        return isSuspended
    }

    private func dropBoardSession() {
        guard let board = run?.bluetooth?.board else { return }
        run?.bluetooth?.board = nil
        Task { await board.close() }
    }

    private func startMonitoringBoard(_ current: Int) {
        monitor?.cancel()
        monitor = Task { [weak self] in await self?.monitorBoard(current) }
    }

    /// Asks the board about this run's request every so often, for display. Separate from the hub
    /// loop, so a slow or lost Bluetooth connection never delays the hub's answer.
    private func monitorBoard(_ current: Int) async {
        while isCurrent(current) {
            guard (try? await Task.sleep(for: boardPollInterval)) != nil else { return }
            guard await waitForBoardGate(current), let bluetooth = run?.bluetooth, let requestID = bluetooth.requestID else { return }

            let board: any PowerBaseBLEBoardSession
            if let live = bluetooth.board {
                board = live
            } else {
                switch await reconnect(current, .afterHub) {
                case let .connected(session):
                    board = session
                case .stale:
                    return
                case .suspended:
                    continue
                case .failed:
                    guard isCurrent(current) else { return }
                    // Normal right after the board enrolled: it shut Bluetooth down.
                    if boardProgress != .enrolled { boardProgress = .unreachable }
                    return
                }
                // The app may have been away while the session was opened.
                guard await waitForBoardGate(current) else { return }
            }

            let status: PowerBaseBLEStatus
            do {
                status = try await board.status(issueChallenge: false, requestID: requestID)
            } catch {
                guard isCurrent(current) else { return }
                dropBoardSession()
                if Self.unrecoverable(error) != nil { run?.bluetooth?.reconnectForbidden = true }
                continue
            }
            guard isCurrent(current) else { return }
            guard status.eui64 == bluetooth.eui64 else {
                endWithCleanup(current, .boardProblem(.differentBoard(actual: status.eui64.hex), cleanup: Self.pendingCleanup))
                return
            }
            switch Self.requestState(in: status) {
            case .unknown:
                boardProgress = .forgotten
                dropBoardSession()
                return
            case let .active(progress):
                boardProgress = progress
            case .enrolled:
                // The board is done and shuts Bluetooth down. Success is still the hub's to say.
                boardProgress = .enrolled
                dropBoardSession()
                return
            case let .failed(result):
                boardProgress = .failed(result: result)
                endWithCleanup(current, .boardAttemptFailed(result: result, cleanup: Self.pendingCleanup))
                return
            case let .cancelled(result):
                boardProgress = .cancelled
                endWithCleanup(current, .boardAttemptFailed(result: result, cleanup: Self.pendingCleanup))
                return
            }
        }
    }

    // MARK: - Ending

    /// Everything a clean-up needs, taken out of the controller: once a run is detached, the
    /// controller holds none of its secrets and none of its answers reach the screen.
    private struct Snapshot: Sendable {
        let baseURL: URL
        let credential: HubCredential
        let sessionID: String?
        let postSent: Bool
        let earlierBoardCancel: BoardCancel?
        let eui64: PowerBaseBLEEUI64?
        let requestID: PowerBaseBLERequestID?
        let board: (any PowerBaseBLEBoardSession)?
        let startSent: Bool
        let delivery: Delivery
        let boardProgress: BoardProgress?
        /// For one more connection, when the tester cancels and the session is gone.
        let boardID: UUID?
        let setupCode: String?
        let driver: Task<String?, Never>?
        let monitor: Task<Void, Never>?
    }

    /// Ends the run under way as far as the screen is concerned: a new generation, no polling, no
    /// secrets left here. Returns what its clean-up needs.
    private func detach() -> Snapshot? {
        guard let run else { return nil }
        // A start without an answer that the board was never asked about again may have arrived:
        // the run does not end as "nothing was sent".
        var delivery = run.bluetooth?.delivery ?? .notSent
        if delivery == .notSent, run.bluetooth?.startUnanswered == true { delivery = .uncertain }
        let snapshot = Snapshot(
            baseURL: run.baseURL, credential: run.credential, sessionID: run.sessionID, postSent: run.postSent,
            earlierBoardCancel: run.earlierBoardCancel, eui64: run.bluetooth?.eui64, requestID: run.bluetooth?.requestID, board: run.bluetooth?.board,
            startSent: run.bluetooth?.startSent ?? false, delivery: delivery, boardProgress: boardProgress,
            boardID: run.bluetooth?.boardID, setupCode: run.bluetooth?.setupCode, driver: driver, monitor: monitor
        )
        generation += 1
        driver?.cancel()
        monitor?.cancel()
        driver = nil
        monitor = nil
        self.run = nil
        // Tasks of the ended run that wait for the app to be active see the new generation and stop.
        let waiting = resumeWaiters + boardGateWaiters
        resumeWaiters = []
        boardGateWaiters = []
        boardGateClosed = false
        waiting.forEach { $0.resume() }
        expiresAround = nil
        pollProblem = nil
        return snapshot
    }

    /// The hub reported a final state: that is the result. The board is not asked to cancel
    /// anything (it may be enrolled, or on its way); only the connection is closed.
    private func finish(_ current: Int, _ session: PowerBaseEnrollmentSession) {
        guard isCurrent(current), let snapshot = detach() else { return }
        // A cancel that reached the board but not the hub is still part of what happened.
        let cleanup = snapshot.earlierBoardCancel.map { Cleanup(hub: .alreadyFinal(session), board: $0) }
        phase = .finished(Outcome(session: session, delivery: snapshot.delivery, boardProgress: snapshot.boardProgress, cleanup: cleanup))
        Task { await snapshot.board?.close() }
    }

    /// A failure before any hub session and before any `pb-start`: nothing to clean up but the
    /// connection.
    private func fail(_ current: Int, _ failure: Failure) {
        guard isCurrent(current), let snapshot = detach() else { return }
        boardProgress = nil
        phase = .failed(failure)
        Task { await snapshot.board?.close() }
    }

    /// Placeholder inside a failure until the clean-up has reported.
    private static let pendingCleanup = Cleanup(hub: .notNeeded, board: .notNeeded)

    /// The request could not be delivered: the board refused it (`code`), is not in a state to
    /// take it (`problem`), or could not be reached (neither).
    private func endWithCleanup(_ current: Int, problem: Problem?, code: PowerBaseBLECode?) {
        if let code {
            endWithCleanup(current, .boardRefused(code, cleanup: Self.pendingCleanup))
        } else if let problem {
            endWithCleanup(current, .boardProblem(problem, cleanup: Self.pendingCleanup))
        } else {
            endWithCleanup(current, .boardUnreachable(cleanup: Self.pendingCleanup))
        }
    }

    /// The run cannot go on while a hub session (and perhaps a board attempt) exists: both are
    /// cancelled by name, then `failure` is shown with what the clean-up achieved. If the hub's
    /// session turns out to have ended first, the hub's final state is shown instead.
    private func endWithCleanup(_ current: Int, _ failure: Failure) {
        guard isCurrent(current), let snapshot = detach() else { return }
        phase = .cancelling
        let ended = generation
        // A hub that can no longer be asked about the session (401, 404, another certificate) is
        // not sent a cancel either; the board still is.
        let cancelHub = if case .hub = failure { false } else { true }
        Task { [weak self, transport] in
            let cleanup = await Self.cleanUp(snapshot, cancelHub: cancelHub, reconnectWith: nil, transport: transport)
            guard let self, self.generation == ended, self.phase == .cancelling else { return }
            if case let .alreadyFinal(final) = cleanup.hub {
                self.phase = .finished(Outcome(session: final, delivery: snapshot.delivery, boardProgress: snapshot.boardProgress, cleanup: cleanup))
                return
            }
            switch failure {
            case let .boardRefused(code, _): self.phase = .failed(.boardRefused(code, cleanup: cleanup))
            case .boardUnreachable: self.phase = .failed(.boardUnreachable(cleanup: cleanup))
            case let .boardProblem(problem, _): self.phase = .failed(.boardProblem(problem, cleanup: cleanup))
            case let .boardAttemptFailed(result, _): self.phase = .failed(.boardAttemptFailed(result: result, cleanup: cleanup))
            case let .hub(error, _): self.phase = .failed(.hub(error, board: cleanup.board))
            default: self.phase = .failed(failure)
            }
        }
    }

    private func cancelDidFinish(_ cleanup: Cleanup, snapshot: Snapshot, generation ended: Int) {
        guard generation == ended, phase == .cancelling else { return }
        switch cleanup.hub {
        case let .cancelled(session), let .alreadyFinal(session):
            // The hub's word, also when the session ended (even successfully) before the cancel.
            phase = .finished(Outcome(session: session, delivery: snapshot.delivery, boardProgress: snapshot.boardProgress, cleanup: cleanup))
        case let .notDelivered(error):
            guard let sessionID = snapshot.sessionID, error.isTransient else {
                phase = .failed(.hub(error, board: cleanup.board))
                return
            }
            // The session runs on at the hub. It is followed again, without any Bluetooth part,
            // and can be cancelled again.
            generation += 1
            let current = generation
            run = Run(generation: current, hubID: snapshot.credential.hubID, baseURL: target.baseURL ?? snapshot.baseURL,
                      credential: snapshot.credential, sessionID: sessionID, postSent: true, earlierBoardCancel: cleanup.board, bluetooth: nil)
            pollProblem = error
            boardProgress = snapshot.boardProgress
            phase = .cancelling
            driver = Task { [weak self] in
                await self?.resumeFollowing(current, sessionID: sessionID)
                return nil
            }
        case .notNeeded, .unknownSession:
            phase = .failed(.stopped(cleanup))
        }
    }

    /// After a cancel that did not reach the hub: ask for the session's state and follow it.
    private func resumeFollowing(_ current: Int, sessionID: String) async {
        while await waitUntilActive(current), let run {
            do {
                let session = try await transport.status(baseURL: run.baseURL, credential: run.credential, sessionID: sessionID)
                guard isCurrent(current) else { return }
                pollProblem = nil
                await follow(current, from: session)
                return
            } catch {
                guard isCurrent(current) else { return }
                let error = error as? PowerBaseEnrollmentError ?? .unreachable("HTTP")
                guard error.isTransient else {
                    fail(current, .hub(error, board: nil))
                    return
                }
                pollProblem = error
                guard (try? await Task.sleep(for: pollInterval)) != nil else { return }
            }
        }
    }

    /// Leaving or another source: the screen moves on at once, the clean-up runs behind it and
    /// reports to `onCleanupReport`.
    private func abandon(showing newPhase: Phase) {
        guard let snapshot = detach() else {
            phase = newPhase
            return
        }
        boardProgress = nil
        phase = newPhase
        let report = onCleanupReport
        Task { [transport] in
            let cleanup = await Self.cleanUp(snapshot, reconnectWith: nil, transport: transport)
            report?(CleanupReport(eui64: snapshot.eui64?.hex ?? "", cleanup: cleanup))
        }
    }

    /// Cancels a detached run by name: its own hub session on the hub it was started on, and its
    /// own request id on its board. Each is tried whatever happens to the other.
    ///
    /// `reconnectWith`: for an explicit cancel while the screen is shown, one more connection is
    /// made if the session is gone. Otherwise only a live session is used.
    private static func cleanUp(
        _ snapshot: Snapshot, cancelHub: Bool = true, reconnectWith provider: PowerBaseBLEBoardProviding?,
        transport: PowerBaseEnrollmentTransport
    ) async -> Cleanup {
        // First let the run's own tasks come to rest: a POST or a pb-start under way either
        // completes or fails, so the two cancels below are sent after them, never before.
        let lateSessionID = await snapshot.driver?.value
        await snapshot.monitor?.value

        async let board = cancelBoardAttempt(snapshot, reconnectWith: provider)
        guard cancelHub else { return await Cleanup(hub: .notNeeded, board: board) }
        async let hub = cancelHubSession(snapshot, sessionID: snapshot.sessionID ?? lateSessionID, transport: transport)
        return await Cleanup(hub: hub, board: board)
    }

    private nonisolated static func cancelHubSession(
        _ snapshot: Snapshot, sessionID: String?, transport: PowerBaseEnrollmentTransport
    ) async -> HubCancel {
        guard let sessionID else { return snapshot.postSent ? .unknownSession : .notNeeded }
        do {
            return .cancelled(try await transport.cancel(baseURL: snapshot.baseURL, credential: snapshot.credential, sessionID: sessionID))
        } catch let PowerBaseEnrollmentError.sessionAlreadyFinal(final) where final.sessionID == sessionID {
            return .alreadyFinal(final)
        } catch {
            return .notDelivered(error as? PowerBaseEnrollmentError ?? .unreachable("HTTP"))
        }
    }

    private static func cancelBoardAttempt(_ snapshot: Snapshot, reconnectWith provider: PowerBaseBLEBoardProviding?) async -> BoardCancel {
        defer { Task { await snapshot.board?.close() } }
        guard snapshot.startSent, let eui64 = snapshot.eui64, let requestID = snapshot.requestID else {
            return snapshot.earlierBoardCancel ?? .notNeeded
        }
        // Whether a cancel left this device without a usable answer coming back.
        var unanswered = false
        if let board = snapshot.board {
            do {
                return boardCancel(for: try await board.cancel(target: eui64, requestID: requestID))
            } catch PowerBaseBLEClientError.noSession {
                // The session was gone already: nothing was sent.
            } catch {
                unanswered = true
            }
        }
        // Cleaning up is not held back by the background.
        guard let provider, let boardID = snapshot.boardID, let setupCode = snapshot.setupCode,
              let board = try? await provider.openSession(boardID: boardID, eui64: eui64, setupCode: setupCode, permit: {}) else {
            return unanswered ? .unconfirmed : .notDelivered
        }
        let code = try? await board.cancel(target: eui64, requestID: requestID)
        await board.close()
        guard let code else { return .unconfirmed }
        return boardCancel(for: code)
    }

    /// The board's answer to `pb-cancel`. Only `OK` is a cancel, and only `NO_SUCH_ATTEMPT` says
    /// there is no attempt to cancel; every other code leaves the attempt's fate open.
    static func boardCancel(for code: PowerBaseBLECode) -> BoardCancel {
        switch code {
        case .ok: return .taken
        case .noSuchAttempt: return .nothingToCancel
        default: return .refused(code)
        }
    }

    // MARK: - Reading the board's answers

    /// What a `pb-status` answer says about the request id it was asked about.
    private nonisolated enum RequestState {
        /// The board has no attempt under this request id.
        case unknown
        /// Queued, or running (joining or attaching).
        case active(BoardProgress)
        /// Attached and recorded on the board. The hub's heartbeat is still a separate matter.
        case enrolled
        case failed(result: UInt8)
        case cancelled(result: UInt8)
    }

    /// Reads the request's own fields. The match flag alone only says that the board knows the
    /// id; whether its attempt is under way, enrolled or over is in the phase and the result, and
    /// while it runs the board's state says how far it is. The answer's code is no part of this:
    /// a board that closed BLE enrollment (`CLOSED`) still reports an attempt it carries on with.
    /// The caller has checked the EUI-64.
    private static func requestState(in status: PowerBaseBLEStatus) -> RequestState {
        guard status.flags.contains(.requestMatch) else { return .unknown }
        switch status.requestPhase {
        case .none: return .unknown
        case .queued: return .active(.queued)
        case .running: return .active(status.state == .attaching ? .attaching : .joining)
        case .enrolled: return .enrolled
        case .failed: return .failed(result: status.requestResult)
        case .cancelled: return .cancelled(result: status.requestResult)
        }
    }

    /// Why a board that just authenticated can't be given a start, if so.
    private static func problem(in status: PowerBaseBLEStatus, expected: PowerBaseBLEEUI64) -> Problem? {
        if status.eui64 != expected { return .differentBoard(actual: status.eui64.hex) }
        if status.code == .closed { return .closed }
        if status.code != .ok { return .protocolMismatch(status.code.name) }
        if status.flags.contains(.joinerUnavailable) { return .unavailable }
        if status.flags.contains(.attemptActive) { return .busy }
        switch status.state {
        case .waiting: return nil
        case .joining: return .notWaiting("joining")
        case .attaching: return .notWaiting("attaching")
        case .enrolled: return .notWaiting("enrolled")
        }
    }

    private static func failure(for problem: Problem) -> Failure {
        switch problem {
        case let .differentBoard(actual): return .differentBoard(actual: actual)
        case let .notWaiting(state): return .boardNotWaiting(state)
        case .busy: return .boardBusy
        case .closed: return .boardClosed
        case .unavailable: return .boardUnavailable
        case let .protocolMismatch(detail): return .protocolMismatch(detail)
        case .authenticationFailed: return .authenticationFailed
        }
    }

    /// A request error that authenticating again would not cure: the board speaks another protocol.
    private static func unrecoverable(_ error: Error) -> Problem? {
        switch error as? PowerBaseBLEClientError {
        case let .malformedResponse(codec)?: return .protocolMismatch(String(describing: codec))
        case let .refusedByBoard(code)?: return .protocolMismatch(code.name)
        case .invalidInput?: return .protocolMismatch("request")
        default: return nil
        }
    }

    private static func failure(forRequest error: Error) -> Failure {
        if let problem = unrecoverable(error) { return failure(for: problem) }
        return .connectionFailed("pb-status")
    }

    /// Why no session could be opened, as the screen names it. Nothing secret is in any of these.
    static func failure(for error: Error) -> Failure {
        switch error as? PowerBaseBLEOpenError {
        case let .bluetoothUnavailable(availability)?: return .bluetooth(availability)
        case .boardNotFound?: return .boardNotFound
        case let .connectionFailed(detail)?: return .connectionFailed(detail)
        case let .gattMismatch(detail)?: return .protocolMismatch(detail)
        case .cancelled?, nil: return .connectionFailed("cancelled")
        case let .client(client)?:
            switch client {
            case .versionUnreadable: return .connectionFailed("proto-ver")
            case let .unsupportedVersion(version): return .protocolMismatch(String(describing: version))
            case .handshakeInterrupted: return .connectionFailed("handshake")
            case .handshakeRefused: return .handshakeRefused
            case .authenticationFailed: return .authenticationFailed
            case .boardProofMismatch: return .boardProofMismatch
            case let .handshakeMalformed(detail): return .protocolMismatch(detail)
            case .noSession, .requestFailed, .decryptionFailed: return .connectionFailed("session")
            case let .malformedResponse(codec): return .protocolMismatch(String(describing: codec))
            case let .refusedByBoard(code): return .protocolMismatch(code.name)
            case let .invalidInput(detail): return .protocolMismatch(detail)
            }
        }
    }
}

extension PowerBaseEnrollmentController.Target {
    /// Why an enrollment test can't use this source; `nil` when it can. Only a hub picked in
    /// "Find hubs" (it has a `hub_id`), with a known address, that this device is paired with.
    var ineligibility: PowerBaseEnrollmentController.Ineligibility? {
        if isSimulated { return .simulatedData }
        guard hubID != nil else { return .typedAddress }
        guard baseURL != nil else { return .noAddress }
        guard isPaired else { return .notPaired }
        return nil
    }
}
#endif
