import Foundation
import Observation
import PowerBaseBLEKit

/// Resets a registered Power Base from the app, without its old hub: authenticates the board over
/// Bluetooth with its own setup code and -- only after the user confirmed it -- asks the board to
/// erase its own registration and stored network (firmware repository, docs/power-base.md
/// "BOOT 버튼 로컬 재등록"). Registering it with another hub afterwards is the ordinary
/// registration (`PowerBaseEnrollmentBLEController`); this type does none of that.
///
/// Nothing here talks to a hub. The old hub may be gone, switched off or unpaired: the board's
/// setup code and its own button are what authorise the reset. The hub the app reads now is only
/// shown (is the new one ready?) and, when it changes, ends a run that has not sent anything.
///
/// The rules:
/// - **The board is authenticated first**, and the EUI-64 it reports inside the session must be the
///   one that was picked. The advertised name only says whom to try.
/// - **Authentication erases nothing.** Nor does connecting, nor finding the board in the window
///   its button opened. Only `confirmReset()` sends the command, it is only callable while the
///   screen shows the confirmation, and the command cannot be encoded without the confirmation
///   value (`PowerBaseBLELocalResetConfirmation`).
/// - **One operation, asked about, never repeated.** The command carries an operation id that
///   this controller makes once. When its answer is lost, the connection drops or the screen is
///   left, the id is kept and every later connection *asks* what became of it
///   (`localResetStatus`). A second command is only ever sent by another explicit confirmation,
///   after the first one's outcome is known.
/// - **A command that left this device is never shown as cancelled.** Leaving the screen or
///   switching hubs then shows "outcome unknown", not "nothing happened".
/// - **Accepted, in progress, verified and registered are four things.** `ready(.resetVerified)`
///   is only shown for the board's own "verified" together with "not enrolled". Registration with
///   the new hub is the registration screen's business and ends with the hub's own word.
/// - **A run that is over starts nothing**, and **nothing new starts in the background**: before
///   the connection, each message of the opening, the board's status, the reset status, the
///   challenge, the reset command and every later question, this asks whether the run is still
///   the run and waits for the foreground. An answer that is under way is still taken; closing a
///   connection never waits.
/// - **A board without the capability is sent nothing else instead.**
/// - **Looking is not asking.** With `automaticSearch` (the product screen) the controller starts
///   using Bluetooth and scans by itself while the screen is on show, the app is in the
///   foreground and the phase is `idle` ("Automatic search" below). That only finds boards whose
///   own button opened their window: it opens no window, connects to nothing, authenticates
///   nothing and resets nothing. Those begin with `verify` and `confirmReset`, which only taps
///   call.
/// - The setup code is used for the one handshake and kept nowhere: not here, not in a log, not
///   in storage, not on the pasteboard.
@MainActor
@Observable
final class PowerBaseLocalResetController {
    nonisolated enum Phase: Equatable, Sendable {
        case idle
        /// Connecting and authenticating the board with the setup code.
        case connecting
        /// Inside the session: who the board is and what it holds.
        case checking
        /// Authenticated; the board holds a registration and its window is open. Nothing has been
        /// sent. Waiting for the user's explicit confirmation.
        case awaitingConfirmation
        /// The user confirmed: the command is being sent, or was accepted and the board is asked
        /// how far it got.
        case resetting
        /// A command left this device and what became of it is not known (yet).
        case uncertain(Uncertainty)
        /// The board holds no registration: it can be registered with a hub.
        case ready(Ready)
        case failed(Failure)
    }

    nonisolated enum Ready: Equatable, Sendable {
        /// The board said: this operation, erased and verified -- and it is not enrolled.
        case resetVerified
        /// The board held nothing to reset in the first place. Nothing was sent.
        case alreadyNotEnrolled
    }

    nonisolated enum Uncertainty: Equatable, Sendable {
        /// The command was sent and its answer (or a later one) did not arrive.
        case answerLost
        /// The board has the operation and has not verified it: it carries on at every restart.
        case boardStillWorking
        /// Asking the board about the operation did not work this time.
        case checkFailed(Failure)
    }

