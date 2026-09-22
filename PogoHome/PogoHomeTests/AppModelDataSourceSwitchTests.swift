import XCTest
@testable import PogoHome

/// Covers switching `AppModel` between data sources — the Settings "Mock ↔ Live" toggle
/// and Live base-URL edits both go through `AppModel.replace(dataSource:)`.
@MainActor
final class AppModelDataSourceSwitchTests: XCTestCase {
    func testReplacingDataSourceCancelsThePreviousOneAndStartsExactlyOneNewConnection() async {
        let first = TrackingDataSource()
        let second = TrackingDataSource()
        let model = AppModel(dataSource: first)

        model.start()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(first.updatesCallCount, 1)
        XCTAssertFalse(first.wasCancelled)

        // Simulates a Settings change (mode toggle or URL edit): exactly one call.
        model.replace(dataSource: second)
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertTrue(first.wasCancelled, "the previous data source's update stream must be torn down")
        XCTAssertEqual(second.updatesCallCount, 1, "replace must start exactly one new connection")
        XCTAssertFalse(second.wasCancelled)
    }

    func testMultipleReplacementsNeverLeaveMoreThanOneLiveConnection() async {
        let sources = (0..<3).map { _ in TrackingDataSource() }
        let model = AppModel(dataSource: sources[0])
        model.start()

        model.replace(dataSource: sources[1])
        model.replace(dataSource: sources[2])
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertTrue(sources[0].wasCancelled)
        XCTAssertTrue(sources[1].wasCancelled)
        XCTAssertFalse(sources[2].wasCancelled)
        for source in sources {
            XCTAssertEqual(source.updatesCallCount, 1)
        }
    }

    func testStopThenStartResumesTheSameDataSourceExactlyOnce() async {
        let source = TrackingDataSource()
        let model = AppModel(dataSource: source)

        model.start()
        try? await Task.sleep(for: .milliseconds(20))
        model.stop()
        try? await Task.sleep(for: .milliseconds(20))
        model.start()
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(source.updatesCallCount, 2, "one call per start(), but never overlapping")
    }
}

@MainActor
private final class TrackingDataSource: SensorDataSource {
    private(set) var updatesCallCount = 0
    private(set) var wasCancelled = false
    private let snapshot: HomeSnapshot

    init(snapshot: HomeSnapshot = MockSensorFixtures.previewSnapshot) {
        self.snapshot = snapshot
    }

    func currentSnapshot() async throws -> HomeSnapshot { snapshot }

    func updates() -> AsyncStream<HomeSnapshot> {
        updatesCallCount += 1
        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.wasCancelled = true }
            }
        }
    }
}
