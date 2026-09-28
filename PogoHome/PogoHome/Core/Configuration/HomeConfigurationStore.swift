import Foundation

@MainActor
protocol HomeConfigurationStore: AnyObject {
    /// Rooms come back with names already resolved in the store's language: user-typed names
    /// verbatim, app-provided names (`RoomNameSource.isAppProvided`) in that language.
    func load() throws -> HomeConfigurationSnapshot
    @discardableResult func createRoom(nameSource: RoomNameSource, symbolName: String) throws -> Room
    func updateRoom(id: UUID, nameSource: RoomNameSource, symbolName: String) throws
    func deleteRoom(id: UUID) throws
    /// Persists a new display order for every *non-fallback* room, by index in `orderedIDs`.
    /// `ModuleCatalog.unspecifiedRoom`'s id is silently ignored if present — it never
    /// participates in user-driven ordering and always sorts last. An id that doesn't match
    /// any stored room is silently ignored rather than thrown, so a caller can always pass
    /// its full current on-screen list without first reconciling it against the store.
    func reorderRooms(orderedIDs: [UUID]) throws
    func updateModule(id: UUID, customName: String?, roomID: UUID) throws
    /// `nil` goes back to the localized default home name.
    func updateHomeName(_ customName: String?) throws
}

extension HomeConfigurationStore {
    /// A room with a user-typed name.
    @discardableResult
    func createRoom(name: String, symbolName: String) throws -> Room {
        try createRoom(nameSource: .custom(name), symbolName: symbolName)
    }

    func updateRoom(id: UUID, name: String, symbolName: String) throws {
        try updateRoom(id: id, nameSource: .custom(name), symbolName: symbolName)
    }
}

/// Shared by both stores so they validate names identically.
nonisolated enum RoomNameValidation {
    /// Trims/validates a custom name and rejects any name — custom or app-provided — that
    /// collides with another room's name as displayed in `language`.
    static func validated(
        _ source: RoomNameSource,
        rooms: [Room],
        excluding id: UUID?,
        language: AppLanguage
    ) throws -> RoomNameSource {
        let normalizedSource: RoomNameSource
        switch source {
        case let .custom(name):
            normalizedSource = .custom(try HomeConfigurationValidation.normalizedName(name))
        case .suggestion, .unspecified:
            normalizedSource = source
        }
        let displayName = normalizedSource.displayName(in: language)
        if rooms.contains(where: {
            $0.id != id && HomeConfigurationValidation.isSameRoomName($0.name, displayName)
        }) {
            throw HomeConfigurationError.duplicateRoomName
        }
        return normalizedSource
    }
}

@MainActor
final class InMemoryHomeConfigurationStore: HomeConfigurationStore {
    private var rooms: [Room]
    private var modules: [UUID: ModuleConfiguration]
    private var customHomeName: String?
    private let language: AppLanguage

    init(
        rooms: [Room]? = nil,
        modules: [UUID: ModuleConfiguration] = [:],
        customHomeName: String? = nil,
        language: AppLanguage = .current
    ) {
        self.language = language
        self.rooms = rooms ?? HomeConfigurationDefaults.rooms(in: language)
        self.modules = modules
        self.customHomeName = customHomeName
    }

    func load() throws -> HomeConfigurationSnapshot {
        HomeConfigurationSnapshot(
            rooms: rooms.map { $0.resolved(in: language) }.sorted { $0.sortOrder < $1.sortOrder },
            modules: modules,
            customHomeName: customHomeName
        )
    }

    @discardableResult
    func createRoom(nameSource: RoomNameSource, symbolName: String) throws -> Room {
        let current = try load().rooms
        let source = try RoomNameValidation.validated(nameSource, rooms: current, excluding: nil, language: language)
        let nextOrder = (rooms.map(\.sortOrder).filter { $0 < ModuleCatalog.unspecifiedRoomSortOrder }.max() ?? -1) + 1
        let room = Room(id: UUID(), nameSource: source, symbolName: symbolName, sortOrder: nextOrder, language: language)
        rooms.append(room)
        return room
    }

    func updateRoom(id: UUID, nameSource: RoomNameSource, symbolName: String) throws {
        guard id != ModuleCatalog.unspecifiedRoomID else {
            throw HomeConfigurationError.cannotModifyUnspecifiedRoom
        }
        guard let index = rooms.firstIndex(where: { $0.id == id }) else {
            throw HomeConfigurationError.roomNotFound
        }
        let source = try RoomNameValidation.validated(nameSource, rooms: try load().rooms, excluding: id, language: language)
        rooms[index] = Room(id: id, nameSource: source, symbolName: symbolName, sortOrder: rooms[index].sortOrder, language: language)
    }

    func deleteRoom(id: UUID) throws {
        guard id != ModuleCatalog.unspecifiedRoomID else {
            throw HomeConfigurationError.cannotModifyUnspecifiedRoom
        }
        guard rooms.contains(where: { $0.id == id }) else { throw HomeConfigurationError.roomNotFound }
        rooms.removeAll { $0.id == id }
        for (moduleID, configuration) in modules where configuration.roomID == id {
            modules[moduleID] = ModuleConfiguration(
                moduleID: moduleID,
                customName: configuration.customName,
                roomID: ModuleCatalog.unspecifiedRoomID,
                updatedAt: Date()
            )
        }
    }

    func reorderRooms(orderedIDs: [UUID]) throws {
        var nextOrder = 0
        for id in orderedIDs where id != ModuleCatalog.unspecifiedRoomID {
            guard let index = rooms.firstIndex(where: { $0.id == id }) else { continue }
            rooms[index] = rooms[index].with(sortOrder: nextOrder, language: language)
            nextOrder += 1
        }
    }

    func updateModule(id: UUID, customName: String?, roomID: UUID) throws {
        guard rooms.contains(where: { $0.id == roomID }) else { throw HomeConfigurationError.roomNotFound }
        let normalized: String?
        if let customName {
            normalized = try HomeConfigurationValidation.normalizedName(customName)
        } else {
            normalized = nil
        }
        modules[id] = ModuleConfiguration(moduleID: id, customName: normalized, roomID: roomID, updatedAt: Date())
    }

    func updateHomeName(_ customName: String?) throws {
        customHomeName = try customName.map { try HomeConfigurationValidation.normalizedName($0) }
    }
}
