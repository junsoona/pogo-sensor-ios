import Foundation

/// Turns an icon's base suggestion (`RoomIconCatalog.suggestedRoomName(for:in:)`) into a room
/// name that is actually free to save — `거실`, then `거실 2`, `거실 3`, … — and resolves
/// what the room editor's name field means on Save. The same value is both the gray
/// placeholder the editor shows and the name it saves when the field is left empty, so what
/// the user sees is always exactly what gets stored.
nonisolated enum RoomNameSuggestion {
    /// Every room in `existingRooms` counts — including the fallback "미지정 공간" even while
    /// it's hidden from room lists — because the store's duplicate check does too.
    /// `excludingRoomID` is the room being edited, which never collides with itself.
    /// `existingRooms` must be resolved in `language`, as the store returns them.
    static func availableSource(
        for symbolName: String,
        existingRooms: [Room],
        excludingRoomID: UUID? = nil,
        language: AppLanguage = .current
    ) -> RoomNameSource {
        let takenNames = existingRooms
            .filter { $0.id != excludingRoomID }
            .map(\.name)
        func isTaken(_ source: RoomNameSource) -> Bool {
            let candidate = source.displayName(in: language)
            return takenNames.contains { HomeConfigurationValidation.isSameRoomName($0, candidate) }
        }
        var ordinal = 1
        while isTaken(.suggestion(symbolName: symbolName, ordinal: ordinal)) {
            ordinal += 1
        }
        return .suggestion(symbolName: symbolName, ordinal: ordinal)
    }

    static func availableName(
        for symbolName: String,
        existingRooms: [Room],
        excludingRoomID: UUID? = nil,
        language: AppLanguage = .current
    ) -> String {
        availableSource(
            for: symbolName,
            existingRooms: existingRooms,
            excludingRoomID: excludingRoomID,
            language: language
        ).displayName(in: language)
    }

    /// The name to save for the editor's current `input`: the user's own text when there is
    /// any, otherwise `suggestion` (the placeholder being shown). Whitespace-only input counts
    /// as empty, matching how the sensor name field already treats it.
    static func resolvedName(input: String, suggestion: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? suggestion : trimmed
    }

    /// Like `resolvedName`, but keeps track of *who* chose the name so an app-provided one
    /// keeps following the app language:
    /// - empty input → `suggestion` (app-provided);
    /// - input identical to the room's current name, as it was pre-filled in the editor →
    ///   the room's existing source, so opening and saving a default-named room never pins
    ///   it to one language;
    /// - anything else the user typed → `.custom`, verbatim in every language.
    static func resolvedSource(input: String, suggestion: RoomNameSource, editing room: Room?) -> RoomNameSource {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return suggestion }
        if let room, trimmed == room.name { return room.nameSource }
        return .custom(trimmed)
    }
}

nonisolated enum ModuleNameInput {
    /// The custom name to persist for the sensor editor's current `input`. `nil` — i.e. "show
    /// the product name" — when the field is empty/whitespace, or when it merely repeats the
    /// product name, so the module keeps following `hardwareName` instead of pinning a copy.
    static func customName(input: String, hardwareName: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == hardwareName ? nil : trimmed
    }
}

nonisolated enum HomeNameInput {
    /// Same rule as `ModuleNameInput`: `nil` (follow the localized default) when the field is
    /// empty or just repeats the default being shown; otherwise the trimmed, verbatim name.
    static func customName(input: String, defaultName: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == defaultName ? nil : trimmed
    }
}
