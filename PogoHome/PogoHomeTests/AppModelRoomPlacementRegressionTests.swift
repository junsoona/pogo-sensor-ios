import SwiftData
import XCTest
@testable import PogoHome

/// Covers the "sensor room placement fails" field bug. The root cause was in
/// `ModuleEditorSheet` (a SwiftUI view: `.pickerStyle(.navigationLink)` pushes a system
/// picker screen, and popping back from it re-fires `onAppear` on the sheet's root Form,
/// which used to call `loadCurrentValues()` again and silently reset the just-picked
/// `roomID` before Save ran). That view-lifecycle defect isn't exercisable from an XCTest
/// target without a UI-test host, so these tests instead lock down every layer the fix
/// depends on staying correct: `AppModel.updateModule` must apply a new `roomID` to
/// `snapshot` immediately, that placement must survive later sensor-data refreshes and a
/// simulated app relaunch (store recreated over the same container), room deletion must move
/// placed modules to the fallback room, and a room-only update must never clobber a
/// previously-set custom name (or vice versa).
@MainActor
final class AppModelRoomPlacementRegressionTests: XCTestCase {
    func testPlacingModuleInNewRoomUpdatesSnapshotImmediately() async throws {
        let store = InMemoryHomeConfigurationStore(rooms: MockSensorFixtures.rooms)
        let model = AppModel(
            dataSource: StaticDataSource(snapshot: MockSensorFixtures.previewSnapshot),
            initialSnapshot: MockSensorFixtures.previewSnapshot,
            configurationStore: store
        )
        let moduleID = MockSensorFixtures.livingRoomEnvironmentModuleID
        XCTAssertEqual(model.module(with: moduleID)?.roomID, MockSensorFixtures.livingRoom.id)

        let newRoom = try await model.createRoom(name: "서재", symbolName: "books.vertical.fill")
        try await model.updateModule(id: moduleID, customName: nil, roomID: newRoom.id)

        XCTAssertEqual(model.module(with: moduleID)?.roomID, newRoom.id)
    }

    func testRoomPlacementSurvivesASubsequentSensorDataRefresh() async throws {
        let store = InMemoryHomeConfigurationStore(rooms: MockSensorFixtures.rooms)
        let source = RefreshableDataSource(initial: MockSensorFixtures.previewSnapshot)
        let model = AppModel(dataSource: source, configurationStore: store)
        model.start()
        try await waitUntil { !model.snapshot.modules.isEmpty }

        let moduleID = MockSensorFixtures.livingRoomEnvironmentModuleID
        let newRoom = try await model.createRoom(name: "서재", symbolName: "books.vertical.fill")
        try await model.updateModule(id: moduleID, customName: nil, roomID: newRoom.id)
        XCTAssertEqual(model.module(with: moduleID)?.roomID, newRoom.id)

        // A fresh reading from the data source still reports the module under its original
        // (unplaced) room — exactly like real hardware, which has no concept of the user's
        // room assignment. The overlay must keep winning.
        var refreshed = MockSensorFixtures.modules(referenceDate: Date())
        refreshed[0] = SensorModule(
            id: refreshed[0].id,
            name: refreshed[0].name,
            roomID: MockSensorFixtures.livingRoom.id,
            readings: refreshed[0].readings,
            isOnline: refreshed[0].isOnline,
            lastSeen: Date()
        )
        source.continuation?.yield(HomeSnapshot(timestamp: Date(), rooms: MockSensorFixtures.rooms, modules: refreshed))
        try await waitUntil { model.module(with: moduleID)?.lastSeen == refreshed[0].lastSeen }

        XCTAssertEqual(model.module(with: moduleID)?.roomID, newRoom.id, "a sensor-data refresh must not undo the user's room placement")
    }

