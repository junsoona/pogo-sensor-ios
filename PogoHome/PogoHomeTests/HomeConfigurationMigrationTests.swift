import SwiftData
import XCTest
@testable import PogoHome

/// The on-disk schema exactly as shipped before room names could follow the app language and
/// before the home name existed — same entity names and attributes, no `nameSourceKind` /
/// `suggestionSymbolName` / `suggestionOrdinal`, no `StoredHomeConfiguration`.
enum LegacyHomeConfigurationSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [StoredRoomConfiguration.self, StoredModuleConfiguration.self] }

    @Model
    final class StoredRoomConfiguration {
        @Attribute(.unique) var id: UUID
        var name: String
        var symbolName: String
        var sortOrder: Int
        var createdAt: Date

        init(id: UUID, name: String, symbolName: String, sortOrder: Int, createdAt: Date = Date()) {
            self.id = id
            self.name = name
            self.symbolName = symbolName
            self.sortOrder = sortOrder
            self.createdAt = createdAt
        }
    }

    @Model
    final class StoredModuleConfiguration {
        @Attribute(.unique) var moduleID: UUID
        var customName: String?
        var roomID: UUID
        var updatedAt: Date

        init(moduleID: UUID, customName: String?, roomID: UUID, updatedAt: Date = Date()) {
            self.moduleID = moduleID
            self.customName = customName
            self.roomID = roomID
            self.updatedAt = updatedAt
        }
    }
}

/// Opening a store written by the previous build: SwiftData must migrate it in place, and the
/// one-time name classification must keep every id, name, icon, order and module placement.
/// Only the untouched seeded default names start following the app language.
@MainActor
final class HomeConfigurationMigrationTests: XCTestCase {
    private let storeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("legacy.store")

