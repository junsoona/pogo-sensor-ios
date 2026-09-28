import Foundation
import os

/// A failed read as `AppleHomeAutoReader` sees it: the error the accessory shows, plus a short
/// code for the diagnostic log ("deadline" = PogoHome's own time limit ran out first;
/// "HMErrorDomain:8" = HomeKit's own error). Never carries names or ids.
nonisolated struct AppleHomeReadFailure: Error, Hashable, Sendable {
    let error: AppleHomeProviderError
    let diagnosticCode: String
}

/// Runs the reads PogoHome starts without a tap: the first read of every accessory HomeKit lists
/// in this session, and a fresh read when one responds again after an outage.
///
/// - At most `Policy.maxConcurrentReads` accessories are read at once, in the order given to
///   `sync`. On a Mac, HomeKit sends reads to the home hub and answers concurrent ones together,
///   so one slow accessory delays everything read alongside it; a few at a time keeps a large
///   home from arriving at the hub in one batch.
/// - A transient failure (time-out, communication failure) is retried after
///   `Policy.retryDelays`, so at most `Policy.maxAttempts` times. Other failures, or the last
///   attempt's, stay as they are: the accessory keeps its `lastReadError`.
/// - Nothing here shows a value: the caller publishes only what a read actually returned.
///
/// HomeKit-free; `HomeKitAppleHomeProvider` supplies `read` and publishes `states`.
@MainActor
final class AppleHomeAutoReader {
    struct Policy: Sendable {
        var maxConcurrentReads: Int
        /// Pause before each automatic retry; one more attempt than there are delays.
        var retryDelays: [Duration]

        var maxAttempts: Int { retryDelays.count + 1 }

        static let standard = Policy(maxConcurrentReads: 4, retryDelays: [.seconds(3), .seconds(10)])
    }

    typealias Read = @MainActor (UUID) async -> AppleHomeReadFailure?
    typealias Sleep = @Sendable (Duration) async throws -> Void

    let policy: Policy
    /// Called when a state changes on its own (a read starts or ends, a retry comes due) — not
    /// for changes made inside `sync`, `markStale`, `noteRead` or `reset`, whose callers publish.
    var onChange: (@MainActor () -> Void)?

    /// Accessories with an automatic read queued, running or waiting to retry.
    private(set) var states: [UUID: AppleHomeAutoReadState] = [:]