    func testRoomPlacementSurvivesSimulatedAppRelaunch() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Schema(SwiftDataHomeConfigurationStore.modelTypes),
            configurations: configuration
        )
        let moduleID = MockSensorFixtures.livingRoomEnvironmentModuleID

        let firstStore = try SwiftDataHomeConfigurationStore(container: container)
        let firstModel = AppModel(
            dataSource: StaticDataSource(snapshot: MockSensorFixtures.previewSnapshot),
            initialSnapshot: MockSensorFixtures.previewSnapshot,
            configurationStore: firstStore
        )
        let newRoom = try await firstModel.createRoom(name: "테라스", symbolName: "tree.fill")
        try await firstModel.updateModule(id: moduleID, customName: nil, roomID: newRoom.id)

        // Simulate an app relaunch: a brand new store/model pair over the same persisted
        // container, exactly as `PogoHomeApp` would construct on the next launch.
        let relaunchedStore = try SwiftDataHomeConfigurationStore(container: container)
        let relaunchedModel = AppModel(
            dataSource: StaticDataSource(snapshot: MockSensorFixtures.previewSnapshot),
            initialSnapshot: MockSensorFixtures.previewSnapshot,
            configurationStore: relaunchedStore
        )

        XCTAssertEqual(relaunchedModel.module(with: moduleID)?.roomID, newRoom.id)
    }

    func testDeletingARoomMovesItsModulesToUnspecifiedInTheLiveSnapshot() async throws {
        let store = InMemoryHomeConfigurationStore(rooms: MockSensorFixtures.rooms)
        let model = AppModel(
            dataSource: StaticDataSource(snapshot: MockSensorFixtures.previewSnapshot),
            initialSnapshot: MockSensorFixtures.previewSnapshot,
            configurationStore: store
        )
        let moduleID = MockSensorFixtures.livingRoomEnvironmentModuleID
        let newRoom = try await model.createRoom(name: "서재", symbolName: "books.vertical.fill")
        try await model.updateModule(id: moduleID, customName: nil, roomID: newRoom.id)

        try await model.deleteRoom(id: newRoom.id)

        XCTAssertEqual(model.module(with: moduleID)?.roomID, ModuleCatalog.unspecifiedRoom.id)
    }

    func testRoomOnlyUpdatePreservesAnExistingCustomNameAndViceVersa() async throws {
        let store = InMemoryHomeConfigurationStore(rooms: MockSensorFixtures.rooms)
        let model = AppModel(
            dataSource: StaticDataSource(snapshot: MockSensorFixtures.previewSnapshot),
            initialSnapshot: MockSensorFixtures.previewSnapshot,
            configurationStore: store
        )
        let moduleID = MockSensorFixtures.livingRoomEnvironmentModuleID

        try await model.updateModule(id: moduleID, customName: "창가 센서", roomID: MockSensorFixtures.livingRoom.id)
        XCTAssertEqual(model.module(with: moduleID)?.name, "창가 센서")

        let newRoom = try await model.createRoom(name: "서재", symbolName: "books.vertical.fill")
        try await model.updateModule(id: moduleID, customName: "창가 센서", roomID: newRoom.id)

        XCTAssertEqual(model.module(with: moduleID)?.roomID, newRoom.id)
        XCTAssertEqual(model.module(with: moduleID)?.name, "창가 센서", "moving rooms must not drop a previously-set custom name")
    }
}

@MainActor
private final class StaticDataSource: SensorDataSource {
    private let snapshot: HomeSnapshot
    init(snapshot: HomeSnapshot) { self.snapshot = snapshot }
    func currentSnapshot() async throws -> HomeSnapshot { snapshot }
    func updates() -> AsyncStream<HomeSnapshot> {
        AsyncStream { continuation in
            continuation.yield(snapshot)
            continuation.finish()
        }
    }
    func connectionStatusUpdates() -> AsyncStream<DataSourceConnectionStatus> {
        AsyncStream { continuation in continuation.yield(.connected) }
    }
}

@MainActor
private final class RefreshableDataSource: SensorDataSource {
    private(set) var continuation: AsyncStream<HomeSnapshot>.Continuation?
    private let initial: HomeSnapshot
    init(initial: HomeSnapshot) { self.initial = initial }
    func currentSnapshot() async throws -> HomeSnapshot { initial }
    func updates() -> AsyncStream<HomeSnapshot> {
        AsyncStream { continuation in
            continuation.yield(initial)
            self.continuation = continuation
        }
    }
    func connectionStatusUpdates() -> AsyncStream<DataSourceConnectionStatus> {
        AsyncStream { continuation in continuation.yield(.connected) }
    }
}