    nonisolated enum Failure: Equatable, Sendable {
        case invalidSetupCode
        case randomnessUnavailable
        case bluetooth(PowerBaseBLEAvailability)
        case boardNotFound
        /// The setup code (or the board it belongs to) was not accepted.
        case wrongSetupCode
        /// The board refuses sessions for now (too many wrong codes, or its time is over).
        case boardLocked
        case boardUnreachable
        /// The board that authenticated is not the one that was picked.
        case differentBoard
        /// The board's firmware has no local reset. Nothing else was sent in its place.
        case boardNeedsUpdate
        /// The board holds a registration, but the window its button opens is not open (the
        /// button was not held, or the two minutes are over). Nothing changed.
        case windowNotOpen
        /// The board's hub is removing it: that is finished first ("삭제 확인").
        case removalInProgress
        /// Another reset is under way on the board.
        case boardBusy
        /// The board ended this reset before it changed anything.
        case resetNotStarted
        case other
    }

    private(set) var phase: Phase = .idle
    private(set) var availability: PowerBaseBLEAvailability = .unknown
    private(set) var boards: [PowerBaseBLEDiscoveredBoard] = []
    private(set) var isScanning = false
    /// Bluetooth is in use for this screen: `activate()` was called (by the automatic search or
    /// by the user). From then on the screen shows what Bluetooth says.
    private(set) var usesBluetooth = false
    /// Scanning for a while without finding a board.
    private(set) var foundNothingSoFar = false
    /// The hub the app reads now: shown as "the new hub", never asked for anything here.
    private(set) var target: PowerBaseHubTarget = .none
    /// The app is in the background: no Bluetooth command is started until it is active again.
    private(set) var isSuspended = false
    /// Seconds the board's window had left when it was last asked (while `awaitingConfirmation`).
    private(set) var windowSecondsLeft = 0
    /// The EUI-64 of the board a run authenticated, lower-case hex; `nil` before that.
    private(set) var boardIdentifier: String?
    /// How many steps of a run wait for the foreground right now. For tests.
    var foregroundWaiters: Int { resumeWaiters.count }
    /// Tasks started for a run that have not come to their end. For tests.
    @ObservationIgnored private(set) var unfinishedRunTasks = 0

    /// A reset command that left this device and whose outcome is not settled. While this is set
    /// no new operation is made: every connection asks about this one.
    private struct PendingOperation {
        let id: PowerBaseBLEOperationID
        let eui64: PowerBaseBLEEUI64
    }

    private let provider: PowerBaseBLEBoardProviding
    /// The screen looks for boards by itself ("Automatic search").
    private let searchesAutomatically: Bool
    /// How long a screen that went away may take to come back before that counts as leaving.
    private let leaveGrace: Duration
    /// Between the screen's appearing and its really being left.
    private var isOnScreen = false
    /// This appearance of the screen has not had its search yet (it appeared in the background).
    private var owesAutomaticSearch = false
    /// The automatic search was stopped because the app went to the background; it goes on, with
    /// what it had found, when the app is back.
    private var searchPausedForBackground = false
    private var leaveTask: Task<Void, Never>?
    private let quietScanPeriod: Duration
    private let pollInterval: Duration
    private let maximumPolls: Int
    private let randomBytes: (Int) -> [UInt8]?
    private var generation = 0
    private var quietScanTask: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []
    private var session: (any PowerBaseBLEBoardSession)?
    private var sessionEUI64: PowerBaseBLEEUI64?
    private var pending: PendingOperation?

    init(
        provider: PowerBaseBLEBoardProviding,
        automaticSearch: Bool = false,
        leaveGrace: Duration = .milliseconds(600),
        quietScanPeriod: Duration = .seconds(8),
        pollInterval: Duration = .milliseconds(500),
        maximumPolls: Int = 20,
        randomBytes: @escaping (Int) -> [UInt8]? = PowerBaseBLERandom.system
    ) {
        self.provider = provider
        self.searchesAutomatically = automaticSearch
        self.leaveGrace = leaveGrace
        self.quietScanPeriod = quietScanPeriod
        self.pollInterval = pollInterval
        self.maximumPolls = maximumPolls
        self.randomBytes = randomBytes
    }

