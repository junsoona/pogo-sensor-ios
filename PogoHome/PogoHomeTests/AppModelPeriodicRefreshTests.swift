import XCTest
@testable import PogoHome

/// Covers `AppModel`'s independent periodic-refresh reconciliation — the fix for the field
/// regression where a running app never recovered from a Linux `pogo-matter-bridge.service`
/// restart until it was force-quit and relaunched. `updates()`/SSE activity (heartbeats, a
/// later `snapshot` event) is deliberately never the only way recovery can happen; these
/// tests drive data sources that only ever push once over `updates()` and otherwise go
/// completely silent, so recovery can only be observed if the independent periodic
/// `currentSnapshot()` polling in `AppModel.runPeriodicRefresh` is doing its job.
///
/// All intervals here are 20-50ms, not the 5s production default, and every wait goes
/// through `waitUntil`'s bounded polling — nothing here waits out a real production tick.
@MainActor
final class AppModelPeriodicRefreshTests: XCTestCase {
    // MARK: - A: independent recovery with no further SSE activity at all

    func testIndependentRecoveryWithNoFurtherSSEActivityAtAll() async throws {
        let room = MockSensorFixtures.rooms[0]
        let idA = UUID()
        let idB = UUID()
        func fullSnapshot() -> HomeSnapshot {
            HomeSnapshot(timestamp: Date(), rooms: [room], modules: [
                SensorModule(id: idA, name: "A", roomID: room.id, readings: [SensorReading(kind: .temperature, value: 22, timestamp: Date(), status: .normal)], isOnline: true, lastSeen: Date()),
                SensorModule(id: idB, name: "B", roomID: room.id, readings: [SensorReading(kind: .humidity, value: 40, timestamp: Date(), status: .normal)], isOnline: true, lastSeen: Date()),
            ])
        }
        let topologyOnly = HomeSnapshot(timestamp: Date(), rooms: [room], modules: [
            SensorModule(id: idA, name: "A", roomID: room.id, readings: [], isOnline: true, lastSeen: Date()),
        ])

        // The periodic GET mirrors reality: before the registry actually recovers
        // server-side, a GET returns the same partial state SSE already reported.
        let source = PeriodicRefreshDataSource(initial: fullSnapshot(), periodicRefreshInterval: 0.03) { topologyOnly }
        let model = AppModel(dataSource: source)
        model.start()
        try await waitUntil { model.health == .healthy }

        source.updatesContinuation?.yield(topologyOnly)
        try await waitUntil { model.isRegistryRecovering }
        XCTAssertEqual(model.snapshot.modules.count, 2, "last complete snapshot must stay on screen while recovering")

        // Linux now has the full registry again, but never says so over SSE again — no
        // later `snapshot` event, no heartbeat, nothing. Only the periodic GET can see this.
        source.currentSnapshotResult = fullSnapshot

        try await waitUntil(timeout: 2) { !model.isRegistryRecovering && model.health == .healthy }
        XCTAssertEqual(model.snapshot.modules.count, 2)
        XCTAssertGreaterThan(source.currentSnapshotCallCount, 0, "recovery must have gone through periodic GET")

        model.stop()
    }

    // MARK: - B: periodic GET failure never clears state or falsely recovers

    func testPeriodicRefreshFailureDuringRecoveryNeitherClearsTheSnapshotNorFalselyRecovers() async throws {
        struct Boom: Error {}
        let room = MockSensorFixtures.rooms[0]
        let idA = UUID()
        let idB = UUID()
        func fullSnapshot() -> HomeSnapshot {
            HomeSnapshot(timestamp: Date(), rooms: [room], modules: [
                SensorModule(id: idA, name: "A", roomID: room.id, readings: [SensorReading(kind: .temperature, value: 22, timestamp: Date(), status: .normal)], isOnline: true, lastSeen: Date()),
                SensorModule(id: idB, name: "B", roomID: room.id, readings: [SensorReading(kind: .humidity, value: 40, timestamp: Date(), status: .normal)], isOnline: true, lastSeen: Date()),
            ])
        }
        let topologyOnly = HomeSnapshot(timestamp: Date(), rooms: [room], modules: [
            SensorModule(id: idA, name: "A", roomID: room.id, readings: [], isOnline: true, lastSeen: Date()),
        ])

        let source = PeriodicRefreshDataSource(initial: fullSnapshot(), periodicRefreshInterval: 0.03) { throw Boom() }
        let model = AppModel(dataSource: source)
        model.start()
        try await waitUntil { model.health == .healthy }

        source.updatesContinuation?.yield(topologyOnly)
        try await waitUntil { model.isRegistryRecovering }

        // A handful of periodic GETs fail outright while recovering.
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.snapshot.modules.count, 2, "a failed periodic GET must never clear the last good snapshot")
        XCTAssertTrue(model.isRegistryRecovering, "a failed periodic GET must never fake a recovery")
        XCTAssertNotEqual(model.health, .healthy)

