import Foundation
import XCTest

/// Polls `condition` until it's true or `timeout` elapses, instead of a single fixed
/// `Task.sleep` — keeps async regression tests both fast (no waiting once the condition is
/// already met) and robust (no flaky fixed-delay guess for how long a reconnect/watchdog
/// cycle takes).
@MainActor
func waitUntil(
    timeout: TimeInterval = 2,
    pollInterval: Duration = .milliseconds(5),
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping @MainActor () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try await Task.sleep(for: pollInterval)
    }
    XCTFail("condition not met within \(timeout)s", file: file, line: line)
}