    var isBusy: Bool {
        switch phase {
        case .connecting, .checking, .resetting: return true
        case .idle, .awaitingConfirmation, .uncertain, .ready, .failed: return false
        }
    }

    /// A reset command was sent and its outcome is not settled: the next connection asks about
    /// it, and no other reset is offered meanwhile.
    var hasUnresolvedOperation: Bool { pending != nil }

    /// The board (by its EUI-64, lower-case hex) the unresolved operation was sent to.
    var unresolvedBoardIdentifier: String? { pending?.eui64.hex }

    var canVerify: Bool { !isBusy && phase != .awaitingConfirmation && availability == .poweredOn }

    var canConfirm: Bool { phase == .awaitingConfirmation && session != nil && pending == nil }

    // MARK: - Bluetooth and scanning

    /// Starts using Bluetooth (the system asks for permission the first time). Does not scan.
    /// Calling it again changes nothing: the provider is activated once.
    func activate() {
        guard !usesBluetooth else { return }
        usesBluetooth = true
        provider.onChange = { [weak self] in self?.providerDidChange() }
        provider.activate()
        providerDidChange()
    }

    /// Looks for boards, forgetting the ones seen so far. Ignored while a run is under way or
    /// waits for the user's confirmation.
    func startScanning() {
        guard !isBusy, phase != .awaitingConfirmation else { return }
        owesAutomaticSearch = false
        searchPausedForBackground = false
        isScanning = true
        foundNothingSoFar = false
        provider.startScanning()
        providerDidChange()
        startQuietScanTimer()
    }

    func stopScanning() {
        searchPausedForBackground = false
        isScanning = false
        foundNothingSoFar = false
        quietScanTask?.cancel()
        quietScanTask = nil
        provider.stopScanning()
    }

    /// After a while without a board, the screen says what to check.
    private func startQuietScanTimer() {
        quietScanTask?.cancel()
        let period = quietScanPeriod
        quietScanTask = Task { [weak self] in
            guard (try? await Task.sleep(for: period)) != nil, let self, self.isScanning, self.boards.isEmpty else { return }
            self.foundNothingSoFar = true
        }
    }

    private func providerDidChange() {
        let previous = availability
        availability = provider.availability
        boards = provider.boards
        if !boards.isEmpty { foundNothingSoFar = false }
        // Bluetooth came on -- switched on, or allowed at last -- while the screen waits for it:
        // the search starts (again) without a tap, with a full "nothing found yet" period.
        if previous != .poweredOn, availability == .poweredOn, mayAutomaticSearch {
            startScanning()
        }
    }

    // MARK: - Automatic search
    //
    // "다른 허브에 연결하기" does not wait for a "find" button: entering it is the user asking to
    // look. The same rules as the registration screen's controller, decided here and not by a
    // view that happens to be drawn:
    //
    // - Only discovery. A board shows up only while the window its own BOOT button opened is
    //   open; looking opens no window, and nothing here connects, authenticates or resets.
    // - Once per appearance: a rebuilt view, a sheet that goes away or a second `onAppear`
    //   starts nothing again, so the list and the selection made in it stay.
    // - Never in the background, and only while the phase is `idle`: not over a run, the
    //   confirmation, an unresolved command, a result or a failure.
    // - It ends when the screen is really left.

    /// A search may be started without a tap right now.
    private var mayAutomaticSearch: Bool {
        searchesAutomatically && isOnScreen && !isSuspended && phase == .idle
    }

    /// Starts the search this appearance still owes, or goes on with the one the background
    /// paused -- when this is a moment for it. Otherwise nothing happens (and it stays owed).
    private func searchAutomaticallyIfDue() {
        guard mayAutomaticSearch, !isScanning else { return }
        if searchPausedForBackground {
            activate()
            searchPausedForBackground = false
            isScanning = true
            provider.resumeScanning()
            providerDidChange()
            startQuietScanTimer()
        } else if owesAutomaticSearch {
            activate()
            // `activate()` may itself have started it (Bluetooth was on already).
            if !isScanning { startScanning() }
        }
    }

