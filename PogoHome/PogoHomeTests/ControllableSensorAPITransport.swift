import Foundation
@testable import PogoHome

/// A `SensorAPITransport` double that gives the test live control over an SSE connection
/// while it's open — unlike `ScriptedSensorAPITransport`, whose event sessions are a finite
/// array that ends the moment it's exhausted, this one can be held open indefinitely (to
/// simulate a hung connection, e.g. for the liveness watchdog) or fed lines one at a time in
/// real time (to simulate heartbeats arriving on a schedule). Snapshot GETs are served by a
/// closure the test supplies, so it can hand back different bodies (including an empty
/// registry) across calls.
actor ControllableSensorAPITransport: SensorAPITransport {
    typealias SnapshotProvider = @Sendable () async throws -> Data

    private var snapshotProvider: SnapshotProvider
    private(set) var snapshotFetchCount = 0
    private(set) var eventStreamOpenCount = 0
    /// The continuation for whichever SSE session is currently open, and the session id it
    /// belongs to — so a termination callback from an old, already-superseded session can
    /// never clear the *new* session's continuation.
    private var current: (id: Int, continuation: AsyncThrowingStream<String, Error>.Continuation)?

    init(snapshotProvider: @escaping SnapshotProvider) {
        self.snapshotProvider = snapshotProvider
    }

    func setSnapshotProvider(_ provider: @escaping SnapshotProvider) {
        snapshotProvider = provider
    }

    func fetchSnapshotData(from url: URL) async throws -> Data {
        snapshotFetchCount += 1
        return try await snapshotProvider()
    }

    nonisolated func openEventStream(from url: URL) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task { await self.register(continuation) }
        }
    }

    private func register(_ continuation: AsyncThrowingStream<String, Error>.Continuation) {
        eventStreamOpenCount += 1
        let id = eventStreamOpenCount
        current = (id, continuation)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.clearIfCurrent(id) }
        }
    }

    private func clearIfCurrent(_ id: Int) {
        if current?.id == id {
            current = nil
        }
    }

    /// Sends one line on whatever SSE session is currently open. A no-op if none is open
    /// (e.g. the test raced ahead of the reconnect loop) so tests can call it defensively.
    func sendLine(_ line: String) {
        current?.continuation.yield(line)
    }

    func sendLines(_ lines: [String]) {
        for line in lines { current?.continuation.yield(line) }
    }

    func finishCurrentEventStream() {
        current?.continuation.finish()
    }

    func failCurrentEventStream(_ error: Error) {
        current?.continuation.finish(throwing: error)
    }

    /// Whether an SSE session is currently open and being consumed — lets a test wait for
    /// "the reconnect loop has opened its connection" without a fixed sleep.
    var hasOpenEventStream: Bool { current != nil }
}
