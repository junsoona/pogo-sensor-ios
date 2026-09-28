import SwiftData
import XCTest
@testable import PogoHome

/// The language-switch policy for names:
/// - app-provided names (seeded rooms, accepted icon suggestions, the fallback room, product
///   names, the default home name) are re-resolved in the current language;
/// - anything the user typed is stored and shown verbatim in every language;
/// - ids, order, icons and module placement never depend on language.
/// A language switch is modelled as reopening the same container with another `AppLanguage`,
/// which is what an iOS app-language change (it relaunches the app) amounts to.
@MainActor
final class LocalizedNamePolicyTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(SwiftDataHomeConfigurationStore.modelTypes),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    func testSeededDefaultRoomsFollowTheLanguage() throws {
        let container = try makeContainer()
        let korean = try SwiftDataHomeConfigurationStore(container: container, language: .korean).load()
        XCTAssertEqual(korean.rooms.map(\.name), ["거실", "침실", "작업실", "미지정 공간"])

        let english = try SwiftDataHomeConfigurationStore(container: container, language: .english).load()
        XCTAssertEqual(english.rooms.map(\.name), ["Living Room", "Bedroom", "Workspace", "Unassigned"])

        let spanish = try SwiftDataHomeConfigurationStore(container: container, language: .spanish).load()
        XCTAssertEqual(spanish.rooms.map(\.name), ["Sala de estar", "Dormitorio", "Espacio de trabajo", "Sin asignar"])
        XCTAssertEqual(spanish.rooms.map(\.id), korean.rooms.map(\.id))
    }

    func testUserTypedNamesStayVerbatimAcrossLanguages() throws {
        let container = try makeContainer()
        let moduleID = UUID()
        let korean = try SwiftDataHomeConfigurationStore(container: container, language: .korean)
        let study = try korean.createRoom(name: "서재", symbolName: "books.vertical.fill")
        let kitchen = try korean.createRoom(name: "Kitchen", symbolName: "fork.knife")
        try korean.updateModule(id: moduleID, customName: "창가 센서", roomID: study.id)
        try korean.updateRoom(id: HomeConfigurationDefaults.bedroomID, name: "안방 침실", symbolName: "bed.double.fill")

        for language in AppLanguage.supported {
            let loaded = try SwiftDataHomeConfigurationStore(container: container, language: language).load()
            XCTAssertEqual(loaded.rooms.first { $0.id == study.id }?.name, "서재", language.identifier)
            XCTAssertEqual(loaded.rooms.first { $0.id == kitchen.id }?.name, "Kitchen", language.identifier)
            XCTAssertEqual(loaded.rooms.first { $0.id == HomeConfigurationDefaults.bedroomID }?.name, "안방 침실", language.identifier)
            XCTAssertEqual(loaded.modules[moduleID]?.customName, "창가 센서", language.identifier)
            XCTAssertEqual(loaded.modules[moduleID]?.roomID, study.id, language.identifier)
        }
    }

    func testAcceptedSuggestionFollowsTheLanguageIncludingItsNumber() throws {
        let container = try makeContainer()
        let korean = try SwiftDataHomeConfigurationStore(container: container, language: .korean)
        let existing = try korean.load().rooms
        let source = RoomNameSuggestion.availableSource(for: "sofa.fill", existingRooms: existing, language: .korean)
        XCTAssertEqual(source, .suggestion(symbolName: "sofa.fill", ordinal: 2), "거실 is taken by the seeded room")
        let second = try korean.createRoom(nameSource: source, symbolName: "sofa.fill")
        XCTAssertEqual(second.name, "거실 2")

        let english = try SwiftDataHomeConfigurationStore(container: container, language: .english).load()
        XCTAssertEqual(english.rooms.first { $0.id == second.id }?.name, "Living Room 2")
        let spanish = try SwiftDataHomeConfigurationStore(container: container, language: .spanish).load()
        XCTAssertEqual(spanish.rooms.first { $0.id == second.id }?.name, "Sala de estar 2")
    }

    func testSuggestionNumberingIsComputedInTheCurrentLanguage() {
        let rooms = [
            Room(id: UUID(), name: "Living Room", symbolName: "sofa.fill", sortOrder: 0),
            Room(id: UUID(), name: "living room 2", symbolName: "sofa.fill", sortOrder: 1),
        ]
        XCTAssertEqual(RoomNameSuggestion.availableName(for: "sofa.fill", existingRooms: rooms, language: .english), "Living Room 3")
        XCTAssertEqual(RoomNameSuggestion.availableName(for: "sofa.fill", existingRooms: rooms, language: .korean), "거실")
    }

    // MARK: - What the room editor saves

    func testEditorSourceResolution() {
        let defaultRoom = HomeConfigurationDefaults.rooms(in: .english)[0]
        let suggestion = RoomNameSource.suggestion(symbolName: "tv.fill", ordinal: 1)

        XCTAssertEqual(RoomNameSuggestion.resolvedSource(input: "  ", suggestion: suggestion, editing: defaultRoom), suggestion, "empty → the shown suggestion")
        XCTAssertEqual(
            RoomNameSuggestion.resolvedSource(input: " Living Room ", suggestion: suggestion, editing: defaultRoom),
            defaultRoom.nameSource,
            "the untouched pre-filled name keeps following the language"
        )
        XCTAssertEqual(RoomNameSuggestion.resolvedSource(input: "Den", suggestion: suggestion, editing: defaultRoom), .custom("Den"))
        XCTAssertEqual(RoomNameSuggestion.resolvedSource(input: "Living Room", suggestion: suggestion, editing: nil), .custom("Living Room"), "typing a name when creating is always the user's own name")
    }

    func testSavingADefaultRoomUnchangedKeepsItTranslatable() async throws {
        let container = try makeContainer()
        let english = try SwiftDataHomeConfigurationStore(container: container, language: .english)
        let model = AppModel(dataSource: MockSensorDataSource(), configurationStore: english, language: .english)
        let living = try XCTUnwrap(model.editableRooms.first { $0.id == HomeConfigurationDefaults.livingRoomID })
        let source = RoomNameSuggestion.resolvedSource(
            input: living.name,
            suggestion: model.suggestedRoomNameSource(for: "tv.fill", excludingRoomID: living.id),
            editing: living
        )
        try await model.updateRoom(id: living.id, nameSource: source, symbolName: "tv.fill")

        let korean = try SwiftDataHomeConfigurationStore(container: container, language: .korean).load()
        let reloaded = try XCTUnwrap(korean.rooms.first { $0.id == living.id })
        XCTAssertEqual(reloaded.name, "거실")
        XCTAssertEqual(reloaded.symbolName, "tv.fill")
    }

    func testDuplicateCheckUsesTheDisplayedNames() throws {
        let english = InMemoryHomeConfigurationStore(language: .english)
        XCTAssertThrowsError(try english.createRoom(name: "living room", symbolName: "tv.fill")) { error in
            XCTAssertEqual(error as? HomeConfigurationError, .duplicateRoomName)
        }
        XCTAssertThrowsError(try english.createRoom(nameSource: .suggestion(symbolName: "sofa.fill", ordinal: 1), symbolName: "sofa.fill")) { error in
            XCTAssertEqual(error as? HomeConfigurationError, .duplicateRoomName)
        }
    }

    // MARK: - Overlay onto live data

    func testProductNamesFollowTheLanguageButCustomModuleNamesDoNot() async throws {
        let raw = "744dbdfffe65d357"
        let moduleID = ModuleIdentity.stableUUID(forRawIdentifier: raw)
        let store = InMemoryHomeConfigurationStore(language: .english)
        let englishDescriptor = ModuleCatalog.descriptor(forRawIdentifier: raw, apiRole: nil, language: .english)
        let module = SensorModule(
            id: moduleID,
            name: englishDescriptor.displayName,
            hardwareName: englishDescriptor.displayName,
            hardwareIdentifier: raw,
            roomID: ModuleCatalog.unspecifiedRoomID,
            readings: [],
            isOnline: true,
            lastSeen: Date()
        )
        let model = AppModel(
            dataSource: MockSensorDataSource(),
            initialSnapshot: HomeSnapshot(timestamp: Date(), rooms: [], modules: [module]),
            configurationStore: store,
            language: .english
        )
        XCTAssertEqual(model.module(with: moduleID)?.name, "SGP41 Gas Sensor")

        try await model.updateModule(id: moduleID, customName: "창가 센서", roomID: HomeConfigurationDefaults.livingRoomID)
        XCTAssertEqual(model.module(with: moduleID)?.name, "창가 센서")
        XCTAssertEqual(model.room(with: HomeConfigurationDefaults.livingRoomID)?.name, "Living Room")
    }
}
