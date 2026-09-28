import XCTest
@testable import PogoHome

/// Room-name suggestions (gray placeholder = the name saved when the field is left empty),
/// duplicate-free numbering, preservation of typed/existing names, and the sensor name
/// falling back to its product name. The SwiftUI editors only bind these values, so this is
/// where the behavior is locked down.
@MainActor
final class NameSuggestionTests: XCTestCase {
    // MARK: - Icon → suggested name

    func testEverySelectableIconHasItsOwnSuggestionInEveryLanguage() {
        for language in AppLanguage.supported {
            let fallback = language.string(RoomIconCatalog.fallbackSuggestedRoomName)
            for symbol in RoomIconCatalog.allSymbolNames {
                let suggestion = RoomIconCatalog.suggestedRoomName(for: symbol, in: language)
                XCTAssertFalse(suggestion.trimmingCharacters(in: .whitespaces).isEmpty, "\(language.identifier) \(symbol)")
                XCTAssertNotEqual(suggestion, fallback, "\(language.identifier): \(symbol) has no dedicated suggestion")
                XCTAssertLessThanOrEqual(suggestion.count + 3, HomeConfigurationValidation.maximumNameLength, "\(language.identifier) \(symbol)")
            }
        }
        XCTAssertEqual(RoomIconCatalog.suggestedRoomName(for: "sofa.fill", in: .korean), "거실")
        XCTAssertEqual(RoomIconCatalog.suggestedRoomName(for: "fork.knife", in: .korean), "주방")
        XCTAssertEqual(RoomIconCatalog.suggestedRoomName(for: "sofa.fill", in: .english), "Living Room")
        XCTAssertEqual(RoomIconCatalog.suggestedRoomName(for: "fork.knife", in: .spanish), "Cocina")
    }

    /// Two icons suggesting the same name in some language would make an app-provided room
    /// name ambiguous after a language switch.
    func testSuggestionsAreUniqueWithinEachLanguage() {
        for language in AppLanguage.supported {
            var names = RoomIconCatalog.allSymbolNames.map { RoomIconCatalog.suggestedRoomName(for: $0, in: language) }
            names.append(language.string(ModuleCatalog.unspecifiedRoomName))
            names.append(language.string(RoomIconCatalog.fallbackSuggestedRoomName))
            for (index, name) in names.enumerated() {
                let clashes = names.enumerated().filter { $0.offset != index && HomeConfigurationValidation.isSameRoomName($0.element, name) }
                XCTAssertTrue(clashes.isEmpty, "\(language.identifier): '\(name)' is suggested more than once")
            }
        }
    }

    func testUncatalogedIconFallsBackToGenericSuggestion() {
        XCTAssertEqual(
            RoomIconCatalog.suggestedRoomName(for: "not.a.catalog.icon", in: .korean),
            AppLanguage.korean.string(RoomIconCatalog.fallbackSuggestedRoomName)
        )
        XCTAssertEqual(RoomIconCatalog.suggestedRoomName(for: "not.a.catalog.icon", in: .korean), "새로운 방")
    }

    func testSuggestionFollowsTheSelectedIcon() {
        let model = makeModel()
        XCTAssertEqual(model.suggestedRoomName(for: "fork.knife"), "주방")
        XCTAssertEqual(model.suggestedRoomName(for: "tree.fill"), "정원")
        XCTAssertEqual(model.suggestedRoomName(for: "washer.fill"), "세탁실")
    }

    // MARK: - Duplicates

    func testSuggestionSkipsNamesAlreadyInUse() async throws {
        let model = makeModel()
        // The default home already has 거실 (sofa.fill) and 침실 (bed.double.fill).
        XCTAssertEqual(model.suggestedRoomName(for: "sofa.fill"), "거실 2")
        XCTAssertEqual(model.suggestedRoomName(for: "bed.double.fill"), "침실 2")

        let second = try await model.createRoom(
            name: RoomNameSuggestion.resolvedName(input: "", suggestion: model.suggestedRoomName(for: "sofa.fill")),
            symbolName: "sofa.fill"
        )
        XCTAssertEqual(second.name, "거실 2")
        XCTAssertEqual(model.suggestedRoomName(for: "sofa.fill"), "거실 3")
    }

    func testSuggestionFillsTheFirstFreeNumberAndMatchesCaseInsensitively() {
        let rooms = [
            Room(id: UUID(), name: "거실", symbolName: "sofa.fill", sortOrder: 0),
            Room(id: UUID(), name: "거실 3", symbolName: "sofa.fill", sortOrder: 1),
            Room(id: UUID(), name: "Popcorn", symbolName: "popcorn.fill", sortOrder: 2),
        ]
        XCTAssertEqual(RoomNameSuggestion.availableName(for: "sofa.fill", existingRooms: rooms, language: .korean), "거실 2")
        XCTAssertTrue(HomeConfigurationValidation.isSameRoomName("popcorn", "Popcorn"))
    }

    // MARK: - Empty save uses exactly the displayed suggestion