    private let studyID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    private let moduleWithNameID = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!
    private let moduleWithoutNameID = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000002")!
    private let legacyCreatedAt = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
    }

    /// Writes what a user of the previous build could have on disk: the Korean seed, one
    /// seeded room renamed, one seeded room re-iconed but not renamed, a custom room the user
    /// dragged to the top, and two module placements.
    private func writeLegacyStore() throws {
        let schema = Schema(versionedSchema: LegacyHomeConfigurationSchemaV1.self)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: storeURL))
        let context = ModelContext(container)
        typealias LegacyRoom = LegacyHomeConfigurationSchemaV1.StoredRoomConfiguration
        typealias LegacyModule = LegacyHomeConfigurationSchemaV1.StoredModuleConfiguration
        context.insert(LegacyRoom(id: studyID, name: "서재", symbolName: "books.vertical.fill", sortOrder: 0, createdAt: legacyCreatedAt))
        // Seeded 거실 whose icon the user changed while keeping the seeded name.
        context.insert(LegacyRoom(id: HomeConfigurationDefaults.livingRoomID, name: "거실", symbolName: "tv.fill", sortOrder: 1, createdAt: legacyCreatedAt))
        // Seeded 침실 the user renamed.
        context.insert(LegacyRoom(id: HomeConfigurationDefaults.bedroomID, name: "우리 침실", symbolName: "bed.double.fill", sortOrder: 2, createdAt: legacyCreatedAt))
        context.insert(LegacyRoom(id: HomeConfigurationDefaults.workspaceID, name: "작업실", symbolName: "desktopcomputer", sortOrder: 3, createdAt: legacyCreatedAt))
        context.insert(LegacyRoom(id: ModuleCatalog.unspecifiedRoomID, name: "미지정 공간", symbolName: "square.dashed", sortOrder: 999, createdAt: legacyCreatedAt))
        context.insert(LegacyModule(moduleID: moduleWithNameID, customName: "창가 센서", roomID: studyID, updatedAt: legacyCreatedAt))
        context.insert(LegacyModule(moduleID: moduleWithoutNameID, customName: nil, roomID: HomeConfigurationDefaults.bedroomID, updatedAt: legacyCreatedAt))
        try context.save()
    }

    func testLegacyStoreMigratesInPlaceAndOnlyUntouchedSeedNamesFollowTheLanguage() throws {
        try writeLegacyStore()

        let english = try SwiftDataHomeConfigurationStore(url: storeURL, language: .english).load()
        XCTAssertEqual(english.rooms.map(\.id), [studyID, HomeConfigurationDefaults.livingRoomID, HomeConfigurationDefaults.bedroomID, HomeConfigurationDefaults.workspaceID, ModuleCatalog.unspecifiedRoomID], "ids and order are preserved")
        XCTAssertEqual(english.rooms.map(\.sortOrder), [0, 1, 2, 3, 999])
        XCTAssertEqual(english.rooms.map(\.symbolName), ["books.vertical.fill", "tv.fill", "bed.double.fill", "desktopcomputer", "square.dashed"], "icons are preserved")
        XCTAssertEqual(english.rooms.map(\.name), ["서재", "Living Room", "우리 침실", "Workspace", "Unassigned"])
        XCTAssertEqual(english.rooms[0].nameSource, .custom("서재"), "a user-created room is never translated")
        XCTAssertEqual(english.rooms[2].nameSource, .custom("우리 침실"), "a renamed seeded room is never translated")
        XCTAssertEqual(english.rooms[1].nameSource, .suggestion(symbolName: "sofa.fill", ordinal: 1), "an untouched seed name follows its original seed, not the new icon")
        XCTAssertEqual(english.modules[moduleWithNameID]?.customName, "창가 센서")
        XCTAssertEqual(english.modules[moduleWithNameID]?.roomID, studyID)
        XCTAssertNil(english.modules[moduleWithoutNameID]?.customName)
        XCTAssertEqual(english.modules[moduleWithoutNameID]?.roomID, HomeConfigurationDefaults.bedroomID)
        XCTAssertNil(english.customHomeName, "a migrated store starts with the default home name")

        // Switching language (a relaunch in another language) re-resolves only the app-provided names.
        let korean = try SwiftDataHomeConfigurationStore(url: storeURL, language: .korean).load()
        XCTAssertEqual(korean.rooms.map(\.name), ["서재", "거실", "우리 침실", "작업실", "미지정 공간"])
        let spanish = try SwiftDataHomeConfigurationStore(url: storeURL, language: .spanish).load()
        XCTAssertEqual(spanish.rooms.map(\.name), ["서재", "Sala de estar", "우리 침실", "Espacio de trabajo", "Sin asignar"])
        XCTAssertEqual(spanish.rooms.map(\.id), english.rooms.map(\.id))
        XCTAssertEqual(spanish.modules, english.modules)
    }

    func testMigrationDoesNotRewriteStoredNamesOrReseed() throws {
        try writeLegacyStore()
        _ = try SwiftDataHomeConfigurationStore(url: storeURL, language: .english)

        let container = try ModelContainer(
            for: Schema(SwiftDataHomeConfigurationStore.modelTypes),
            configurations: ModelConfiguration(url: storeURL)
        )
        let rows = try ModelContext(container).fetch(FetchDescriptor<StoredRoomConfiguration>(sortBy: [SortDescriptor(\.sortOrder)]))
        XCTAssertEqual(rows.count, 5, "no default rooms are re-seeded into an existing store")
        XCTAssertEqual(rows.map(\.name), ["서재", "거실", "우리 침실", "작업실", "미지정 공간"], "the stored name column is left exactly as it was")
        XCTAssertEqual(rows.map(\.createdAt), Array(repeating: legacyCreatedAt, count: 5))
        XCTAssertEqual(rows.map(\.nameSourceKind), ["custom", "suggestion", "custom", "suggestion", "unspecified"])
    }

    /// Classification happens once: a room later renamed to exactly its old seed text is the
    /// user's own name from then on and must not start translating.
    func testClassificationRunsOnlyOnce() throws {
        try writeLegacyStore()
        let store = try SwiftDataHomeConfigurationStore(url: storeURL, language: .korean)
        try store.updateRoom(id: HomeConfigurationDefaults.bedroomID, name: "침실", symbolName: "bed.double.fill")

        let english = try SwiftDataHomeConfigurationStore(url: storeURL, language: .english).load()
        XCTAssertEqual(english.rooms.first { $0.id == HomeConfigurationDefaults.bedroomID }?.name, "침실")
    }

    func testMigratedStoreKeepsWorkingAndPersistsTheHomeName() throws {
        try writeLegacyStore()
        let store = try SwiftDataHomeConfigurationStore(url: storeURL, language: .english)
        let added = try store.createRoom(nameSource: .suggestion(symbolName: "fork.knife", ordinal: 1), symbolName: "fork.knife")
        try store.updateHomeName("Beach House")

        let relaunched = try SwiftDataHomeConfigurationStore(url: storeURL, language: .korean).load()
        XCTAssertEqual(relaunched.customHomeName, "Beach House")
        XCTAssertEqual(relaunched.rooms.first { $0.id == added.id }?.name, "주방")
        XCTAssertEqual(relaunched.rooms.count, 6)
    }
}
