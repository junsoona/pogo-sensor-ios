import SwiftData
import XCTest
@testable import PogoHome

@MainActor
final class HomeConfigurationStoreTests: XCTestCase {
    func testDefaultRoomsAreSeededExactlyOnceAndFallbackIsLast() throws {
        let store = try SwiftDataHomeConfigurationStore(inMemory: true, language: .korean)
        let first = try store.load()
        let second = try store.load()

        XCTAssertEqual(first.rooms, HomeConfigurationDefaults.rooms(in: .korean))
        XCTAssertEqual(second.rooms, first.rooms)
        XCTAssertEqual(first.rooms.last?.id, ModuleCatalog.unspecifiedRoom.id)
    }

    func testCreateUpdateAndDuplicateValidation() throws {
        let store = InMemoryHomeConfigurationStore(language: .korean)
        let room = try store.createRoom(name: "  서재  ", symbolName: "books.vertical.fill")
        XCTAssertEqual(room.name, "서재")

        try store.updateRoom(id: room.id, name: "작은 서재", symbolName: "book.fill")
        let updated = try XCTUnwrap(try store.load().rooms.first { $0.id == room.id })
        XCTAssertEqual(updated.name, "작은 서재")
        XCTAssertEqual(updated.symbolName, "book.fill")

        XCTAssertThrowsError(try store.createRoom(name: "거실", symbolName: "sofa.fill")) { error in
            XCTAssertEqual(error as? HomeConfigurationError, .duplicateRoomName)
        }
    }

    func testDeletingRoomMovesAssignedModulesToFallback() throws {
        let moduleID = UUID()
        let store = InMemoryHomeConfigurationStore(language: .korean)
        let room = try store.createRoom(name: "테스트 공간", symbolName: "square.fill")
        try store.updateModule(id: moduleID, customName: "창가 센서", roomID: room.id)

        try store.deleteRoom(id: room.id)

        let configuration = try store.load()
        XCTAssertFalse(configuration.rooms.contains { $0.id == room.id })
        XCTAssertEqual(configuration.modules[moduleID]?.roomID, ModuleCatalog.unspecifiedRoom.id)
        XCTAssertEqual(configuration.modules[moduleID]?.customName, "창가 센서")
    }

    func testFallbackRoomCannotBeRenamedOrDeleted() throws {
        let store = InMemoryHomeConfigurationStore(language: .korean)
        XCTAssertThrowsError(
            try store.updateRoom(
                id: ModuleCatalog.unspecifiedRoom.id,
                name: "다른 이름",
                symbolName: "house"
            )
        ) { error in
            XCTAssertEqual(error as? HomeConfigurationError, .cannotModifyUnspecifiedRoom)
        }
        XCTAssertThrowsError(try store.deleteRoom(id: ModuleCatalog.unspecifiedRoom.id)) { error in
            XCTAssertEqual(error as? HomeConfigurationError, .cannotModifyUnspecifiedRoom)
        }
    }

    func testSwiftDataConfigurationSurvivesStoreRecreation() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Schema(SwiftDataHomeConfigurationStore.modelTypes),
            configurations: configuration
        )
        let moduleID = UUID()

        let firstStore = try SwiftDataHomeConfigurationStore(container: container, language: .korean)
        let room = try firstStore.createRoom(name: "테라스", symbolName: "tree.fill")
        try firstStore.updateModule(id: moduleID, customName: "바깥 공기", roomID: room.id)

        let relaunchedStore = try SwiftDataHomeConfigurationStore(container: container, language: .korean)
        let restored = try relaunchedStore.load()
        XCTAssertEqual(restored.rooms.first(where: { $0.id == room.id })?.name, "테라스")
        XCTAssertEqual(restored.modules[moduleID]?.customName, "바깥 공기")
        XCTAssertEqual(restored.modules[moduleID]?.roomID, room.id)
    }

    /// `reorderRooms` is documented to take *every* non-fallback room's id (the caller,
    /// `RoomManagementView`, always passes its full on-screen list) — these tests start from
    /// a store holding only the fallback room, so there is no pre-existing default room to
    /// collide with the freshly-assigned 0-based sort orders below.
    func testReorderRoomsPersistsNewSortOrderAndKeepsFallbackLast() throws {
        let store = InMemoryHomeConfigurationStore(rooms: [ModuleCatalog.unspecifiedRoom(in: .korean)], language: .korean)
        let a = try store.createRoom(name: "A", symbolName: "a.circle")
        let b = try store.createRoom(name: "B", symbolName: "b.circle")
        let c = try store.createRoom(name: "C", symbolName: "c.circle")

        try store.reorderRooms(orderedIDs: [c.id, a.id, b.id])

        let ordered = try store.load().rooms
        XCTAssertEqual(ordered.map(\.name), ["C", "A", "B", "미지정 공간"])
        XCTAssertEqual(ordered.last?.id, ModuleCatalog.unspecifiedRoom.id)
    }

    func testReorderRoomsIgnoresTheFallbackRoomIDIfPassed() throws {
        let store = InMemoryHomeConfigurationStore(rooms: [ModuleCatalog.unspecifiedRoom(in: .korean)], language: .korean)
        let a = try store.createRoom(name: "A", symbolName: "a.circle")
        let b = try store.createRoom(name: "B", symbolName: "b.circle")

        try store.reorderRooms(orderedIDs: [ModuleCatalog.unspecifiedRoom.id, b.id, a.id])

        let ordered = try store.load().rooms
        XCTAssertEqual(ordered.map(\.name), ["B", "A", "미지정 공간"])
    }

    func testRoomOrderSurvivesSimulatedAppRelaunch() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Schema(SwiftDataHomeConfigurationStore.modelTypes),
            configurations: configuration
        )
        // The store seeds `HomeConfigurationDefaults.rooms` (거실/침실/작업실 + fallback) on
        // first use, exactly like a real first launch — `reorderRooms` must be given every
        // one of them, matching how `RoomManagementView` always passes its complete list.
        let firstStore = try SwiftDataHomeConfigurationStore(container: container, language: .korean)
        let seeded = try firstStore.load().rooms.filter { $0.id != ModuleCatalog.unspecifiedRoom.id }
        let a = try firstStore.createRoom(name: "A", symbolName: "a.circle")
        let b = try firstStore.createRoom(name: "B", symbolName: "b.circle")
        try firstStore.reorderRooms(orderedIDs: [b.id, a.id] + seeded.map(\.id))

        let relaunchedStore = try SwiftDataHomeConfigurationStore(container: container, language: .korean)
        let restored = try relaunchedStore.load().rooms

        XCTAssertEqual(restored.map(\.name), ["B", "A", "거실", "침실", "작업실", "미지정 공간"])
    }

    func testNamesRejectEmptyAndOverlongInput() throws {
        let store = InMemoryHomeConfigurationStore(language: .korean)
        XCTAssertThrowsError(try store.createRoom(name: "   ", symbolName: "house")) { error in
            XCTAssertEqual(error as? HomeConfigurationError, .emptyName)
        }
        let overlong = String(repeating: "가", count: HomeConfigurationValidation.maximumNameLength + 1)
        XCTAssertThrowsError(try store.createRoom(name: overlong, symbolName: "house")) { error in
            XCTAssertEqual(
                error as? HomeConfigurationError,
                .nameTooLong(maximum: HomeConfigurationValidation.maximumNameLength)
            )
        }
    }
}
