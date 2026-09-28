import Foundation
import SwiftData

@Model
final class StoredRoomConfiguration {
    @Attribute(.unique) var id: UUID
    /// The name as displayed when it was last saved. Authoritative for custom names; for
    /// app-provided names it is only a readable copy (and what a build predating
    /// `nameSourceKind` would show), since those are re-resolved per language on load.
    var name: String
    var symbolName: String
    var sortOrder: Int
    var createdAt: Date
    // The three fields below were added after rooms were first persisted. They are optional so
    // SwiftData migrates an existing store in place (lightweight), leaving them `nil` on every
    // old row until `classifyLegacyRoomNames()` fills them in once.
    /// `StoredRoomNameKind` raw value, or `nil` for a row saved before it existed.
    var nameSourceKind: String? = nil
    /// `RoomNameSource.suggestion`'s icon — may differ from `symbolName` if the user later
    /// changed the icon but kept the name.
    var suggestionSymbolName: String? = nil
    var suggestionOrdinal: Int? = nil

    init(id: UUID, nameSource: RoomNameSource, displayName: String, symbolName: String, sortOrder: Int, createdAt: Date = Date()) {
        self.id = id
        self.name = displayName
        self.symbolName = symbolName
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        setNameSource(nameSource, displayName: displayName)
    }

    func setNameSource(_ source: RoomNameSource, displayName: String) {
        name = displayName
        switch source {
        case .custom:
            nameSourceKind = StoredRoomNameKind.custom.rawValue
            suggestionSymbolName = nil
            suggestionOrdinal = nil
        case let .suggestion(symbolName, ordinal):
            nameSourceKind = StoredRoomNameKind.suggestion.rawValue
            suggestionSymbolName = symbolName
            suggestionOrdinal = ordinal
        case .unspecified:
            nameSourceKind = StoredRoomNameKind.unspecified.rawValue
            suggestionSymbolName = nil
            suggestionOrdinal = nil
        }
    }

    /// An unclassified (legacy) or unreadable row is treated as a verbatim custom name, so a
    /// stored name is never replaced by a translation by accident.
    var nameSource: RoomNameSource {
        switch nameSourceKind.flatMap(StoredRoomNameKind.init(rawValue:)) {
        case .suggestion:
            guard let suggestionSymbolName else { return .custom(name) }
            return .suggestion(symbolName: suggestionSymbolName, ordinal: suggestionOrdinal ?? 1)
        case .unspecified:
            return .unspecified
        case .custom, nil:
            return .custom(name)
        }
    }
}

nonisolated enum StoredRoomNameKind: String {
    case custom
    case suggestion
    case unspecified
}

/// Home-level display settings — at most one row. A separate entity (rather than a field
/// on rooms) so adding it is a purely additive migration of existing stores.
@Model
final class StoredHomeConfiguration {
    /// `nil` means "show the localized default name".
    var customName: String?
    var updatedAt: Date

