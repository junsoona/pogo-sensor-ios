#if DEBUG
import Foundation
import Observation

/// Where the PSKd can be copied to, so the tester can type it into the spare board's serial
/// console. Separate so tests can check that the app clears what it copied.
@MainActor
protocol PowerBaseEnrollmentClipboard: AnyObject {
    func copySecret(_ value: String, expiresAt: Date?)
    /// Removes the copied value, unless something else was copied since.
    func clearSecretIfUnchanged()
}

/// The DEBUG-only Power Base enrollment test: asks the hub the app follows to let one spare board
/// (a Joiner probe), named by its EUI-64, join Thread with a fresh PSKd, and shows what the hub
/// reports until the session ends. Not a registration feature.
///
/// Rules this type enforces:
/// - **Only the paired hub picked in "Find hubs".** Simulated data, a typed address, a hub without
///   an address or one this device isn't paired with send nothing. Requests use this device's own
///   credential for that hub and its pinned certificate.
/// - **A new PSKd per start**, from the system's secure random generator, shown only after the hub
///   accepted the session (`202`). It is kept only in memory, only while the session runs, and is
///   never stored, logged or put into an error; it is dropped when the session ends or is left.
/// - **The hub decides.** Success is shown only when the hub answers `heartbeat_received`;
///   `expires_in_ms` is shown as guidance, and the session ends only on the hub's answer.
/// - **Nothing late applies.** Every request belongs to a generation; leaving the screen or a
///   change of hub starts a new one, so an answer that arrives afterwards changes nothing. The
///   same hub at a new address carries on there, with the same pin.
/// - **Leaving cancels, the background doesn't.** Leaving the screen or switching the source
///   stops polling at once and asks the original hub (original address and credential) to cancel,
///   best effort; otherwise the hub's own window ends it. The app going to the background changes
///   nothing — the tester is working on the board's console meanwhile.
@MainActor
@Observable
final class PowerBaseEnrollmentController {
    /// The source the app reads, as far as enrollment cares (`PowerBaseHubTarget`, shared with the
    /// product screens).
    typealias Target = PowerBaseHubTarget
    /// Why a test can't start with the current source.
    typealias Ineligibility = PowerBaseHubIneligibility

    nonisolated enum Phase: Equatable, Sendable {
        case idle
        /// The `POST` is under way.
        case starting
        /// Accepted and not final yet; polled about once a second. The PSKd is shown.
        case running(PowerBaseEnrollmentSession)
        /// A session this device started earlier (the hub answered `409` with it). Its PSKd is gone
        /// and is never shown again; it can be followed and cancelled.
        case earlierSessionRunning(PowerBaseEnrollmentSession)
        /// The `DELETE` is under way.
        case cancelling(PowerBaseEnrollmentSession)
        /// The hub reported a final state.
        case finished(PowerBaseEnrollmentSession)
        case failed(Failure)
    }

    nonisolated enum Failure: Equatable, Sendable {
        case invalidEUI64
        /// No secure randomness for a PSKd; nothing was sent.
        case randomnessUnavailable
        /// This device's credential for the hub couldn't be read; nothing was sent.
        case credentialUnavailable
        /// The hub refused, or the session could no longer be followed.
        case request(PowerBaseEnrollmentError)
        /// The app switched to another source while a session ran; it was cancelled on the original
        /// hub as far as possible.
        case sourceChanged
    }

    private(set) var phase: Phase = .idle
    /// The PSKd of the running session — only between the hub's `202` and the session's end.
    private(set) var pskd: String?
    /// When the hub's window ends, from its last `expires_in_ms` (guidance only).
    private(set) var expiresAround: Date?
    /// A problem while following a running session that may clear up (the hub unreachable for a
    /// moment, or a cancel that didn't get through).
    private(set) var pollProblem: PowerBaseEnrollmentError?
    private(set) var target: Target = .none

    /// The rule itself is `PowerBaseHubTarget.ineligibility`, shared with every other screen.
    var ineligibility: Ineligibility? { target.ineligibility }

    /// A session is under way (starting, running, or being cancelled).
    var isBusy: Bool {
        switch phase {
        case .starting, .running, .earlierSessionRunning, .cancelling: return true
        case .idle, .finished, .failed: return false
        }
    }

    var canStart: Bool { ineligibility == nil && !isBusy }

    var canCancel: Bool { liveSession != nil }

    /// The hub, address and credential of the session under way. The credential stays here, out of
    /// every view; only the transport puts its token into a request.
    private struct SessionContext {
        let generation: Int
        let hubID: String
        var baseURL: URL
        let credential: HubCredential
        var sessionID: String?
    }

    private let transport: PowerBaseEnrollmentTransport
    private let credentials: HubCredentialStoring
    private let clipboard: PowerBaseEnrollmentClipboard?
    private let pollInterval: Duration
    private let randomBytes: (Int) -> [UInt8]?
    private let now: () -> Date

    private var context: SessionContext?
    private var generation = 0
    private var pollTask: Task<Void, Never>?