    private let read: Read
    private let sleep: Sleep
    private var queue: [UUID] = []
    private var readable: Set<UUID> = []
    /// Read, or given up on, since it last became readable: not read again automatically.
    private var settled: Set<UUID> = []
    private var inFlight = 0
    /// The running read's token per accessory, so a read that was forgotten or superseded
    /// schedules nothing when it ends.
    private var readTokens: [UUID: Int] = [:]
    private var nextToken = 0
    private var retryTimers: [UUID: Task<Void, Never>] = [:]
    /// Bumped by `reset()`, so reads started before it change nothing afterwards.
    private var generation = 0
    private var pass: PassStats?

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.junsoona.PogoHome",
        category: "AppleHome"
    )

    init(
        policy: Policy = .standard,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        read: @escaping Read
    ) {
        precondition(policy.maxConcurrentReads > 0)
        self.policy = policy
        self.sleep = sleep
        self.read = read
    }

    // MARK: - Input

    /// Brings the reads in line with what HomeKit lists now. `readableIDs`: the accessories that
    /// respond and have something to read, in the order to read them. One that drops out is
    /// forgotten, and read again once it's back.
    func sync(readableIDs: [UUID]) {
        let current = Set(readableIDs)
        for id in readable.subtracting(current) { forget(id) }
        readable = current
        for id in readableIDs where states[id] == nil && !settled.contains(id) {
            states[id] = .waiting(nextAttempt: 1, maxAttempts: policy.maxAttempts)
            queue.append(id)
            pass = pass ?? PassStats(startedAt: .now)
            pass?.accessories += 1
        }
        pump()
    }

    /// Reads the accessory again at the next `sync` (it responds again after an outage, so values
    /// from before are old). No effect while a read of it is queued or running.
    func markStale(_ id: UUID) {
        guard states[id] == nil else { return }
        settled.remove(id)
    }

    /// Another read of the accessory (a tap, a control's read-back) finished. A success makes a
    /// queued or retrying automatic read of it unnecessary.
    func noteRead(_ id: UUID, succeeded: Bool) {
        guard succeeded, case .waiting? = states[id] else { return }
        queue.removeAll { $0 == id }
        retryTimers.removeValue(forKey: id)?.cancel()
        states[id] = nil
        settled.insert(id)
        pass?.settledByOtherRead += 1
        endPassIfIdle()
    }

    /// Stops everything (Apple Home turned off); reads still running end without effect.
    func reset() {
        generation += 1
        retryTimers.values.forEach { $0.cancel() }
        retryTimers = [:]
        queue = []
        states = [:]
        readable = []
        settled = []
        readTokens = [:]
        inFlight = 0
        pass = nil
    }

    // MARK: - Running reads

    private func forget(_ id: UUID) {
        queue.removeAll { $0 == id }
        retryTimers.removeValue(forKey: id)?.cancel()
        // A read still running ends on its own; with its token gone it schedules nothing.
        readTokens[id] = nil
        states[id] = nil
        settled.remove(id)
    }

    private func pump() {
        while inFlight < policy.maxConcurrentReads, !queue.isEmpty {
            let id = queue.removeFirst()
            guard case let .waiting(attempt, _)? = states[id] else { continue }
            start(id, attempt: attempt)
        }
    }

    private func start(_ id: UUID, attempt: Int) {
        nextToken += 1
        let token = nextToken
        let generation = self.generation
        readTokens[id] = token
        states[id] = .reading(attempt: attempt, maxAttempts: policy.maxAttempts)
        inFlight += 1
        if var stats = pass {
            stats.attempts += 1
            stats.peakInFlight = max(stats.peakInFlight, inFlight)
            pass = stats
        }
        let started = ContinuousClock.now
        Task { [weak self, read] in
            let failure = await read(id)
            let elapsed = ContinuousClock.now - started
            self?.finish(id, token: token, generation: generation, attempt: attempt, failure: failure, elapsed: elapsed)
        }
    }

    private func finish(
        _ id: UUID,
        token: Int,
        generation: Int,
        attempt: Int,
        failure: AppleHomeReadFailure?,
        elapsed: Duration
    ) {
        guard generation == self.generation else { return }
        let inFlightAtEnd = inFlight
        inFlight -= 1
        defer {
            pump()
            endPassIfIdle()
            onChange?()
        }
        if let failure { pass?.recordFailure(failure.diagnosticCode, elapsed: elapsed) }
        guard readTokens[id] == token else { return }
        readTokens[id] = nil

        if let failure, Self.isTransient(failure.error), attempt < policy.maxAttempts {
            let delay = policy.retryDelays[attempt - 1]
            states[id] = .waiting(nextAttempt: attempt + 1, maxAttempts: policy.maxAttempts)
            Self.logger.debug("""
                automatic read attempt \(attempt, privacy: .public)/\(self.policy.maxAttempts, privacy: .public) \
                failed: \(failure.diagnosticCode, privacy: .public) after \(elapsed.milliseconds, privacy: .public) ms, \
                concurrent \(inFlightAtEnd, privacy: .public); retry in \(delay.milliseconds, privacy: .public) ms
                """)
            scheduleRetry(id, after: delay)
            return
        }
        states[id] = nil
        settled.insert(id)
        if failure != nil {
            pass?.failed += 1
        } else if attempt > 1 {
            pass?.recovered += 1
        } else {
            pass?.succeededFirstTry += 1
        }
    }

    private func scheduleRetry(_ id: UUID, after delay: Duration) {
        let generation = self.generation
        retryTimers[id] = Task { [weak self, sleep] in
            do { try await sleep(delay) } catch { return }
            self?.retryDue(id, generation: generation)
        }
    }

    private func retryDue(_ id: UUID, generation: Int) {
        guard generation == self.generation, retryTimers.removeValue(forKey: id) != nil,
              case .waiting? = states[id] else { return }
        queue.append(id)
        pump()
        onChange?()
    }

    nonisolated static func isTransient(_ error: AppleHomeProviderError) -> Bool {
        switch error {
        case .timedOut, .notReachable, .accessNotReady, .underlying: return true
        case .notAuthorized, .accessoryNotFound, .characteristicNotFound, .cancelled, .setupUnavailable: return false
        }
    }

    // MARK: - Diagnostics

    /// One log line per round of automatic reads (from the first queued read until nothing is
    /// queued, running or waiting): codes, times and counts only.
    private struct PassStats {
        let startedAt: ContinuousClock.Instant
        var accessories = 0
        var attempts = 0
        var succeededFirstTry = 0
        var recovered = 0
        var failed = 0
        var settledByOtherRead = 0
        var peakInFlight = 0
        var failureCodes: [String: Int] = [:]
        var slowestFailure: Duration = .zero

        mutating func recordFailure(_ code: String, elapsed: Duration) {
            failureCodes[code, default: 0] += 1
            slowestFailure = max(slowestFailure, elapsed)
        }
    }

    private func endPassIfIdle() {
        guard let pass, inFlight == 0, queue.isEmpty, retryTimers.isEmpty else { return }
        self.pass = nil
        let codes = pass.failureCodes.isEmpty
            ? "none"
            : pass.failureCodes.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: ", ")
        let duration = ContinuousClock.now - pass.startedAt
        Self.logger.notice("""
            automatic reads: accessories \(pass.accessories, privacy: .public), \
            ok first try \(pass.succeededFirstTry, privacy: .public), \
            recovered by retry \(pass.recovered, privacy: .public), \
            failed after retries \(pass.failed, privacy: .public), \
            settled by another read \(pass.settledByOtherRead, privacy: .public); \
            attempts \(pass.attempts, privacy: .public), \
            peak concurrent \(pass.peakInFlight, privacy: .public)/\(self.policy.maxConcurrentReads, privacy: .public), \
            failed attempts [\(codes, privacy: .public)], \
            slowest failure \(pass.slowestFailure.milliseconds, privacy: .public) ms, \
            took \(duration.milliseconds, privacy: .public) ms
            """)
    }
}

private extension Duration {
    nonisolated var milliseconds: Int {
        let (seconds, attoseconds) = components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}
