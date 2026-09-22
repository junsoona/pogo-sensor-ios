import Foundation

/// A `SensorDataSource` backed by the real Linux PogoHome API: an initial `GET
/// /api/v1/snapshot`, followed by a persistent `GET /api/v1/events` SSE connection that
/// atomically replaces app state on every `snapshot` event. Reconnects with bounded
/// exponential backoff whenever the SSE connection drops, and re-fetches a fresh snapshot
/// on every (re)connect attempt so a restarted Linux registry (which repopulates only
/// after its own periodic re-sync) is reflected as soon as possible.
///
/// `connectionStatusUpdates()` only reports `.connected` once the SSE connection has both
/// actually opened *and* delivered at least one line (a heartbeat or a `snapshot` event) —
/// never merely because the snapshot GET succeeded. `SSELivenessWatchdog` then guards that
/// open connection: if a restarted Linux service leaves the socket open but silent (no FIN,
/// so `URLSession` itself never errors), the watchdog tears it down after
/// `livenessIdleTimeout` seconds of no lines and this loop reconnects.
///
/// A heartbeat only resets the liveness watchdog and (re)confirms `.connected` — it
/// deliberately does *not* trigger an extra `GET /snapshot` here. An earlier version of this
/// type did that, on the theory that the server's own heartbeat cadence could double as a
/// registry-recovery signal. On real hardware that never fired reliably (heartbeat comments
/// can sit buffered on the wire far longer than the server's nominal cadence suggests), so
/// recovery now goes through `AppModel`'s independent `periodicRefreshInterval`-driven
/// polling instead — see `periodicRefreshInterval` below — which needs no cooperation from
/// SSE activity at all.
///
/// `@MainActor`, matching `MockSensorDataSource` and this project's default actor
/// isolation — the actual network I/O (`SensorAPITransport`) runs off the main actor, so
/// this type only ever does cheap orchestration (state transitions, publishing to the
/// two `AsyncStream`s) on it. Being single-actor keeps the reconnect bookkeeping
/// (generation counter, status subscriber) simple and race-free without needing a
/// separate actor domain.
@MainActor
final class LiveSensorDataSource: SensorDataSource {
    /// The server's heartbeat cadence is ~15s; this tolerates at least two missed
    /// heartbeats before treating the connection as dead. Overridable so tests never have
    /// to wait 40 real seconds.
    static let defaultLivenessIdleTimeout: Double = 40
    /// Default `periodicRefreshInterval`: independent of SSE/heartbeat activity entirely, so
    /// a registry recovering after a Linux service restart converges within roughly this
    /// long even if the SSE connection never delivers another usable signal. Overridable so
    /// tests never have to wait multiple real seconds per tick.
    static let defaultPeriodicRefreshInterval: Double = 5

    private let endpoint: PogoAPIEndpoint
    private let transport: SensorAPITransport
    /// Paces reconnect backoff only. Deliberately a *separate* clock from
    /// `watchdogSleeper`: a test that caps reconnect attempts via a `RecordingSleeper`'s
    /// `maxSleeps` must never have that budget silently drained by unrelated watchdog waits
    /// (or vice versa) just because they happened to share one `AsyncSleeping` instance.
    private let sleeper: AsyncSleeping
    private let livenessIdleTimeout: Double
    private let watchdogSleeper: AsyncSleeping
    let periodicRefreshInterval: Double?

    private var updatesGeneration = 0
    private var statusContinuation: AsyncStream<DataSourceConnectionStatus>.Continuation?

    init(
        endpoint: PogoAPIEndpoint,
        transport: SensorAPITransport = URLSessionSensorAPITransport(),
        sleeper: AsyncSleeping = RealAsyncSleeper(),
        livenessIdleTimeout: Double = defaultLivenessIdleTimeout,
        watchdogSleeper: AsyncSleeping = RealAsyncSleeper(),
        periodicRefreshInterval: Double? = defaultPeriodicRefreshInterval
    ) {
        self.endpoint = endpoint
        self.transport = transport
        self.sleeper = sleeper
        self.livenessIdleTimeout = livenessIdleTimeout
        self.watchdogSleeper = watchdogSleeper
        self.periodicRefreshInterval = periodicRefreshInterval
    }

    func currentSnapshot() async throws -> HomeSnapshot {
        let data = try await transport.fetchSnapshotData(from: endpoint.snapshotURL)
        return try PogoSnapshotMapper.decodeSnapshot(from: data)
    }

