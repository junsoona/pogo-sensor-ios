import Foundation

/// Guards a raw SSE line stream against silently hanging. A Linux service killed without
/// sending a TCP FIN (e.g. `systemctl restart` under some process managers) can leave a
/// `URLSession` task suspended forever waiting on bytes that will never arrive — no error,
/// no `CancellationError`, just an idle socket. This watches the *idle time since the last
/// line* (heartbeat or `snapshot` event, both count) and, if it exceeds `idleTimeout`, tears
/// the connection down itself and throws, so the caller's normal reconnect-with-backoff path
/// takes over.
///
/// Implementation runs two structured child tasks for the connection's whole lifetime — one
/// forwards `upstream` (and is the sole reader of it, so there's never a shared, concurrently
/// touched iterator), the other sleeps until the exact moment the idle deadline would be
/// reached and re-checks (never a fixed-interval busy poll). Whichever finishes first wins;
/// `withThrowingTaskGroup` cancels the loser. `AsyncThrowingStream` terminates its underlying
/// continuation — and for `URLSessionSensorAPITransport`, the real `URLSessionDataTask` — as
/// soon as the task iterating it is cancelled, so cancelling the forwarding child tears down
/// the real socket too. Cancelling the *returned* stream cancels both children the same way.
nonisolated struct SSELivenessWatchdog: Sendable {
    nonisolated enum LivenessError: Error, Equatable, Sendable {
        /// No line (heartbeat or event) arrived within `idleTimeout` seconds.
        case idleTimeout
    }

    let idleTimeout: Double
    let sleeper: AsyncSleeping

    init(idleTimeout: Double, sleeper: AsyncSleeping) {
        self.idleTimeout = idleTimeout
        self.sleeper = sleeper
    }

    /// Wraps `upstream`: every line it yields resets the idle deadline and is forwarded
    /// unchanged; if `idleTimeout` elapses with no line, the returned stream throws
    /// `LivenessError.idleTimeout` and `upstream` is cancelled.
    func watch(_ upstream: AsyncThrowingStream<String, Error>) -> AsyncThrowingStream<String, Error> {
        let idleTimeout = idleTimeout
        let sleeper = sleeper
        return AsyncThrowingStream { continuation in
            let task = Task {
                let activity = LastActivityTracker()
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for try await line in upstream {
                                await activity.touch()
                                continuation.yield(line)
                            }
                            // Reaching here also happens when the *other* child (the idle
                            // timer) wins the race: `withThrowingTaskGroup` cancels this one
                            // in response, and a cancelled `AsyncThrowingStream` iteration
                            // ends its `for await` normally (not by throwing) — so without
                            // this check, this task would call `continuation.finish()` with
                            // no error immediately after the idle-timer child already threw,
                            // silently winning the race and swallowing the timeout. Only a
                            // genuine, uncancelled end of `upstream` may finish this way.
                            if !Task.isCancelled {
                                continuation.finish()
                            }
                        }
                        group.addTask {
                            try await Self.watchForIdleTimeout(activity, idleTimeout: idleTimeout, sleeper: sleeper)
                        }
                        // Whichever child finishes first (upstream ending, or the watchdog
                        // detecting a timeout) decides the outcome; the other is torn down.
                        try await group.next()
                        group.cancelAll()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Never a busy loop: sleeps exactly until the current idle deadline, then re-checks —
    /// if `activity` was touched in the meantime the deadline moved out, so it computes the
    /// new remaining time and sleeps again, rather than polling at a fixed cadence.
    private static func watchForIdleTimeout(
        _ activity: LastActivityTracker,
        idleTimeout: Double,
        sleeper: AsyncSleeping
    ) async throws {
        while true {
            let remaining = idleTimeout - (await activity.idleDuration())
            guard remaining > 0 else { throw LivenessError.idleTimeout }
            try await sleeper.sleep(seconds: remaining)
        }
    }
}

extension SSELivenessWatchdog.LivenessError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .idleTimeout:
            return "센서 허브와의 연결이 응답하지 않습니다 (연결 상태 확인 시간 초과)"
        }
    }
}

/// Tracks only a timestamp — never touches the SSE iterator itself, so there is no shared
/// mutable state for the two racing tasks in `watch(_:)` to contend over beyond this.
private actor LastActivityTracker {
    private var lastActivityAt = Date()

    func touch() {
        lastActivityAt = Date()
    }

    func idleDuration() -> Double {
        Date().timeIntervalSince(lastActivityAt)
    }
}
