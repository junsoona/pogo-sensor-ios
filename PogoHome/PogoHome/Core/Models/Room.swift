import Foundation

/// Where a room's name comes from — which decides whether it follows the app language.
///
/// Only names the app itself provided are re-resolved per language; anything the user typed
/// is kept verbatim in every language. See `SwiftDataHomeConfigurationStore` for how rooms
/// saved before this distinction existed are classified.
nonisolated enum RoomNameSource: Hashable, Sendable {
    /// Typed by the user. Shown exactly as saved, never translated.
    case custom(String)
    /// The app's suggestion for `symbolName` (see `RoomIconCatalog`), accepted as-is — the
    /// seeded default rooms, or a room saved with an empty name field. `ordinal` > 1 appends
    /// a number (`거실 2`, `Living Room 2`) to keep names unique.
    case suggestion(symbolName: String, ordinal: Int)
    /// The fixed fallback room (`ModuleCatalog.unspecifiedRoom`).
    case unspecified

    func displayName(in language: AppLanguage) -> String {
        switch self {
        case let .custom(name):
            return name
        case let .suggestion(symbolName, ordinal):
            let base = RoomIconCatalog.suggestedRoomName(for: symbolName, in: language)
            guard ordinal > 1 else { return base }
            // Catalog key "room.name.numbered" (Korean "%1$@ %2$lld", e.g. "거실 2").
            return language.format("room.name.numbered", base, ordinal)
        case .unspecified:
            return language.string(ModuleCatalog.unspecifiedRoomName)
        }
    }

    /// Whether this name follows the app language.
    var isAppProvided: Bool {
        if case .custom = self { return false }
        return true
    }
}

nonisolated struct Room: Identifiable, Hashable, Sendable {
    let id: UUID
    /// Display name, already resolved for the language this room was loaded in.
    let name: String
    let nameSource: RoomNameSource
    let symbolName: String
    let sortOrder: Int

    /// A room with a user-typed (verbatim) name.
    init(id: UUID, name: String, symbolName: String, sortOrder: Int) {
        self.init(id: id, nameSource: .custom(name), symbolName: symbolName, sortOrder: sortOrder)
    }

    init(
        id: UUID,
        nameSource: RoomNameSource,
        symbolName: String,
        sortOrder: Int,
        language: AppLanguage = .current
    ) {
        self.id = id
        self.name = nameSource.displayName(in: language)
        self.nameSource = nameSource
        self.symbolName = symbolName
        self.sortOrder = sortOrder
    }

    func with(sortOrder: Int, language: AppLanguage) -> Room {
        Room(id: id, nameSource: nameSource, symbolName: symbolName, sortOrder: sortOrder, language: language)
    }

    /// The same room with its name re-resolved in `language`.
    func resolved(in language: AppLanguage) -> Room {
        with(sortOrder: sortOrder, language: language)
    }
}