    /// The screen is visible (again). The first time, and after it was really left, this is
    /// where the automatic search begins; a screen that only came back from under a sheet, or
    /// was rebuilt, starts nothing.
    func screenDidAppear() {
        leaveTask?.cancel()
        leaveTask = nil
        guard !isOnScreen else { return }
        isOnScreen = true
        owesAutomaticSearch = searchesAutomatically
        searchAutomaticallyIfDue()
    }

    /// The screen went away. A run ends at once, as `leave()` ends it. The search is only given
    /// up if the screen does not come back within a moment: a view that is rebuilt disappears
    /// and appears again at once, and that must not make the list start over.
    func screenDidDisappear() {
        endRunForLeaving()
        leaveTask?.cancel()
        let grace = leaveGrace
        leaveTask = Task { [weak self] in
            guard (try? await Task.sleep(for: grace)) != nil else { return }
            self?.leave()
        }
    }

    // MARK: - The hub shown, the screen, the app

    /// The hub the app reads changed. A run that has sent no command ends (what was only
    /// scheduled is not sent for a screen that now names another hub). A command that already
    /// left this device is followed up as before: the board does not care which hub is shown.
    func targetDidChange(_ newTarget: PowerBaseHubTarget) {
        let previous = target
        target = newTarget
        guard newTarget.hubID != previous.hubID || newTarget.ineligibility != previous.ineligibility else { return }
        guard isBusy || phase == .awaitingConfirmation else { return }
        end(showing: pending == nil ? .idle : .uncertain(.answerLost))
    }

    /// The screen was left. The connection ends. A command that was only scheduled is not sent.
    /// A command that was sent is not taken back and is not shown as cancelled: the phase says
    /// that its outcome is unknown, and the operation stays to be asked about.
    func leave() {
        leaveTask?.cancel()
        leaveTask = nil
        isOnScreen = false
        owesAutomaticSearch = false
        stopScanning()
        endRunForLeaving()
    }

    private func endRunForLeaving() {
        if pending != nil {
            if case .uncertain = phase {
                end(showing: phase)
            } else {
                end(showing: .uncertain(.answerLost))
            }
        } else {
            end(showing: .idle)
        }
    }

    /// Back to the start after a result was read. Ignored while a run is under way, and while a
    /// sent command's outcome is unknown (that is only left by asking the board).
    func acknowledgeResult() {
        guard !isBusy, phase != .awaitingConfirmation, pending == nil else { return }
        phase = .idle
        boardIdentifier = nil
    }

    /// The confirmation was declined: the connection ends and nothing was sent.
    func declineConfirmation() {
        guard phase == .awaitingConfirmation else { return }
        end(showing: .idle)
    }

    private func end(showing newPhase: Phase) {
        retire()
        let open = session
        session = nil
        sessionEUI64 = nil
        phase = newPhase
        if let open {
            // Not held back by the background: ending a connection is not a new command.
            Task { await open.close() }
        }
    }

    /// The run under way, if any, is over from here on: nothing it still holds is current, its
    /// task is cancelled, and whatever of it waits for the foreground is woken to see that.
    private func retire() {
        generation += 1
        worker?.cancel()
        worker = nil
        let waiting = resumeWaiters
        resumeWaiters = []
        waiting.forEach { $0.resume() }
    }

    func sceneDidEnterBackground() {
        guard !isSuspended else { return }
        isSuspended = true
        // The automatic search rests with the app. What it found stays on the list.
        if searchesAutomatically, isScanning {
            quietScanTask?.cancel()
            quietScanTask = nil
            isScanning = false
            foundNothingSoFar = false
            provider.stopScanning()
            searchPausedForBackground = true
        }
    }

    func sceneDidBecomeActive() {
        guard isSuspended else { return }
        isSuspended = false
        let waiting = resumeWaiters
        resumeWaiters = []
        waiting.forEach { $0.resume() }
        searchAutomaticallyIfDue()
    }

    /// Waits until the app is in the foreground. `false`: run `current` ended meanwhile, so
    /// nothing more may be started for it.
    private func waitUntilActive(_ current: Int) async -> Bool {
        while isSuspended, isCurrent(current) {
            await withCheckedContinuation { resumeWaiters.append($0) }
        }
        return isCurrent(current)
    }

