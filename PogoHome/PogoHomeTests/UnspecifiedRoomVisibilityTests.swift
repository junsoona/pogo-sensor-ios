import XCTest
@testable import PogoHome

/// "미지정 공간" is hidden from room lists (and the room count) while no module is placed in
/// it, and reappears the moment one is. The filter is display-only: the fallback room's fixed
/// id stays in `snapshot.rooms`, in persisted configuration, and in the sensor editor's room
/// picker (`editableRooms`) the whole time.
@MainActor
final class UnspecifiedRoomVisibilityTests: XCTestCase {
    private let unspecifiedID = ModuleCatalog.unspecifiedRoom.id

    func testEmptyUnspecifiedRoomIsHiddenButStillPersistedAndPickable() throws {
        let store = InMemoryHomeConfigurationStore()
        let model = makeModel(store: store)

        XCTAssertFalse(model.snapshot.hasModulesInUnspecifiedRoom)
        XCTAssertFalse(model.snapshot.visibleRooms.contains { $0.id == unspecifiedID })
        XCTAssertEqual(model.snapshot.visibleRooms.count, 3, "the room count must not include an empty 미지정 공간")

        XCTAssertTrue(model.snapshot.rooms.contains { $0.id == unspecifiedID }, "hiding must not drop the room from the snapshot")
        XCTAssertTrue(model.editableRooms.contains { $0.id == unspecifiedID }, "the sensor editor must still offer 미지정 공간")
        XCTAssertTrue(try store.load().rooms.contains { $0.id == unspecifiedID }, "hiding must not delete persisted data")
        XCTAssertNotNil(model.room(with: unspecifiedID))
    }

    func testMovingAModuleIntoUnspecifiedRoomShowsItImmediatelyAndMovingItOutHidesItAgain() async throws {
        let model = makeModel(store: InMemoryHomeConfigurationStore())
        let moduleID = MockSensorFixtures.livingRoomEnvironmentModuleID

        try await model.updateModule(id: moduleID, customName: nil, roomID: unspecifiedID)
        XCTAssertTrue(model.snapshot.visibleRooms.contains { $0.id == unspecifiedID })
        XCTAssertEqual(model.snapshot.visibleRooms.last?.id, unspecifiedID, "미지정 공간 still sorts last")
        XCTAssertEqual(model.snapshot.visibleRooms.count, 4)

        try await model.updateModule(id: moduleID, customName: nil, roomID: MockSensorFixtures.livingRoom.id)
        XCTAssertFalse(model.snapshot.visibleRooms.contains { $0.id == unspecifiedID })
        XCTAssertTrue(model.editableRooms.contains { $0.id == unspecifiedID })
    }

    func testDeletingARoomWithModulesRevealsUnspecifiedRoom() async throws {
        let model = makeModel(store: InMemoryHomeConfigurationStore())
        XCTAssertFalse(model.snapshot.visibleRooms.contains { $0.id == unspecifiedID })

        try await model.deleteRoom(id: MockSensorFixtures.bedroom.id)

        XCTAssertEqual(model.module(with: MockSensorFixtures.bedroomLightModuleID)?.roomID, unspecifiedID)
        XCTAssertTrue(model.snapshot.visibleRooms.contains { $0.id == unspecifiedID })
    }

    func testNewlyRegisteredModuleRevealsUnspecifiedRoom() async throws {
        let source = ControlledDataSource(initial: MockSensorFixtures.previewSnapshot)
        let model = AppModel(dataSource: source, configurationStore: InMemoryHomeConfigurationStore())
        model.start()
        try await waitUntil { !model.snapshot.modules.isEmpty }
        XCTAssertFalse(model.snapshot.visibleRooms.contains { $0.id == unspecifiedID })

        let newModule = SensorModule(
            id: UUID(),
            name: "새 센서 모듈",
            roomID: unspecifiedID,
            readings: [SensorReading(kind: .temperature, value: 22, timestamp: Date(), status: .normal)],
            isOnline: true,
            lastSeen: Date()
        )
        var modules = MockSensorFixtures.modules(referenceDate: Date())
        modules.append(newModule)
        source.continuation?.yield(HomeSnapshot(timestamp: Date(), rooms: MockSensorFixtures.rooms, modules: modules))

        try await waitUntil { model.module(with: newModule.id) != nil }
        XCTAssertTrue(model.snapshot.visibleRooms.contains { $0.id == unspecifiedID })
        model.stop()
    }

    /// A module that merely goes offline stays in the snapshot (API contract), so the room it
    /// sits in stays visible and its saved placement is untouched; the same holds while the
    /// app is disconnected and keeps showing the last good snapshot.
    func testTemporarilyOfflineModuleKeepsUnspecifiedRoomVisibleAndPlacementUnchanged() async throws {
        let store = InMemoryHomeConfigurationStore()
        let source = ControlledDataSource(initial: MockSensorFixtures.previewSnapshot)
        let model = AppModel(dataSource: source, configurationStore: store)
        model.start()
        try await waitUntil { !model.snapshot.modules.isEmpty }

        let moduleID = MockSensorFixtures.livingRoomEnvironmentModuleID
        try await model.updateModule(id: moduleID, customName: nil, roomID: unspecifiedID)
        XCTAssertTrue(model.snapshot.visibleRooms.contains { $0.id == unspecifiedID })

        let offline = MockSensorFixtures.modules(referenceDate: Date()).map { module in
            SensorModule(
                id: module.id,
                name: module.name,
                roomID: module.roomID,
                readings: module.readings,
                isOnline: module.id == moduleID ? false : module.isOnline,
                lastSeen: module.lastSeen
            )
        }
        source.continuation?.yield(HomeSnapshot(timestamp: Date(), rooms: MockSensorFixtures.rooms, modules: offline))
        try await waitUntil { model.module(with: moduleID)?.isOnline == false }

        XCTAssertEqual(model.module(with: moduleID)?.roomID, unspecifiedID)
        XCTAssertTrue(model.snapshot.visibleRooms.contains { $0.id == unspecifiedID })
        XCTAssertEqual(try store.load().modules[moduleID]?.roomID, unspecifiedID)

        model.stop()
        XCTAssertTrue(model.snapshot.visibleRooms.contains { $0.id == unspecifiedID }, "a disconnect keeps the last snapshot, and so the room")
        XCTAssertEqual(try store.load().modules[moduleID]?.roomID, unspecifiedID)
    }

    func testVisibleRoomsIsAPureFilterOverTheSnapshot() {
        let module = SensorModule(
            id: UUID(), name: "A", roomID: MockSensorFixtures.livingRoom.id,
            readings: [], isOnline: true, lastSeen: Date()
        )
        let rooms = MockSensorFixtures.rooms + [ModuleCatalog.unspecifiedRoom]
        let hidden = HomeSnapshot(timestamp: Date(), rooms: rooms, modules: [module])
        XCTAssertEqual(hidden.visibleRooms.map(\.id), MockSensorFixtures.rooms.map(\.id))
        XCTAssertEqual(hidden.rooms.count, 4)

        let empty = HomeSnapshot(timestamp: Date(), rooms: rooms, modules: [])
        XCTAssertFalse(empty.visibleRooms.contains { $0.id == unspecifiedID })
    }

    private func makeModel(store: HomeConfigurationStore) -> AppModel {
        AppModel(
            dataSource: ControlledDataSource(initial: MockSensorFixtures.previewSnapshot),
            initialSnapshot: MockSensorFixtures.previewSnapshot,
            configurationStore: store
        )
    }
}

@MainActor
private final class ControlledDataSource: SensorDataSource {
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
}
