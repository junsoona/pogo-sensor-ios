import XCTest
@testable import PogoHome

/// Covers `AppModel`'s reconnect/health regressions: the "never let a transient empty
/// snapshot erase the last good one" merge policy, the stale-generation guard that keeps a
/// just-replaced data source's in-flight callbacks from overwriting the new one, and that
/// `stop()`/`health` report connection state accurately.
@MainActor
final class AppModelReconnectRegressionTests: XCTestCase {
    func testEmptyIncomingSnapshotNeverOverwritesAPreviouslyGoodOne() async throws {
        let source = RaceableDataSource(initial: MockSensorFixtures.previewSnapshot)
        let model = AppModel(dataSource: source)
        model.start()
        try await waitUntil { !model.snapshot.modules.isEmpty }

        let empty = HomeSnapshot(timestamp: Date(), rooms: [], modules: [])
        source.updatesContinuation?.yield(empty)
        // There's nothing else to observe once the (correct) no-op has happened, so this
        // waits out a short window rather than a condition.
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertFalse(model.snapshot.modules.isEmpty, "a transient empty snapshot must not erase the last good one")
        XCTAssertNotNil(model.lastSyncAt, "an empty snapshot still counts as API activity for freshness")
    }

    func testPartialIncomingSnapshotDoesNotReplaceLastCompleteState() async throws {
        let source = RaceableDataSource(initial: MockSensorFixtures.previewSnapshot)
        let model = AppModel(dataSource: source)
        model.start()
        try await waitUntil { !model.snapshot.modules.isEmpty }

        let partial = HomeSnapshot(
            timestamp: Date(),
            rooms: MockSensorFixtures.rooms,
            modules: [SensorModule(id: UUID(), name: "새 모듈", roomID: MockSensorFixtures.rooms[0].id, readings: [], isOnline: true, lastSeen: Date())]
        )
        let original = model.snapshot
        source.updatesContinuation?.yield(partial)
        try await waitUntil { model.isRegistryRecovering }

        XCTAssertEqual(model.snapshot, original)
        XCTAssertEqual(model.health, .recoveringRegistry)
    }

    func testStrictSubsetWithReadingsIsStillHeldUntilLastCompleteSetReturns() async throws {
        let complete = makeCompleteSnapshot(moduleIDs: [UUID(), UUID()])
        let source = RaceableDataSource(initial: complete)
        let model = AppModel(dataSource: source)
        model.start()
        try await waitUntil { model.health == .healthy }

        let partial = HomeSnapshot(timestamp: Date(), rooms: complete.rooms, modules: [complete.modules[0]])
        source.updatesContinuation?.yield(partial)
        try await waitUntil { model.isRegistryRecovering }

        XCTAssertEqual(model.snapshot, complete)
        XCTAssertEqual(model.health, .recoveringRegistry)
    }

    func testFullSetAfterPartialRecoveryIsAppliedAndClearsRecovery() async throws {
        let ids = [UUID(), UUID()]
        let initial = makeCompleteSnapshot(moduleIDs: ids)
        let source = RaceableDataSource(initial: initial)
        let model = AppModel(dataSource: source)
        model.start()
        try await waitUntil { model.health == .healthy }

        source.updatesContinuation?.yield(HomeSnapshot(timestamp: Date(), rooms: initial.rooms, modules: [initial.modules[0]]))
        try await waitUntil { model.isRegistryRecovering }

        let recovered = makeCompleteSnapshot(moduleIDs: ids, value: 99)
        source.updatesContinuation?.yield(recovered)
        try await waitUntil { !model.isRegistryRecovering && model.snapshot == recovered }

        XCTAssertEqual(model.health, .healthy)
    }

    func testFirstTopologyOnlyModuleIsShownAsWaitingForData() async throws {
        let topologyOnly = HomeSnapshot(
            timestamp: Date(),
            rooms: MockSensorFixtures.rooms,
            modules: [SensorModule(id: UUID(), name: "새 모듈", roomID: MockSensorFixtures.rooms[0].id, readings: [], isOnline: true, lastSeen: Date())]
        )
        let source = RaceableDataSource(initial: topologyOnly)
        let model = AppModel(dataSource: source)
        model.start()
        try await waitUntil { model.snapshot.modules.count == 1 }

        XCTAssertEqual(model.health, .waitingForData)
        XCTAssertFalse(model.health.isCurrentStateVerified)
    }

    func testFirstSingleModuleWithReadingsCanBeHealthy() async throws {
        let complete = makeCompleteSnapshot(moduleIDs: [UUID()])
        let source = RaceableDataSource(initial: complete)
        let model = AppModel(dataSource: source)
        model.start()
        try await waitUntil { model.health == .healthy }

        XCTAssertEqual(model.snapshot.modules.count, 1)
        XCTAssertFalse(model.isRegistryRecovering)
    }