    private func isCurrent(_ current: Int) -> Bool { current == generation && !Task.isCancelled }

    /// What every Bluetooth opening of run `current` asks before each new command -- the connect
    /// (also after it waited for the end of an earlier connection to the same board), `proto-ver`
    /// and the two handshake messages.
    private func permit(_ current: Int) -> PowerBaseBLESendPermit {
        { [weak self] in
            guard let self, await self.waitUntilActive(current) else { throw CancellationError() }
        }
    }

    private func startWorker(_ body: @escaping @MainActor (PowerBaseLocalResetController) async -> Void) {
        unfinishedRunTasks += 1
        worker = Task { [weak self] in
            guard let self else { return }
            await body(self)
            self.unfinishedRunTasks -= 1
        }
    }

    // MARK: - Actions

    /// Connects to the board `boardID` (a scan result naming `expectedEUI64`), authenticates it
    /// with `setupCode`, and finds out what it holds. Sends no reset. When a reset command of this
    /// controller is unresolved, this is "check the result": it asks the board about that
    /// operation and nothing else.
    func verify(boardID: UUID, expectedEUI64: String, setupCode: String) {
        guard !isBusy, phase != .awaitingConfirmation else { return }
        guard availability == .poweredOn else {
            show(failure: .bluetooth(availability))
            return
        }
        guard let code = PowerBaseSetupCode.normalized(setupCode) else {
            show(failure: .invalidSetupCode)
            return
        }
        let expected = expectedEUI64.lowercased()
        guard let eui64 = PowerBaseBLEEUI64(hex: expected), boards.contains(where: { $0.id == boardID && $0.advertisedEUI64 == expected }) else {
            show(failure: .boardNotFound)
            return
        }
        stopScanning()
        retire()
        let current = generation
        boardIdentifier = nil
        phase = .connecting
        startWorker { await $0.runVerify(current, boardID: boardID, eui64: eui64, setupCode: code) }
    }

    /// The user confirmed erasing the board's registration. Only while the confirmation is shown
    /// for an authenticated board, and never while an earlier command is unresolved.
    func confirmReset() {
        guard canConfirm, let opened = session, let eui64 = sessionEUI64 else { return }
        guard let id = PowerBaseBLEOperationID.random(randomBytes) else {
            end(showing: .failed(.randomnessUnavailable))
            return
        }
        retire()
        let current = generation
        phase = .resetting
        startWorker { await $0.runReset(current, session: opened, eui64: eui64, operationID: id) }
    }

    /// A failure before anything was started. With an unresolved operation the screen keeps
    /// saying so.
    private func show(failure: Failure) {
        phase = pending == nil ? .failed(failure) : .uncertain(.checkFailed(failure))
    }

    // MARK: - The run

    private func runVerify(_ current: Int, boardID: UUID, eui64: PowerBaseBLEEUI64, setupCode: String) async {
        let opened: any PowerBaseBLEBoardSession
        do {
            opened = try await provider.openSession(boardID: boardID, eui64: eui64, setupCode: setupCode, permit: permit(current))
        } catch {
            finish(current, failure: Self.failure(forOpening: error))
            return
        }
        guard isCurrent(current) else {
            await opened.close()
            return
        }
        session = opened
        sessionEUI64 = eui64
        phase = .checking

        let state: PowerBaseBLELocalResetStatus
        do {
            // The board's own word for who it is, inside the session. A new command: it waits for
            // the foreground like the opening's messages did. (A run that ended while it waited
            // has had its session closed by whatever ended it.)
            guard await waitUntilActive(current) else { return }
            let status = try await opened.status(issueChallenge: false, requestID: nil)
            guard isCurrent(current) else { return }
            guard status.eui64 == eui64 else {
                finish(current, failure: .differentBoard)
                return
            }
            boardIdentifier = eui64.hex
            // No capability: nothing is asked and nothing else is sent in its place.
            guard await opened.capabilities().contains(.localResetV1) else {
                finish(current, failure: .boardNeedsUpdate)
                return
            }
            guard await waitUntilActive(current) else { return }
            // An unresolved operation is asked about -- on the board it was sent to.
            let asked = pending?.eui64 == eui64 ? pending?.id : nil
            state = try await opened.localResetStatus(target: eui64, operationID: asked)
        } catch {
            finish(current, failure: Self.failure(forRequest: error))
            return
        }
        guard isCurrent(current) else { return }

        if let operation = pending, operation.eui64 == eui64 {
            await resolve(current, operation: operation, state: state, session: opened)
        } else if pending != nil {
            // Another board than the one the unresolved command went to: nothing is offered here.
            finish(current, failure: .differentBoard)
        } else {
            decide(current, state: state)
        }
    }

