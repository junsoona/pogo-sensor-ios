import Foundation
import Observation
import PowerBaseBLEKit

/// Confirms a released Power Base's removal: reads the board's release receipt over Bluetooth and
/// hands it to the hub (firmware repository, docs/power-base-management.md).
///
/// Why this exists: a board erases its stored network only after it has told the hub "released"
/// -- OpenThread refuses to erase while Thread is running -- and once that is erased it has no
/// network to report on. What says "erased, and I checked" is the receipt the board makes then and
/// keeps. It gets to the hub through an app that reads it inside an authenticated Bluetooth
/// session. Until the hub has verified it the removal is "released", not complete.
///
/// The rules:
/// - **The board is authenticated first**, with its own setup code (Security 2), and the EUI-64 it
///   reports inside the session must be the removed Base's. The advertised name only says whom to
///   try.
/// - **The app decides nothing.** It checks the receipt's shape and relays it byte for byte.
///   Whether it is genuine is the hub's judgement (its MAC needs the registration's key, which the
///   app never has). A removal is shown as complete only when the hub answered `completed`.
/// - **Reading changes nothing on the board**, so there is nothing to clean up: leaving the screen
///   just ends the connection, and trying again is always safe. A receipt that was read but could
///   not be delivered is kept (in memory only) and can be sent again without Bluetooth.
/// - **Only the paired hub picked in "Find hubs".** Anything else sends nothing.
/// - **A run that is over starts nothing.** Leaving the screen, another hub and a new run end the
///   run under way. Whether it is still the run is checked right before every new command -- each
///   Bluetooth message and the request to the hub -- not only when its answer arrives. A request
///   that already left this device is not taken back (the hub may well have handled it); its
///   answer is simply not shown.
/// - **Nothing new starts in the background**, as in the registration flow: the connection, each
///   message of the opening, the board's status, the receipt request and the request to the hub
///   (the first one and "send again") each wait for the foreground. An answer that is under way is
///   still taken. Closing a connection never waits.
@MainActor
@Observable
final class PowerBaseReleaseConfirmationController {
    nonisolated enum Phase: Equatable, Sendable {
        case idle
        /// Connecting and authenticating the board with the setup code.
        case connecting
        /// Inside the session: who the board is, then its receipt.
        case reading
        case sendingToHub
        /// The hub verified the receipt: the removal is complete.
        case confirmed(PowerBaseRemoval)
        case failed(Failure)
    }

    nonisolated enum Failure: Equatable, Sendable {
        case notEligible(PowerBaseHubIneligibility)
        case credentialUnavailable
        case invalidSetupCode
        case bluetooth(PowerBaseBLEAvailability)
        case boardNotFound
        /// The setup code (or the board it belongs to) was not accepted.
        case wrongSetupCode
        /// The board refuses enrollment sessions for this boot: power-cycle it.
        case boardLocked
        case boardUnreachable
        /// The board that authenticated is not the removed Base.
        case differentBoard
        /// The board's firmware cannot hand out a receipt.
        case boardNeedsUpdate
        /// The board has no receipt: it has not finished erasing (it tries again at every boot),
        /// or a new registration attempt has since replaced its record.
        case noReceipt
        /// The receipt was read but the hub did not take it. Unless the hub rejected it, it is kept
        /// and `sendAgain()` delivers it without Bluetooth.
        case hub(PowerBaseRemovalError)
    }

    /// The removed Base's EUI-64, 16 lower-case hex digits.
    let powerBaseIdentifier: String