    init(
        transport: PowerBaseEnrollmentTransport = URLSessionPowerBaseEnrollmentTransport(),
        credentials: HubCredentialStoring = KeychainHubCredentialStore(),
        clipboard: PowerBaseEnrollmentClipboard? = nil,
        pollInterval: Duration = .seconds(1),
        randomBytes: @escaping (Int) -> [UInt8]? = SecureRandomBytes.system,
        now: @escaping () -> Date = Date.init
    ) {
        self.transport = transport
        self.credentials = credentials
        self.clipboard = clipboard
        self.pollInterval = pollInterval
        self.randomBytes = randomBytes
        self.now = now
    }

    private var liveSession: PowerBaseEnrollmentSession? {
        switch phase {
        case let .running(session), let .earlierSessionRunning(session): return session
        default: return nil
        }
    }

    // MARK: - Source

    /// The app now reads `newTarget`. The same hub at another address keeps its session there;
    /// anything else ends it (cancelled on the original hub as far as possible) and drops every
    /// result that belonged to the previous hub.
    func targetDidChange(_ newTarget: Target) {
        let previous = target
        target = newTarget
        if let context, ineligibility == nil, newTarget.hubID == context.hubID, let address = newTarget.baseURL {
            self.context?.baseURL = address
            return
        }
        guard newTarget.hubID != previous.hubID || ineligibility != nil else { return }
        if isBusy {
            abandon(showing: .failed(.sourceChanged))
        } else if phase != .idle {
            // A finished or failed test of the previous hub isn't this hub's.
            abandon(showing: .idle)
        }
    }

    // MARK: - Actions