    func updates() -> AsyncStream<HomeSnapshot> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                await self.runUpdatesLoop(continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func connectionStatusUpdates() -> AsyncStream<DataSourceConnectionStatus> {
        AsyncStream { continuation in
            statusContinuation = continuation
            continuation.yield(.idle)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.statusContinuation != nil else { return }
                    self.statusContinuation = nil
                }
            }
        }
    }

    private func publishStatus(_ status: DataSourceConnectionStatus) {
        statusContinuation?.yield(status)
    }

    /// The reconnect loop. Runs until its `Task` is cancelled (app backgrounded, data
    /// source replaced) or a newer call to `updates()` supersedes it (`generation` check),
    /// never creating more than one live SSE connection at a time and never busy-looping —
    /// every retry passes through `ReconnectBackoff` before trying again.
    private func runUpdatesLoop(continuation: AsyncStream<HomeSnapshot>.Continuation) async {
        updatesGeneration += 1
        let generation = updatesGeneration
        defer { continuation.finish() }

        var attempt = 0
        while !Task.isCancelled && generation == updatesGeneration {
            publishStatus(attempt == 0 ? .connecting : .reconnecting(attempt: attempt))
            do {
                try Task.checkCancellation()
                let snapshotData = try await transport.fetchSnapshotData(from: endpoint.snapshotURL)
                let snapshot = try PogoSnapshotMapper.decodeSnapshot(from: snapshotData)
                continuation.yield(snapshot)
                // Deliberately NOT `publishStatus(.connected)` here: a successful GET only
                // proves the HTTP server answered once, not that a live SSE connection
                // exists. `.connected` is reserved for real SSE activity below, so a
                // Dashboard reading `connectionStatus` never shows "connected" for a
                // connection that hasn't actually opened yet.

                // Re-check before opening the SSE connection itself: a newer `updates()`
                // call may have superseded this loop while the snapshot GET was in
                // flight, and this is the one place that would otherwise still open a
                // second, now-unwanted SSE connection.
                guard generation == updatesGeneration else { break }

                var parser = SSELineParser()
                var receivedFirstActivity = false
                let watchdog = SSELivenessWatchdog(idleTimeout: livenessIdleTimeout, sleeper: watchdogSleeper)
                for try await line in watchdog.watch(transport.openEventStream(from: endpoint.eventsURL)) {
                    guard generation == updatesGeneration else { break }
                    try Task.checkCancellation()
                    if !receivedFirstActivity {
                        // The SSE HTTP connection is open AND something has actually come
                        // through it (a heartbeat comment or a real event) — only now is
                        // this truly "connected", per the class doc above.
                        receivedFirstActivity = true
                        attempt = 0
                        publishStatus(.connected)
                    }

                    if line.hasPrefix(":") {
                        // A heartbeat only proves the SSE socket is alive — see the class
                        // doc for why this no longer also re-fetches the snapshot.
                        continue
                    }

                    guard let event = parser.consume(line: line) else { continue }
                    guard event.event == nil || event.event == "snapshot" else { continue }
                    guard let eventData = event.data.data(using: .utf8) else { continue }
                    // A single malformed event is dropped rather than tearing down the
                    // whole connection — mirrors the "unknown kind/status never crashes
                    // decoding" safety requirement.
                    if let next = try? PogoSnapshotMapper.decodeSnapshot(from: eventData) {
                        continuation.yield(next)
                        attempt = 0
                        publishStatus(.connected)
                    }
                }
                // The SSE stream ended — server closed it, or the liveness watchdog gave up
                // waiting and tore it down — fall through to reconnect.
            } catch is CancellationError {
                break
            } catch {
                if Task.isCancelled { break }
                publishStatus(.failed(Self.describe(error)))
            }

            guard !Task.isCancelled && generation == updatesGeneration else { break }
            attempt += 1
            do {
                try await sleeper.sleep(seconds: ReconnectBackoff.delaySeconds(forAttempt: attempt))
            } catch {
                break // cancelled while backing off
            }
        }

        if generation == updatesGeneration {
            publishStatus(.idle)
        }
    }

    private nonisolated static func describe(_ error: Error) -> String {
        if let apiError = error as? PogoAPIError {
            return apiError.errorDescription ?? "알 수 없는 오류"
        }
        return (error as NSError).localizedDescription
    }
}