    /// What a board that has no operation of this controller is: ready, to be confirmed, or
    /// neither.
    private func decide(_ current: Int, state: PowerBaseBLELocalResetStatus) {
        switch state.condition {
        case .notEnrolled:
            // Nothing to reset: nothing is sent, and the ordinary registration can go on.
            finish(current, .ready(.alreadyNotEnrolled))
        case .enrolled, .unreadable:
            guard state.isWindowOpen else {
                finish(current, failure: .windowNotOpen)
                return
            }
            // The session stays open; nothing has been sent. The next step is the user's.
            guard isCurrent(current) else { return }
            worker = nil
            windowSecondsLeft = state.windowSecondsLeft
            phase = .awaitingConfirmation
        case .remoteReleasePending:
            finish(current, failure: .removalInProgress)
        case .resetPending:
            finish(current, failure: .boardBusy)
        }
    }

    /// The board's answer about the unresolved operation.
    private func resolve(
        _ current: Int, operation: PendingOperation, state: PowerBaseBLELocalResetStatus, session opened: any PowerBaseBLEBoardSession
    ) async {
        switch state.operationPhase {
        case .verified? where state.condition == .notEnrolled:
            pending = nil
            finish(current, .ready(.resetVerified))
        case .verified?:
            // Verified once, and the board has been registered again since: that operation is
            // history. What the board is now is decided afresh.
            pending = nil
            decide(current, state: state)
        case .notStarted?:
            pending = nil
            finish(current, failure: .resetNotStarted)
        case .queued?, .inProgress?:
            phase = .resetting
            await follow(current, session: opened, operation: operation, first: state)
        case nil:
            // The board knows nothing of it: the command never arrived. Nothing was reset.
            pending = nil
            if state.condition == .notEnrolled {
                finish(current, .ready(.alreadyNotEnrolled))
            } else {
                finish(current, failure: .resetNotStarted)
            }
        }
    }

    private func runReset(_ current: Int, session opened: any PowerBaseBLEBoardSession, eui64: PowerBaseBLEEUI64, operationID: PowerBaseBLEOperationID) async {
        // Not in the background, and not for a run that is over: both are asked here, right
        // before each message -- this task may only run long after the tap that queued it.
        guard await waitUntilActive(current) else { return }
        let challenge: PowerBaseBLEChallenge
        do {
            let status = try await opened.status(issueChallenge: true, requestID: nil)
            guard isCurrent(current) else { return }
            guard status.eui64 == eui64, let issued = status.challenge else {
                finish(current, failure: status.eui64 == eui64 ? .boardLocked : .differentBoard)
                return
            }
            challenge = issued
        } catch {
            // Nothing was sent yet.
            finish(current, failure: Self.failure(forRequest: error))
            return
        }
        guard await waitUntilActive(current) else { return }

        // From here the command is on its way. It is not taken back when the run ends, and its
        // outcome is asked about under this id until it is known.
        let operation = PendingOperation(id: operationID, eui64: eui64)
        pending = operation
        let code: PowerBaseBLECode
        do {
            code = try await opened.localReset(
                target: eui64, operationID: operationID, challenge: challenge, confirmation: .userConfirmedErasingRegistration
            )
        } catch PowerBaseBLEClientError.invalidInput {
            // The client refused to send it (no capability): nothing left this device.
            pending = nil
            finish(current, failure: .boardNeedsUpdate)
            return
        } catch {
            // Sent or not, taken or not: this side cannot know.
            finishUncertain(current, .answerLost)
            return
        }
        guard isCurrent(current) else { return }
        switch code {
        case .accepted, .duplicate:
            // Accepted is not erased: the board is asked how far it got.
            await follow(current, session: opened, operation: operation, first: nil)
        case .notEnrolled:
            pending = nil
            finish(current, .ready(.alreadyNotEnrolled))
        case .windowClosed:
            pending = nil
            finish(current, failure: .windowNotOpen)
        case .busy:
            pending = nil
            finish(current, failure: .boardBusy)
        case .wrongTarget:
            pending = nil
            finish(current, failure: .differentBoard)
        case .closed:
            pending = nil
            finish(current, failure: .boardLocked)
        default:
            // Refused: the board changed nothing.
            pending = nil
            finish(current, failure: .other)
        }
    }