        source.currentSnapshotResult = fullSnapshot
        try await waitUntil(timeout: 2) { !model.isRegistryRecovering && model.health == .healthy }
        model.stop()
    }

    // MARK: - C: no duplicate polling tasks

    func testStartCalledMultipleTimesStartsExactlyOnePollingLoop() async throws {
        let source = PeriodicRefreshDataSource(initial: MockSensorFixtures.previewSnapshot, periodicRefreshInterval: 0.03) { MockSensorFixtures.previewSnapshot }
        let model = AppModel(dataSource: source)

        model.start()
        model.start()
        model.start()

        // One loop ticking every 30ms for 160ms fires ~5 times; a second, duplicate loop
        // would roughly double that — the bound below is well under double so it catches a
        // duplicate without being sensitive to exact scheduler timing.
        try? await Task.sleep(for: .milliseconds(160))
        XCTAssertGreaterThanOrEqual(source.currentSnapshotCallCount, 1)
        XCTAssertLessThanOrEqual(source.currentSnapshotCallCount, 7, "start() called repeatedly must never start more than one polling loop")

        model.stop()
    }

    func testReplaceCancelsOldSourcesPollingAndStartsExactlyOneNewLoop() async throws {
        let first = PeriodicRefreshDataSource(initial: MockSensorFixtures.previewSnapshot, periodicRefreshInterval: 0.03) { MockSensorFixtures.previewSnapshot }
        let second = PeriodicRefreshDataSource(initial: MockSensorFixtures.previewSnapshot, periodicRefreshInterval: 0.03) { MockSensorFixtures.previewSnapshot }
        let model = AppModel(dataSource: first)
        model.start()

        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertGreaterThan(first.currentSnapshotCallCount, 0)

        model.replace(dataSource: second)
        let firstCountAtReplace = first.currentSnapshotCallCount

        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(first.currentSnapshotCallCount, firstCountAtReplace, "the previous data source's polling must stop at replace(dataSource:)")
        XCTAssertGreaterThan(second.currentSnapshotCallCount, 0, "the new data source must be the one polled")

        model.stop()
    }

    func testStopThenStartResumesPollingExactlyOnce() async throws {
        let source = PeriodicRefreshDataSource(initial: MockSensorFixtures.previewSnapshot, periodicRefreshInterval: 0.03) { MockSensorFixtures.previewSnapshot }
        let model = AppModel(dataSource: source)

        model.start()
        try? await Task.sleep(for: .milliseconds(60))
        model.stop()
        let countAtStop = source.currentSnapshotCallCount

        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(source.currentSnapshotCallCount, countAtStop, "no polling ticks must fire while stopped")

        model.start()
        try? await Task.sleep(for: .milliseconds(160))
        XCTAssertLessThanOrEqual(source.currentSnapshotCallCount - countAtStop, 7, "resuming must start exactly one new loop, not stack another")

        model.stop()
    }

    // MARK: - D: Mock mode never polls

    func testMockDataSourceHasNoPeriodicRefreshInterval() {
        let source = MockSensorDataSource()
        // This is the actual mechanism that keeps `AppModel` from ever calling
        // `currentSnapshot()` on a mock source on a timer: `start()` only spins up the
        // periodic-refresh Task when `periodicRefreshInterval` is non-nil.
        XCTAssertNil(source.periodicRefreshInterval, "MockSensorDataSource must opt out of periodic refresh — its own updates() drift is the only thing that should move it")
    }

    // MARK: - F: a full snapshot with the same module set but changed values still applies

    func testFullSnapshotWithSameModuleSetButChangedValuesStillApplies() async throws {
        let room = MockSensorFixtures.rooms[0]
        let ids = [UUID(), UUID()]
        func snapshot(value: Double) -> HomeSnapshot {
            HomeSnapshot(timestamp: Date(), rooms: [room], modules: ids.enumerated().map { index, id in
                SensorModule(id: id, name: "모듈 \(index)", roomID: room.id, readings: [SensorReading(kind: .temperature, value: value, timestamp: Date(), status: .normal)], isOnline: true, lastSeen: Date())
            })
        }

        let source = PeriodicRefreshDataSource(initial: snapshot(value: 20), periodicRefreshInterval: 0.03) { snapshot(value: 20) }
        let model = AppModel(dataSource: source)
        model.start()
        try await waitUntil { model.health == .healthy }

        source.currentSnapshotResult = { snapshot(value: 77) }
        try await waitUntil(timeout: 2) {
            model.snapshot.modules.allSatisfy { $0.readings.first?.value == 77 }
        }

        model.stop()
    }
}

/// A `SensorDataSource` double giving the test direct control over both `updates()` (via its
/// continuation, like `RaceableDataSource` in `AppModelReconnectRegressionTests`) and what
/// `currentSnapshot()` returns on each periodic-refresh tick — including making it throw, and
/// changing its result mid-test to simulate the server's state changing between ticks.
@MainActor
private final class PeriodicRefreshDataSource: SensorDataSource {
    private(set) var updatesContinuation: AsyncStream<HomeSnapshot>.Continuation?
    private(set) var currentSnapshotCallCount = 0
    var currentSnapshotResult: () throws -> HomeSnapshot
    let periodicRefreshInterval: Double?
    private let initial: HomeSnapshot

    init(initial: HomeSnapshot, periodicRefreshInterval: Double?, currentSnapshotResult: @escaping () throws -> HomeSnapshot) {
        self.initial = initial
        self.periodicRefreshInterval = periodicRefreshInterval
        self.currentSnapshotResult = currentSnapshotResult
    }

    func currentSnapshot() async throws -> HomeSnapshot {
        currentSnapshotCallCount += 1
        return try currentSnapshotResult()
    }

    func updates() -> AsyncStream<HomeSnapshot> {
        AsyncStream { continuation in
            updatesContinuation = continuation
            continuation.yield(initial)
        }
    }
}