    func testSavingEmptyFieldStoresTheDisplayedSuggestionWithoutDuplicateError() async throws {
        let model = makeModel()
        for _ in 0..<3 {
            let displayed = model.suggestedRoomName(for: "sofa.fill")
            let room = try await model.createRoom(
                name: RoomNameSuggestion.resolvedName(input: "", suggestion: displayed),
                symbolName: "sofa.fill"
            )
            XCTAssertEqual(room.name, displayed, "the saved name must equal the placeholder that was shown")
        }
        XCTAssertEqual(
            model.editableRooms.filter { $0.symbolName == "sofa.fill" }.map(\.name).sorted(),
            ["거실", "거실 2", "거실 3", "거실 4"]
        )
    }

    func testWhitespaceOnlyInputCountsAsEmpty() {
        XCTAssertEqual(RoomNameSuggestion.resolvedName(input: "   ", suggestion: "주방"), "주방")
    }

    // MARK: - Typed and existing names are preserved

    func testTypedNameSurvivesIconChangesAndIsSaved() async throws {
        let model = makeModel()
        let typed = "  아이 놀이방 "
        // The view recomputes only the suggestion when the icon changes; the typed text wins.
        for symbol in ["sofa.fill", "teddybear.fill", "gamecontroller.fill"] {
            XCTAssertEqual(
                RoomNameSuggestion.resolvedName(input: typed, suggestion: model.suggestedRoomName(for: symbol)),
                "아이 놀이방"
            )
        }
        let room = try await model.createRoom(
            name: RoomNameSuggestion.resolvedName(input: typed, suggestion: model.suggestedRoomName(for: "gamecontroller.fill")),
            symbolName: "gamecontroller.fill"
        )
        XCTAssertEqual(room.name, "아이 놀이방")
    }

    func testEditingExistingRoomKeepsItsStoredName() async throws {
        let model = makeModel()
        let living = try XCTUnwrap(model.editableRooms.first { $0.id == HomeConfigurationDefaults.livingRoom.id })

        // Unchanged field (pre-filled with the stored name) saves the stored name even after
        // the icon changes.
        try await model.updateRoom(
            id: living.id,
            name: RoomNameSuggestion.resolvedName(input: living.name, suggestion: model.suggestedRoomName(for: "tv.fill", excludingRoomID: living.id)),
            symbolName: "tv.fill"
        )
        XCTAssertEqual(model.room(with: living.id)?.name, "거실")
        XCTAssertEqual(model.room(with: living.id)?.symbolName, "tv.fill")
    }

    func testClearingAnExistingRoomNameSavesTheCurrentIconSuggestionIgnoringItself() async throws {
        let model = makeModel()
        let livingID = HomeConfigurationDefaults.livingRoom.id

        // The room being edited never collides with itself: 거실 + sofa → "거실", not "거실 2".
        XCTAssertEqual(model.suggestedRoomName(for: "sofa.fill", excludingRoomID: livingID), "거실")

        let displayed = model.suggestedRoomName(for: "popcorn.fill", excludingRoomID: livingID)
        XCTAssertEqual(displayed, "홈시어터")
        try await model.updateRoom(
            id: livingID,
            name: RoomNameSuggestion.resolvedName(input: "", suggestion: displayed),
            symbolName: "popcorn.fill"
        )
        XCTAssertEqual(model.room(with: livingID)?.name, "홈시어터")
    }

    // MARK: - Sensor names

    func testModuleNameInputMapsEmptyAndProductNameToNil() {
        let hardware = "PMS5003 미세먼지 센서"
        XCTAssertNil(ModuleNameInput.customName(input: "", hardwareName: hardware))
        XCTAssertNil(ModuleNameInput.customName(input: "  \n", hardwareName: hardware))
        XCTAssertNil(ModuleNameInput.customName(input: hardware, hardwareName: hardware))
        XCTAssertEqual(ModuleNameInput.customName(input: " 창가 센서 ", hardwareName: hardware), "창가 센서")
    }

    func testClearingSensorNameRestoresProductNameAndTouchesNothingElse() async throws {
        let model = makeModel()
        let moduleID = MockSensorFixtures.livingRoomAirQualityModuleID
        let before = try XCTUnwrap(model.module(with: moduleID))
        XCTAssertNil(model.customName(forModule: moduleID), "no custom name → the editor starts empty with the product name in gray")

        try await model.updateModule(
            id: moduleID,
            customName: ModuleNameInput.customName(input: "창가 센서", hardwareName: before.hardwareName),
            roomID: before.roomID
        )
        XCTAssertEqual(model.module(with: moduleID)?.name, "창가 센서")
        XCTAssertEqual(model.customName(forModule: moduleID), "창가 센서", "the editor pre-fills the stored custom name verbatim")

        // Clear button → empty field → save.
        try await model.updateModule(
            id: moduleID,
            customName: ModuleNameInput.customName(input: "", hardwareName: before.hardwareName),
            roomID: before.roomID
        )
        let after = try XCTUnwrap(model.module(with: moduleID))
        XCTAssertNil(model.customName(forModule: moduleID))
        XCTAssertEqual(after.name, before.hardwareName)
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.roomID, before.roomID)
        XCTAssertEqual(after.readings, before.readings)
        XCTAssertEqual(after.isOnline, before.isOnline)
        XCTAssertEqual(after.lastSeen, before.lastSeen)
    }

    private func makeModel(language: AppLanguage = .korean) -> AppModel {
        AppModel(
            dataSource: MockSensorDataSource(),
            initialSnapshot: MockSensorFixtures.previewSnapshot,
            configurationStore: InMemoryHomeConfigurationStore(language: language),
            language: language
        )
    }
}