    private(set) var phase: Phase = .idle
    private(set) var availability: PowerBaseBLEAvailability = .unknown
    /// Advertisers that name the removed Base (nothing else is offered).
    private(set) var boards: [PowerBaseBLEDiscoveredBoard] = []
    private(set) var isScanning = false
    /// Scanning for a while without finding the board.
    private(set) var foundNothingSoFar = false
    private(set) var target: PowerBaseHubTarget = .none
    /// The app is in the background: no Bluetooth command and no request to the hub is started
    /// until it is active again.
    private(set) var isSuspended = false
    /// How many steps of a run wait for the foreground right now. For tests: none may be left when
    /// no run is under way.
    var foregroundWaiters: Int { resumeWaiters.count }
    /// Tasks started for a run that have not come to their end. For tests: a run that ended leaves
    /// none behind once the request it had already sent, if any, was answered.
    @ObservationIgnored private(set) var unfinishedRunTasks = 0

    private let provider: PowerBaseBLEBoardProviding
    private let transport: PowerBaseRemovalTransport
    private let credentials: HubCredentialStoring
    private let quietScanPeriod: Duration
    private var generation = 0
    private var quietScanTask: Task<Void, Never>?
    /// The task of the run under way. Cancelled when the run ends, so an opening that waits (for
    /// the end of an earlier connection, or for the foreground) ends with it.
    private var worker: Task<Void, Never>?
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []
    private var session: (any PowerBaseBLEBoardSession)?
    /// A receipt that was read and not yet taken by the hub. Not a secret; never stored.
    private var undelivered: PowerBaseBLEReleaseReceipt?

    init(
        powerBaseIdentifier: String,
        provider: PowerBaseBLEBoardProviding,
        transport: PowerBaseRemovalTransport = URLSessionPowerBaseRemovalTransport(),
        credentials: HubCredentialStoring = KeychainHubCredentialStore(),
        quietScanPeriod: Duration = .seconds(8)
    ) {
        self.powerBaseIdentifier = powerBaseIdentifier.lowercased()
        self.provider = provider
        self.transport = transport
        self.credentials = credentials
        self.quietScanPeriod = quietScanPeriod
    }

    var ineligibility: PowerBaseHubIneligibility? { target.ineligibility }

    var isBusy: Bool {
        switch phase {
        case .connecting, .reading, .sendingToHub: return true
        case .idle, .confirmed, .failed: return false
        }
    }

    var canStart: Bool { ineligibility == nil && !isBusy && availability == .poweredOn }

    /// A receipt is in hand and only the hub is missing.
    var canSendAgain: Bool { !isBusy && undelivered != nil && ineligibility == nil }

    // MARK: - Bluetooth and scanning

