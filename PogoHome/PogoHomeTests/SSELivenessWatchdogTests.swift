import XCTest
@testable import PogoHome

final class SSELivenessWatchdogTests: XCTestCase {
    func testLinesArriveWithinTheIdleWindowAreForwardedUnchanged() async throws {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let watchdog = SSELivenessWatchdog(idleTimeout: 0.15, sleeper: RealAsyncSleeper())
        let watched = watchdog.watch(stream)

        let collector = Task { () -> [String] in
            var lines: [String] = []
            for try await line in watched { lines.append(line) }
            return lines
        }

        for index in 0..<4 {
            try await Task.sleep(for: .milliseconds(50)) // well under the 150ms idle timeout
            continuation.yield("line-\(index)")
        }
        continuation.finish()

        let lines = try await collector.value
        XCTAssertEqual(lines, (0..<4).map { "line-\($0)" }, "heartbeats/events arriving inside the window must never trip the watchdog")
    }

    func testSnapshotEventLinesAlsoResetTheIdleDeadline() async throws {
        // The watchdog treats every raw line the same way — this exercises real multi-line
        // `event: snapshot` / `data: ...` chunks (not just heartbeat comments) to confirm
        // they count as liveness activity too.
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let watchdog = SSELivenessWatchdog(idleTimeout: 0.15, sleeper: RealAsyncSleeper())
        let watched = watchdog.watch(stream)

        let collector = Task { () -> [String] in
            var lines: [String] = []
            for try await line in watched { lines.append(line) }
            return lines
        }

        let eventLines = PogoAPIFixtures.sseSnapshotEvent(json: PogoAPIFixtures.fullSnapshotJSON())
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(50))
            for line in eventLines { continuation.yield(line) }
        }
        continuation.finish()

        let lines = try await collector.value
        XCTAssertEqual(lines.count, eventLines.count * 3)
    }

    func testIdleTimeoutClosesTheConnectionAndThrows() async throws {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let watchdog = SSELivenessWatchdog(idleTimeout: 0.05, sleeper: RealAsyncSleeper())
        let watched = watchdog.watch(stream)

        let collector = Task { () -> Result<[String], Error> in
            var lines: [String] = []
            do {
                for try await line in watched { lines.append(line) }
                return .success(lines)
            } catch {
                return .failure(error)
            }
        }

        // Send nothing — real-world equivalent of a Linux service killed without a FIN.
        switch await collector.value {
        case .success:
            XCTFail("expected idle timeout to throw")
        case let .failure(error):
            XCTAssertEqual(error as? SSELivenessWatchdog.LivenessError, .idleTimeout)
        }

        continuation.yield("too-late") // must be a silent no-op, not a crash
    }

    func testCancellingTheConsumerTearsDownTheUpstreamConnection() async throws {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let terminated = FlagBox()
        continuation.onTermination = { _ in Task { await terminated.set(true) } }

        // A long idle timeout: this test proves *cancellation* tears the upstream down, not
        // the watchdog's own timer.
        let watchdog = SSELivenessWatchdog(idleTimeout: 5, sleeper: RealAsyncSleeper())
        let watched = watchdog.watch(stream)

        let consumer = Task {
            for try await _ in watched {}
        }
        try await Task.sleep(for: .milliseconds(30))
        consumer.cancel()

        try await waitUntil { await terminated.get() }
    }

    func testUpstreamFinishingNormallyEndsTheWatchedStreamWithoutError() async throws {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let watchdog = SSELivenessWatchdog(idleTimeout: 1, sleeper: RealAsyncSleeper())
        let watched = watchdog.watch(stream)

        let collector = Task { () -> Result<[String], Error> in
            var lines: [String] = []
            do {
                for try await line in watched { lines.append(line) }
                return .success(lines)
            } catch {
                return .failure(error)
            }
        }
        continuation.yield("only-line")
        continuation.finish()

        switch try await collector.value.get() {
        case ["only-line"]: break
        default: XCTFail("expected the single forwarded line and a clean finish")
        }
    }
}

private actor FlagBox {
    private var value = false
    func set(_ newValue: Bool) { value = newValue }
    func get() -> Bool { value }
}