    /// Starts a session for the board with EUI-64 `input` with a new PSKd. Ignored while one is
    /// under way or while the source isn't eligible.
    func start(eui64 input: String) {
        guard canStart, let hubID = target.hubID, let baseURL = target.baseURL else { return }
        guard let eui64 = PowerBaseEUI64.normalized(input) else {
            phase = .failed(.invalidEUI64)
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
        guard let code = ThreadPSKd.generate(randomBytes: randomBytes) else {
            phase = .failed(.randomnessUnavailable)
            return
        }

        resetSessionState()
        generation += 1
        let session = generation
        context = SessionContext(generation: session, hubID: hubID, baseURL: baseURL, credential: credential, sessionID: nil)
        phase = .starting
        let transport = transport
        Task { [weak self] in
            let result: Result<PowerBaseEnrollmentSession, Error>
            do {
                result = .success(try await transport.start(baseURL: baseURL, credential: credential, eui64: eui64, pskd: code))
            } catch {
                result = .failure(error)
            }
            guard let self else {
                if case let .success(accepted) = result {
                    Self.cancelInBackground(accepted.sessionID, baseURL: baseURL, credential: credential, transport: transport)
                }
                return
            }
            self.startDidFinish(result, pskd: code, generation: session, baseURL: baseURL, credential: credential)
        }
    }

    /// Asks the hub to cancel the running session. A second tap while the `DELETE` is under way
    /// does nothing.
    func cancel() {
        guard let session = liveSession, let context, let sessionID = context.sessionID else { return }
        let earlier = if case .earlierSessionRunning = phase { true } else { false }
        stopPolling()
        phase = .cancelling(session)
        let current = generation
        let transport = transport
        Task { [weak self] in
            let result: Result<PowerBaseEnrollmentSession, Error>
            do {
                result = .success(try await transport.cancel(baseURL: context.baseURL, credential: context.credential, sessionID: sessionID))
            } catch {
                result = .failure(error)
            }
            self?.cancelDidFinish(result, generation: current, resumeAsEarlier: earlier)
        }
    }

    /// The screen went away: stop at once and cancel what runs, best effort.
    func leave() {
        abandon(showing: .idle)
    }

    func copyCode() {
        guard let pskd else { return }
        clipboard?.copySecret(pskd, expiresAt: expiresAround)
    }

    // MARK: - Answers

    private func startDidFinish(
        _ result: Result<PowerBaseEnrollmentSession, Error>, pskd code: String, generation session: Int,
        baseURL: URL, credential: HubCredential
    ) {
        guard session == generation, context?.generation == session else {
            // Left, or the source changed, while the POST was under way: nobody follows this
            // session, so it is cancelled right away on the hub that accepted it.
            if case let .success(accepted) = result, !accepted.state.isFinal {
                Self.cancelInBackground(accepted.sessionID, baseURL: baseURL, credential: credential, transport: transport)
            }
            return
        }
        switch result {
        case let .success(accepted):
            context?.sessionID = accepted.sessionID
            if !accepted.state.isFinal { pskd = code }
            apply(accepted, earlier: false)
        case let .failure(PowerBaseEnrollmentError.enrollmentInProgress(own?)):
            // This device's earlier session (its PSKd is gone): followed, and can be cancelled.
            context?.sessionID = own.sessionID
            apply(own, earlier: true)
        case let .failure(error):
            context = nil
            phase = .failed(.request(error as? PowerBaseEnrollmentError ?? .unreachable("HTTP")))
        }
    }

    private func cancelDidFinish(_ result: Result<PowerBaseEnrollmentSession, Error>, generation current: Int, resumeAsEarlier: Bool) {
        guard current == generation, case let .cancelling(session) = phase else { return }
        switch result {
        case let .success(cancelled):
            finish(cancelled)
        case let .failure(PowerBaseEnrollmentError.sessionAlreadyFinal(final)) where final.sessionID == session.sessionID:
            // The session ended first (a heartbeat or the deadline won the race): the hub's answer.
            finish(final)
        case let .failure(error):
            let error = error as? PowerBaseEnrollmentError ?? .unreachable("HTTP")
            if error.isTransient {
                // The cancel didn't get through; the session runs on and can be cancelled again.
                phase = resumeAsEarlier ? .earlierSessionRunning(session) : .running(session)
                pollProblem = error
                schedulePolling()
            } else {
                end(with: .request(error))
            }
        }
    }

    /// A session from the hub for the context's session id.
    private func apply(_ session: PowerBaseEnrollmentSession, earlier: Bool) {
        guard session.sessionID == context?.sessionID else { return }
        if session.state.isFinal {
            finish(session)
            return
        }
        phase = earlier ? .earlierSessionRunning(session) : .running(session)
        expiresAround = now().addingTimeInterval(TimeInterval(session.expiresInMs) / 1000)
        schedulePolling()
    }

    private func finish(_ session: PowerBaseEnrollmentSession) {
        stopPolling()
        context = nil
        clearSecret()
        expiresAround = nil
        pollProblem = nil
        phase = .finished(session)
    }

    private func end(with failure: Failure) {
        stopPolling()
        context = nil
        clearSecret()
        expiresAround = nil
        pollProblem = nil
        phase = .failed(failure)
    }

    // MARK: - Polling

    private func schedulePolling() {
        guard pollTask == nil else { return }
        let current = generation
        let interval = pollInterval
        let transport = transport
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, current == self.generation, let context = self.context, let sessionID = context.sessionID,
                      self.liveSession != nil else { return }
                let result: Result<PowerBaseEnrollmentSession, Error>
                do {
                    result = .success(try await transport.status(baseURL: context.baseURL, credential: context.credential, sessionID: sessionID))
                } catch {
                    result = .failure(error)
                }
                // Left, switched, cancelling or ended meanwhile: this answer is stale.
                guard !Task.isCancelled, current == self.generation, self.context?.sessionID == sessionID,
                      self.liveSession != nil else { return }
                switch result {
                case let .success(session):
                    self.pollProblem = nil
                    let earlier = if case .earlierSessionRunning = self.phase { true } else { false }
                    self.applyPolled(session, earlier: earlier)
                    if session.state.isFinal { return }
                case let .failure(error):
                    let error = error as? PowerBaseEnrollmentError ?? .unreachable("HTTP")
                    if error.isTransient {
                        self.pollProblem = error
                    } else {
                        // 401, 404, a changed certificate…: nothing more is sent.
                        self.pollTask = nil
                        self.end(with: .request(error))
                        return
                    }
                }
            }
        }
    }

    private func applyPolled(_ session: PowerBaseEnrollmentSession, earlier: Bool) {
        if session.state.isFinal {
            pollTask = nil
            finish(session)
        } else {
            phase = earlier ? .earlierSessionRunning(session) : .running(session)
            expiresAround = now().addingTimeInterval(TimeInterval(session.expiresInMs) / 1000)
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Ending

    /// Stops following the current session: polling ends now, a running session is cancelled on
    /// the hub it belongs to (its last known address, this device's credential for it — the pin
    /// keeps the request from reaching any other hub), and every answer still on its way is
    /// ignored.
    private func abandon(showing newPhase: Phase) {
        if let context, let sessionID = context.sessionID, liveSession != nil {
            Self.cancelInBackground(sessionID, baseURL: context.baseURL, credential: context.credential, transport: transport)
        }
        // A POST still under way cancels its own session when it returns (`startDidFinish`); a
        // DELETE under way finishes on its own.
        generation += 1
        stopPolling()
        context = nil
        clearSecret()
        expiresAround = nil
        pollProblem = nil
        phase = newPhase
    }

    private func resetSessionState() {
        clearSecret()
        expiresAround = nil
        pollProblem = nil
    }

    private func clearSecret() {
        guard pskd != nil else { return }
        pskd = nil
        clipboard?.clearSecretIfUnchanged()
    }

    /// Fire and forget: if it fails, the hub's window ends the session.
    private nonisolated static func cancelInBackground(_ sessionID: String, baseURL: URL, credential: HubCredential, transport: PowerBaseEnrollmentTransport) {
        Task.detached {
            _ = try? await transport.cancel(baseURL: baseURL, credential: credential, sessionID: sessionID)
        }
    }
}
#endif