    func testStaleGenerationCallbacksNeverOverwriteANewerDataSource() async throws {
        let first = RaceableDataSource(initial: MockSensorFixtures.previewSnapshot)
        let second = RaceableDataSource(initial: MockSensorFixtures.previewSnapshot)
        let model = AppModel(dataSource: first)
        model.start()
        try await waitUntil { !model.snapshot.modules.isEmpty }

        model.replace(dataSource: second)
        try await waitUntil { model.connectionStatus == .connected }
        let snapshotAfterReplace = model.snapshot
        let statusAfterReplace = model.connectionStatus

        // The exact race this guards against: the OLD data source's continuation is still
        // capable of yielding (its underlying task requested cancellation but hadn't
        // actually finished tearing down yet) after `replace` already installed the new one.
        let staleModule = SensorModule(id: UUID(), name: "정체된 모듈", roomID: UUID(), readings: [], isOnline: true, lastSeen: Date())
        let staleSnapshot = HomeSnapshot(timestamp: Date(), rooms: [], modules: [staleModule])
        first.updatesContinuation?.yield(staleSnapshot)
        first.statusContinuation?.yield(.failed("stale"))
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(model.snapshot, snapshotAfterReplace, "a superseded data source's snapshot must never land after replace(dataSource:)")
        XCTAssertEqual(model.connectionStatus, statusAfterReplace, "a superseded data source's status must never land after replace(dataSource:)")
    }

    func testStopPreservesLastSnapshotButClearsConnectionStatus() async throws {
        let source = RaceableDataSource(initial: MockSensorFixtures.previewSnapshot)
        let model = AppModel(dataSource: source)
        model.start()
        try await waitUntil { model.connectionStatus == .connected }
        let snapshotBeforeStop = model.snapshot

        model.stop()

        XCTAssertEqual(model.snapshot, snapshotBeforeStop)
        XCTAssertEqual(model.connectionStatus, .idle)
    }

    func testHealthReflectsDisconnectedStatusEvenWithAGoodSnapshotStillOnScreen() async throws {
        // `MockSensorFixtures.previewSnapshot` deliberately includes an offline module and
        // stale/conditioning readings (to showcase those states in SwiftUI previews), so it
        // can never itself read as `.healthy` — this test needs a snapshot with nothing to
        // flag, to isolate "connection dropped" as the only reason `health` isn't healthy.
        let cleanModule = SensorModule(
            id: UUID(),
            name: "정상 모듈",
            roomID: MockSensorFixtures.rooms[0].id,
            readings: [SensorReading(kind: .temperature, value: 22, timestamp: Date(), status: .normal)],
            isOnline: true,
            lastSeen: Date()
        )
        let cleanSnapshot = HomeSnapshot(timestamp: Date(), rooms: MockSensorFixtures.rooms, modules: [cleanModule])
        let source = RaceableDataSource(initial: cleanSnapshot)
        let model = AppModel(dataSource: source)
        model.start()
        try await waitUntil { model.health == .healthy }

        model.stop()

        XCTAssertFalse(model.snapshot.modules.isEmpty, "Dashboard must keep showing the last good snapshot")
        XCTAssertEqual(model.health, .reconnecting, "but health must not still claim healthy once disconnected")
    }

    private func makeCompleteSnapshot(moduleIDs: [UUID], value: Double = 22) -> HomeSnapshot {
        let room = MockSensorFixtures.rooms[0]
        let modules = moduleIDs.enumerated().map { index, id in
            SensorModule(
                id: id,
                name: "모듈 \(index)",
                roomID: room.id,
                readings: [SensorReading(kind: .temperature, value: value, timestamp: Date(), status: .normal)],
                isOnline: true,
                lastSeen: Date()
            )
        }
        return HomeSnapshot(timestamp: Date(), rooms: [room], modules: modules)
    }
}

/// A `SensorDataSource` double that hands its `updates()`/`connectionStatusUpdates()`
/// continuations directly to the test, so it can drive them at will — including after
/// `AppModel.replace(dataSource:)`/`stop()` has already moved on, to deterministically
/// reproduce the "stale generation" race rather than relying on incidental Task-cancellation
/// timing.
@MainActor
private final class RaceableDataSource: SensorDataSource {
    private(set) var updatesContinuation: AsyncStream<HomeSnapshot>.Continuation?
    private(set) var statusContinuation: AsyncStream<DataSourceConnectionStatus>.Continuation?
    private let initial: HomeSnapshot

    init(initial: HomeSnapshot) {
        self.initial = initial
    }

    func currentSnapshot() async throws -> HomeSnapshot { initial }

    func updates() -> AsyncStream<HomeSnapshot> {
        AsyncStream { continuation in
            updatesContinuation = continuation
            continuation.yield(initial)
        }
    }

    func connectionStatusUpdates() -> AsyncStream<DataSourceConnectionStatus> {
        AsyncStream { continuation in
            statusContinuation = continuation
            continuation.yield(.connected)
        }
    }
}