    /// Starts using Bluetooth (the system asks for permission the first time). Does not scan.
    func activate() {
        provider.onChange = { [weak self] in self?.providerDidChange() }
        provider.activate()
        providerDidChange()
    }

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
        boards = Self.matching(provider.boards, powerBaseIdentifier)
        if !boards.isEmpty { foundNothingSoFar = false }
    }

    /// The advertisers that name `identifier`, strongest signal first. A name is only a hint: the
    /// board is believed after it authenticated and reported the same EUI-64 itself.
    nonisolated static func matching(_ boards: [PowerBaseBLEDiscoveredBoard], _ identifier: String) -> [PowerBaseBLEDiscoveredBoard] {
        boards.filter { $0.advertisedEUI64 == identifier }.sorted { $0.rssi > $1.rssi }
    }

    // MARK: - Source and leaving

    func targetDidChange(_ newTarget: PowerBaseHubTarget) {
        let previous = target
        target = newTarget
        guard newTarget.hubID != previous.hubID || newTarget.ineligibility != previous.ineligibility else { return }
        // A receipt belongs to the hub it was read for; a run under way is not this hub's.
        end(showing: .idle)
        undelivered = nil
    }

    /// The screen was left: the connection ends. Nothing on the board or the hub needs undoing.
    func leave() {
        stopScanning()
        end(showing: .idle)
    }

    /// Back to the start after a result was read. Ignored while a run is under way.
    func acknowledgeResult() {
        guard !isBusy else { return }
        phase = .idle
    }

    private func end(showing newPhase: Phase) {
        retire()
        let open = session
        session = nil
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

    // MARK: - The app in the background

    /// The app went to the background. Nothing is cancelled and nothing new is started: no
    /// Bluetooth command and no request to the hub until `sceneDidBecomeActive()`. A request that
    /// already left this device is still waited for.
    func sceneDidEnterBackground() {
        isSuspended = true
    }

    /// Back in the foreground: a run that waited carries on where it stopped.
    func sceneDidBecomeActive() {
        guard isSuspended else { return }
        isSuspended = false
        let waiting = resumeWaiters
        resumeWaiters = []
        waiting.forEach { $0.resume() }
    }

    /// Waits until the app is in the foreground. `false`: run `current` ended meanwhile (ending a
    /// run wakes everything that waits here), so nothing more may be started for it.
    private func waitUntilActive(_ current: Int) async -> Bool {
        while isSuspended, isCurrent(current) {
            await withCheckedContinuation { resumeWaiters.append($0) }
        }
        return isCurrent(current)
    }

    // MARK: - Actions

    /// Reads the receipt of the board `boardID` (a scan result naming the removed Base), which the
    /// user holds the setup code of, and hands it to the hub.
    func confirm(boardID: UUID, setupCode: String) {
        guard !isBusy else { return }
        if let reason = target.ineligibility {
            phase = .failed(.notEligible(reason))
            return
        }
        guard let context = hubContext() else { return }
        guard availability == .poweredOn else {
            phase = .failed(.bluetooth(availability))
            return
        }
        guard let code = PowerBaseSetupCode.normalized(setupCode) else {
            phase = .failed(.invalidSetupCode)
            return
        }
        guard let eui64 = PowerBaseBLEEUI64(hex: powerBaseIdentifier),
              boards.contains(where: { $0.id == boardID && $0.advertisedEUI64 == powerBaseIdentifier }) else {
            phase = .failed(.boardNotFound)
            return
        }
        stopScanning()
        retire()
        let current = generation
        undelivered = nil
        phase = .connecting
        startWorker { await $0.run(current, boardID: boardID, eui64: eui64, setupCode: code, context: context) }
    }

    /// Hands a receipt that was already read to the hub again. No Bluetooth.
    func sendAgain() {
        guard canSendAgain, let receipt = undelivered, let context = hubContext() else { return }
        retire()
        let current = generation
        phase = .sendingToHub
        startWorker { await $0.deliver(current, receipt: receipt, context: context) }
    }

    /// Queues the task of the run that was just made current. It may run much later than the tap
    /// that asked for it; what it does first is to ask whether its run still is the run.
    private func startWorker(_ body: @escaping @MainActor (PowerBaseReleaseConfirmationController) async -> Void) {
        unfinishedRunTasks += 1
        worker = Task { [weak self] in
            guard let self else { return }
            await body(self)
            self.unfinishedRunTasks -= 1
        }
    }

    // MARK: - The run

    /// The hub a run was started for. The address is not kept: it is the target's at the moment
    /// a request is made (the same hub may have moved to another address meanwhile).
    private struct HubContext {
        let hubID: String
        let credential: HubCredential
    }

    private func hubContext() -> HubContext? {
        guard let hubID = target.hubID, target.baseURL != nil else { return nil }
        guard let stored = try? credentials.credential(forHubID: hubID), stored.hubID.lowercased() == hubID.lowercased() else {
            phase = .failed(.credentialUnavailable)
            return nil
        }
        return HubContext(hubID: hubID, credential: stored)
    }

    private func isCurrent(_ current: Int) -> Bool { current == generation && !Task.isCancelled }

    /// Where a request of run `current` goes, asked right before it is made: `nil` when the run is
    /// over, or the app no longer reads the eligible hub the run was started for.
    private func address(_ current: Int, _ context: HubContext) -> URL? {
        guard isCurrent(current), target.ineligibility == nil, target.hubID == context.hubID else { return nil }
        return target.baseURL
    }

    /// What every Bluetooth opening of run `current` asks before each new command -- the connect
    /// (also after it waited for the end of an earlier connection), `proto-ver` and the two
    /// handshake messages. Waits for the foreground; throws once the run is over.
    private func permit(_ current: Int) -> PowerBaseBLESendPermit {
        { [weak self] in
            guard let self, await self.waitUntilActive(current) else { throw CancellationError() }
        }
    }

    private func run(_ current: Int, boardID: UUID, eui64: PowerBaseBLEEUI64, setupCode: String, context: HubContext) async {
        let opened: any PowerBaseBLEBoardSession
        do {
            opened = try await provider.openSession(boardID: boardID, eui64: eui64, setupCode: setupCode, permit: permit(current))
        } catch {
            finish(current, .failed(Self.failure(forOpening: error)))
            return
        }
        guard isCurrent(current) else {
            await opened.close()
            return
        }
        session = opened
        phase = .reading

        let receipt: PowerBaseBLEReleaseReceipt?
        do {
            // The board's own word for who it is, inside the session. A new command: it waits for
            // the foreground like the opening's messages did. (A run that ended while it waited
            // has had its session closed by whatever ended it.)
            guard await waitUntilActive(current) else { return }
            let status = try await opened.status(issueChallenge: false, requestID: nil)
            guard isCurrent(current) else { return }
            guard status.eui64 == eui64 else {
                finish(current, .failed(.differentBoard))
                return
            }
            guard await opened.capabilities().contains(.releaseReceiptV1) else {
                finish(current, .failed(.boardNeedsUpdate))
                return
            }
            guard await waitUntilActive(current) else { return }
            receipt = try await opened.releaseReceipt(target: eui64)
        } catch {
            finish(current, .failed(Self.failure(forRequest: error)))
            return
        }
        guard isCurrent(current) else { return }
        // Read, or known to be absent: the board is not needed any more. Closing is not a new
        // command and does not wait for the foreground.
        session = nil
        await opened.close()
        guard isCurrent(current) else { return }
        guard let receipt, receipt.eui64Hex == powerBaseIdentifier else {
            finish(current, .failed(.noReceipt))
            return
        }
        undelivered = receipt
        phase = .sendingToHub
        await deliver(current, receipt: receipt, context: context)
    }

    private func deliver(_ current: Int, receipt: PowerBaseBLEReleaseReceipt, context: HubContext) async {
        // Not in the background, and not for a run that is over: both are asked here, right before
        // the request is made -- this may be a task that was queued by a tap and only runs now, or
        // one that has waited for the foreground for a long time.
        guard await waitUntilActive(current), let baseURL = address(current, context) else { return }
        // From here the request is on its way. It is not taken back when the run ends: the hub may
        // have handled it, and nothing is claimed about that. Its answer is shown only to the run
        // that made it.
        let transport = transport
        let credential = context.credential
        let hex = receipt.hex
        let result = await Task {
            try await transport.submitReceipt(baseURL: baseURL, credential: credential, receiptHex: hex)
        }.result
        guard isCurrent(current) else { return }
        switch result {
        case let .success(removal):
            // The hub's word, for this Base: nothing else is shown as complete.
            guard removal.state == .completed, removal.powerBaseIdentifier == powerBaseIdentifier else {
                finish(current, .failed(.hub(.badResponse("receipt reply"))))
                return
            }
            undelivered = nil
            finish(current, .confirmed(removal))
        case let .failure(error):
            let error = error as? PowerBaseRemovalError ?? .unreachable("HTTP")
            // A receipt the hub rejected will not fare better a second time.
            if !error.isTransient { undelivered = nil }
            finish(current, .failed(.hub(error)))
        }
    }

    /// Run `current` has its result. Nothing of it goes on after this, and nothing of it is left
    /// waiting for the foreground.
    private func finish(_ current: Int, _ newPhase: Phase) {
        guard isCurrent(current) else { return }
        // The run's own task is the caller: it is not cancelled, it is simply done.
        worker = nil
        retire()
        let open = session
        session = nil
        phase = newPhase
        if let open {
            Task { await open.close() }
        }
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