    init(customName: String?, updatedAt: Date = Date()) {
        self.customName = customName
        self.updatedAt = updatedAt
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

@MainActor
final class SwiftDataHomeConfigurationStore: HomeConfigurationStore {
    /// Every persisted entity. Adding one here is an additive (lightweight) migration of an
    /// existing on-device store; see `HomeConfigurationMigrationTests`.
    static let modelTypes: [any PersistentModel.Type] = [
        StoredRoomConfiguration.self,
        StoredModuleConfiguration.self,
        StoredHomeConfiguration.self,
    ]

    private let container: ModelContainer
    private let context: ModelContext
    private let language: AppLanguage

    convenience init(inMemory: Bool = false, language: AppLanguage = .current) throws {
        try self.init(configuration: ModelConfiguration(isStoredInMemoryOnly: inMemory), language: language)
    }

    /// A store file at `url` — used by tests to open (and migrate) a specific on-disk store.
    convenience init(url: URL, language: AppLanguage = .current) throws {
        try self.init(configuration: ModelConfiguration(url: url), language: language)
    }

    private convenience init(configuration: ModelConfiguration, language: AppLanguage) throws {
        do {
            let container = try ModelContainer(
                for: Schema(Self.modelTypes),
                configurations: configuration
            )
            try self.init(container: container, language: language)
        } catch let error as HomeConfigurationError {
            throw error
        } catch {
            throw HomeConfigurationError.persistence(String(describing: error))
        }
    }

    /// Internal seam used by tests to construct a second store over the same container,
    /// matching an app relaunch without writing test data into the user's real database.
    init(container: ModelContainer, language: AppLanguage = .current) throws {
        self.container = container
        self.context = ModelContext(container)
        self.language = language
        do {
            try seedDefaultsIfNeeded()
            try classifyLegacyRoomNames()
        } catch {
            throw HomeConfigurationError.persistence(String(describing: error))
        }
    }

    func load() throws -> HomeConfigurationSnapshot {
        do {
            let storedRooms = try context.fetch(FetchDescriptor<StoredRoomConfiguration>())
            let storedModules = try context.fetch(FetchDescriptor<StoredModuleConfiguration>())
            let rooms = storedRooms
                .map { Room(id: $0.id, nameSource: $0.nameSource, symbolName: $0.symbolName, sortOrder: $0.sortOrder, language: language) }
                .sorted { $0.sortOrder < $1.sortOrder }
            let modules = Dictionary(uniqueKeysWithValues: storedModules.map {
                ($0.moduleID, ModuleConfiguration(moduleID: $0.moduleID, customName: $0.customName, roomID: $0.roomID, updatedAt: $0.updatedAt))
            })
            return HomeConfigurationSnapshot(
                rooms: rooms,
                modules: modules,
                customHomeName: try storedHome()?.customName
            )
        } catch let error as HomeConfigurationError {
            throw error
        } catch {
            throw HomeConfigurationError.persistence(String(describing: error))
        }
    }

    @discardableResult
    func createRoom(nameSource: RoomNameSource, symbolName: String) throws -> Room {
        let current = try load()
        let source = try RoomNameValidation.validated(nameSource, rooms: current.rooms, excluding: nil, language: language)
        let nextOrder = (current.rooms.map(\.sortOrder).filter { $0 < ModuleCatalog.unspecifiedRoomSortOrder }.max() ?? -1) + 1
        let room = Room(id: UUID(), nameSource: source, symbolName: symbolName, sortOrder: nextOrder, language: language)
        context.insert(StoredRoomConfiguration(id: room.id, nameSource: source, displayName: room.name, symbolName: room.symbolName, sortOrder: room.sortOrder))
        try save()
        return room
    }

    func updateRoom(id: UUID, nameSource: RoomNameSource, symbolName: String) throws {
        guard id != ModuleCatalog.unspecifiedRoomID else { throw HomeConfigurationError.cannotModifyUnspecifiedRoom }
        let current = try load()
        let source = try RoomNameValidation.validated(nameSource, rooms: current.rooms, excluding: id, language: language)
        guard let stored = try context.fetch(FetchDescriptor<StoredRoomConfiguration>()).first(where: { $0.id == id }) else {
            throw HomeConfigurationError.roomNotFound
        }
        stored.setNameSource(source, displayName: source.displayName(in: language))
        stored.symbolName = symbolName
        try save()
    }

    func deleteRoom(id: UUID) throws {
        guard id != ModuleCatalog.unspecifiedRoomID else { throw HomeConfigurationError.cannotModifyUnspecifiedRoom }
        let storedRooms = try context.fetch(FetchDescriptor<StoredRoomConfiguration>())
        guard let room = storedRooms.first(where: { $0.id == id }) else { throw HomeConfigurationError.roomNotFound }
        for module in try context.fetch(FetchDescriptor<StoredModuleConfiguration>()) where module.roomID == id {
            module.roomID = ModuleCatalog.unspecifiedRoomID
            module.updatedAt = Date()
        }
        context.delete(room)
        try save()
    }

    func reorderRooms(orderedIDs: [UUID]) throws {
        let storedRooms = try context.fetch(FetchDescriptor<StoredRoomConfiguration>())
        var nextOrder = 0
        for id in orderedIDs where id != ModuleCatalog.unspecifiedRoomID {
            guard let stored = storedRooms.first(where: { $0.id == id }) else { continue }
            stored.sortOrder = nextOrder
            nextOrder += 1
        }
        try save()
    }

    func updateModule(id: UUID, customName: String?, roomID: UUID) throws {
        let current = try load()
        guard current.rooms.contains(where: { $0.id == roomID }) else { throw HomeConfigurationError.roomNotFound }
        let normalized: String?
        if let customName {
            normalized = try HomeConfigurationValidation.normalizedName(customName)
        } else {
            normalized = nil
        }
        let existing = try context.fetch(FetchDescriptor<StoredModuleConfiguration>()).first(where: { $0.moduleID == id })
        if let existing {
            existing.customName = normalized
            existing.roomID = roomID
            existing.updatedAt = Date()
        } else {
            context.insert(StoredModuleConfiguration(moduleID: id, customName: normalized, roomID: roomID))
        }
        try save()
    }

    func updateHomeName(_ customName: String?) throws {
        let normalized = try customName.map { try HomeConfigurationValidation.normalizedName($0) }
        if let stored = try storedHome() {
            stored.customName = normalized
            stored.updatedAt = Date()
        } else {
            context.insert(StoredHomeConfiguration(customName: normalized))
        }
        try save()
    }

    private func storedHome() throws -> StoredHomeConfiguration? {
        var descriptor = FetchDescriptor<StoredHomeConfiguration>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func seedDefaultsIfNeeded() throws {
        let rooms = try context.fetch(FetchDescriptor<StoredRoomConfiguration>())
        guard rooms.isEmpty else { return }
        for room in HomeConfigurationDefaults.rooms(in: language) {
            context.insert(StoredRoomConfiguration(id: room.id, nameSource: room.nameSource, displayName: room.name, symbolName: room.symbolName, sortOrder: room.sortOrder))
        }
        try context.save()
    }

    /// One-time, in-place classification of rooms saved before names could follow the app
    /// language (`nameSourceKind == nil`). Ids, names, icons and order are never changed:
    /// - the fallback room becomes `.unspecified` (it can't be renamed anyway);
    /// - a seeded default room that still has its original Korean seed name becomes an
    ///   app-provided `.suggestion`, so it now reads e.g. `Living Room` in English;
    /// - every other row — including a seeded room the user renamed — becomes `.custom`,
    ///   shown verbatim in every language.
    /// Rows are only ever classified once; later saves record their source explicitly.
    private func classifyLegacyRoomNames() throws {
        let unclassified = try context.fetch(FetchDescriptor<StoredRoomConfiguration>()).filter { $0.nameSourceKind == nil }
        guard !unclassified.isEmpty else { return }
        for room in unclassified {
            let source: RoomNameSource
            if room.id == ModuleCatalog.unspecifiedRoomID {
                source = .unspecified
            } else if let seed = HomeConfigurationDefaults.legacySeedNames[room.id], seed.name == room.name {
                source = .suggestion(symbolName: seed.symbolName, ordinal: 1)
            } else {
                source = .custom(room.name)
            }
            // Keep the stored `name` column exactly as it was.
            room.setNameSource(source, displayName: room.name)
        }
        try context.save()
    }

    private func save() throws {
        do {
            try context.save()
        } catch {
            throw HomeConfigurationError.persistence(String(describing: error))
        }
    }
}