    /// Asks the board about `operation` until it says verified or not started, the connection is
    /// gone (the board restarts when it is done), or it has been asked often enough. It never
    /// sends the command.
    private func follow(
        _ current: Int, session opened: any PowerBaseBLEBoardSession, operation: PendingOperation, first: PowerBaseBLELocalResetStatus?
    ) async {
        var state = first
        var asked = 0
        while true {
            if let state {
                switch state.operationPhase {
                case .verified? where state.condition == .notEnrolled:
                    pending = nil
                    finish(current, .ready(.resetVerified))
                    return
                case .notStarted?:
                    pending = nil
                    finish(current, failure: .resetNotStarted)
                    return
                case .inProgress? where state.operationReason != 0:
                    // A step failed on the board: it restarts and carries on. Not verified.
                    finishUncertain(current, .boardStillWorking)
                    return
                case .queued?, .inProgress?:
                    break
                case .verified?, nil:
                    // Not an answer this operation can have right after it was accepted.
                    finishUncertain(current, .answerLost)
                    return
                }
                guard asked < maximumPolls else {
                    finishUncertain(current, .boardStillWorking)
                    return
                }
                guard (try? await Task.sleep(for: pollInterval)) != nil, isCurrent(current) else { return }
            }
            guard await waitUntilActive(current) else { return }
            asked += 1
            do {
                state = try await opened.localResetStatus(target: operation.eui64, operationID: operation.id)
            } catch {
                finishUncertain(current, .answerLost)
                return
            }
            guard isCurrent(current) else { return }
        }
    }

    // MARK: - Ending a run

    /// Run `current` has its result. Nothing of it goes on after this.
    private func finish(_ current: Int, _ newPhase: Phase) {
        guard isCurrent(current) else { return }
        // The run's own task is the caller: it is not cancelled, it is simply done.
        worker = nil
        retire()
        let open = session
        session = nil
        sessionEUI64 = nil
        phase = newPhase
        if let open {
            Task { await open.close() }
        }
    }

    /// A failure of run `current`. While a sent command is unresolved it is shown as that: the
    /// screen never falls back to "failed, nothing happened".
    private func finish(_ current: Int, failure: Failure) {
        finish(current, pending == nil ? .failed(failure) : .uncertain(.checkFailed(failure)))
    }

    private func finishUncertain(_ current: Int, _ uncertainty: Uncertainty) {
        finish(current, .uncertain(uncertainty))
    }

    // MARK: - Mapping

    static func failure(forOpening error: Error) -> Failure {
        switch PowerBaseEnrollmentBLEController.failure(for: error) {
        case let .bluetooth(availability): return .bluetooth(availability)
        case .boardNotFound: return .boardNotFound
        case .authenticationFailed, .boardProofMismatch: return .wrongSetupCode
        case .handshakeRefused: return .boardLocked
        case .protocolMismatch: return .boardNeedsUpdate
        default: return .boardUnreachable
        }
    }

    nonisolated static func failure(forRequest error: Error) -> Failure {
        switch error as? PowerBaseBLEClientError {
        case .refusedByBoard(.wrongTarget)?: return .differentBoard
        case .malformedResponse?, .refusedByBoard?, .invalidInput?: return .boardNeedsUpdate
        default: return .boardUnreachable
        }
    }
}
