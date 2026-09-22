import Foundation
@testable import PogoHome

/// A `SensorAPITransport` double whose snapshot responses and SSE lines are scripted by
/// the test, with no real networking involved. Snapshot fetches are served in order from
/// `snapshotScript` (repeating the last entry once exhausted); each call to
/// `openEventStream` opens a fresh scripted SSE session from `eventStreamScript`.
actor ScriptedSensorAPITransport: SensorAPITransport {
    enum SnapshotResult {
        case success(Data)
        case failure(Error)
    }

    /// One scripted SSE "session": the lines it yields (in order, with simulated delays
    /// baked in only via ordering — no real waiting), and how it ends.
    struct EventSession {
        enum Ending {
            case finish
            case fail(Error)
        }
        let lines: [String]
        let ending: Ending
    }

    private var snapshotScript: [SnapshotResult]
    private var eventScript: [EventSession]

    private(set) var snapshotFetchCount = 0
    private(set) var eventStreamOpenCount = 0

    init(snapshotScript: [SnapshotResult], eventScript: [EventSession]) {
        self.snapshotScript = snapshotScript
        self.eventScript = eventScript
    }

    func fetchSnapshotData(from url: URL) async throws -> Data {
        snapshotFetchCount += 1
        let index = min(snapshotFetchCount - 1, snapshotScript.count - 1)
        guard index >= 0 else { throw PogoAPIError.transport("no script") }
        switch snapshotScript[index] {
        case let .success(data): return data
        case let .failure(error): throw error
        }
    }

    nonisolated func openEventStream(from url: URL) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let session = await self.nextEventSession()
                guard let session else {
                    continuation.finish()
                    return
                }
                for line in session.lines {
                    guard !Task.isCancelled else { return }
                    continuation.yield(line)
                }
                guard !Task.isCancelled else { return }
                switch session.ending {
                case .finish: continuation.finish()
                case let .fail(error): continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func nextEventSession() -> EventSession? {
        eventStreamOpenCount += 1
        guard !eventScript.isEmpty else { return nil }
        let index = min(eventStreamOpenCount - 1, eventScript.count - 1)
        return eventScript[index]
    }
}

/// A no-delay `AsyncSleeping` that records every requested delay instead of waiting, so
/// reconnect-loop tests run instantly regardless of backoff length.
actor RecordingSleeper: AsyncSleeping {
    private(set) var recordedDelays: [Double] = []
    private var sleepCallCount = 0
    /// Optional cap on how many sleeps to honor before throwing `CancellationError`, so a
    /// test can stop an otherwise-infinite reconnect loop after N attempts.
    private var maxSleeps: Int?

    func setMaxSleeps(_ value: Int?) {
        maxSleeps = value
    }

    func sleep(seconds: Double) async throws {
        sleepCallCount += 1
        recordedDelays.append(seconds)
        if let maxSleeps, sleepCallCount > maxSleeps {
            throw CancellationError()
        }
    }
}
