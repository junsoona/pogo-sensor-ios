import XCTest
@testable import PogoHome

@MainActor
final class AppModelTests: XCTestCase {
    func testStartIsIdempotentAndDoesNotDuplicateUpdatesConsumption() async {
        let dataSource = CountingDataSource(snapshot: MockSensorFixtures.previewSnapshot)
        let model = AppModel(dataSource: dataSource)

        model.start()
        model.start()
        model.start()

        // Let the update-consuming Task actually run before asserting.
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(dataSource.updatesCallCount, 1)
    }
}

@MainActor
private final class CountingDataSource: SensorDataSource {
    private(set) var updatesCallCount = 0
    private let snapshot: HomeSnapshot

    init(snapshot: HomeSnapshot) {
        self.snapshot = snapshot
    }

    func currentSnapshot() async throws -> HomeSnapshot {
        snapshot
    }

    func updates() -> AsyncStream<HomeSnapshot> {
        updatesCallCount += 1
        return AsyncStream { continuation in
            continuation.finish()
        }
    }
}
