import Foundation

/// The home settings a Jogakbo hub keeps for every device paired with it (Linux
/// `home_settings.hpp`, `docs/pogohome-api-v1.md` "Home settings"): the home name, the rooms, and
/// each sensor module's custom name and room.
///
/// Deliberately not here: readings and connection state (the snapshot's), simulated data, Apple
/// Home's homes/rooms/accessories, and everything that belongs to one device (language,
/// appearance, the selected tab, the Watch's sensor choice).
///
/// A module is keyed by its real module UUID as the hub reports it (`"744dbdfffe65d357"`), never by
/// the app's derived `UUID`, so its name and room follow it across detaching, re-docking and
/// moving to another Power Base. A room is keyed by its `UUID`. The app's fixed "미지정 공간" is
/// never listed; a module in it has no `roomID`.
nonisolated struct HubSettingsDocument: Codable, Hashable, Sendable {
    var homeName: String?
    var rooms: [HubRoomSetting]
    var modules: [HubModuleSetting]

    enum CodingKeys: String, CodingKey {
        case homeName = "home_name"
        case rooms, modules
    }

    init(homeName: String?, rooms: [HubRoomSetting], modules: [HubModuleSetting]) {
        self.homeName = homeName
        self.rooms = rooms
        self.modules = modules
    }

    /// The hub requires every key to be present, `null` included.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(homeName, forKey: .homeName)
        try container.encode(rooms, forKey: .rooms)
        try container.encode(modules, forKey: .modules)
    }
}

nonisolated struct HubRoomSetting: Codable, Hashable, Sendable {
    enum NameKind: String, Codable, Sendable {
        /// Typed by the user: the same text on every device.
        case custom
        /// The app's own name for an icon ("거실"/"Living Room"): each device shows it in its language.
        case suggestion
    }

    let id: UUID
    let nameKind: NameKind
    /// `.custom` only.
    let name: String?
    /// `.suggestion` only.
    let suggestionSymbol: String?
    /// `.suggestion` only.
    let suggestionOrdinal: Int?
    let symbol: String

    enum CodingKeys: String, CodingKey {
        case id
        case nameKind = "name_kind"
        case name
        case suggestionSymbol = "suggestion_symbol"
        case suggestionOrdinal = "suggestion_ordinal"
        case symbol
    }
}

nonisolated struct HubModuleSetting: Codable, Hashable, Sendable {
    /// The module UUID as `/api/v1/snapshot` lists it (lowercase hex).
    let uuid: String
    let name: String?
    let roomID: UUID?

    enum CodingKeys: String, CodingKey {
        case uuid, name
        case roomID = "room_id"
    }

    init(uuid: String, name: String?, roomID: UUID?) {
        self.uuid = uuid
        self.name = name
        self.roomID = roomID
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uuid, forKey: .uuid)
        try container.encode(name, forKey: .name)
        try container.encode(roomID, forKey: .roomID)
    }
}

/// `GET /api/v1/settings` (and the body of a successful `PUT`, and a conflict's `current`).
nonisolated struct HubSettingsState: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let hubID: String
    /// `false` until the first device uploads settings.
    let initialized: Bool
    /// Opaque, assigned by the hub; `nil` while not initialized. Only ever compared for equality and
    /// sent back as the base of the next change.
    let revision: String?
    let updatedAtUnixMs: Int64?
    let settings: HubSettingsDocument?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case hubID = "hub_id"
        case initialized, revision
        case updatedAtUnixMs = "updated_at_unix_ms"
        case settings
    }
}

nonisolated enum HubSettingsMapping {
    /// The hub's settings as the app's configuration: rooms in the hub's order (then "미지정 공간"),
    /// module names and rooms keyed by the same derived `UUID` the snapshot mapper gives each module.
    static func configuration(from document: HubSettingsDocument, language: AppLanguage) -> HomeConfigurationSnapshot {
        var rooms: [Room] = document.rooms.enumerated().map { index, room in
            Room(id: room.id, nameSource: nameSource(of: room), symbolName: room.symbol, sortOrder: index, language: language)
        }
        rooms.append(ModuleCatalog.unspecifiedRoom(in: language))
        let roomIDs = Set(rooms.map(\.id))
        var modules: [UUID: ModuleConfiguration] = [:]
        for module in document.modules {
            let raw = module.uuid.lowercased()
            guard ModuleIdentity.isValidRawIdentifier(raw) else { continue }
            let id = ModuleIdentity.stableUUID(forRawIdentifier: raw)
            let roomID = module.roomID.flatMap { roomIDs.contains($0) ? $0 : nil } ?? ModuleCatalog.unspecifiedRoomID
            modules[id] = ModuleConfiguration(moduleID: id, customName: module.name, roomID: roomID, updatedAt: .distantPast)
        }
        return HomeConfigurationSnapshot(rooms: rooms, modules: modules, customHomeName: document.homeName)
    }

    /// The app's configuration as the hub's document. `rawIdentifiers` maps each module's derived
    /// `UUID` to its real module UUID; a module the map doesn't know (it came from another hub or
    /// from simulated data) is left out — the hub could never recognize it. So is a module that has
    /// neither a custom name nor a room: there is nothing to share about it.
    static func document(
        from configuration: HomeConfigurationSnapshot,
        rawIdentifiers: [UUID: String]
    ) -> HubSettingsDocument {
        let rooms = configuration.rooms
            .filter { $0.id != ModuleCatalog.unspecifiedRoomID }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(roomSetting(from:))
        let sharedRoomIDs = Set(rooms.map(\.id))
        let modules = configuration.modules.values.compactMap { module -> HubModuleSetting? in
            guard let raw = rawIdentifiers[module.moduleID] else { return nil }
            let roomID = sharedRoomIDs.contains(module.roomID) ? module.roomID : nil
            guard module.customName != nil || roomID != nil else { return nil }
            return HubModuleSetting(uuid: raw, name: module.customName, roomID: roomID)
        }
        .sorted { $0.uuid < $1.uuid }
        return HubSettingsDocument(homeName: configuration.customHomeName, rooms: rooms, modules: modules)
    }

    static func nameSource(of room: HubRoomSetting) -> RoomNameSource {
        switch room.nameKind {
        case .suggestion:
            if let symbol = room.suggestionSymbol {
                return .suggestion(symbolName: symbol, ordinal: max(1, room.suggestionOrdinal ?? 1))
            }
            return .custom(room.name ?? "")
        case .custom:
            return .custom(room.name ?? "")
        }
    }

    static func roomSetting(from room: Room) -> HubRoomSetting {
        switch room.nameSource {
        case let .suggestion(symbolName, ordinal):
            return HubRoomSetting(id: room.id, nameKind: .suggestion, name: nil, suggestionSymbol: symbolName, suggestionOrdinal: ordinal, symbol: room.symbolName)
        case let .custom(name):
            return HubRoomSetting(id: room.id, nameKind: .custom, name: name, suggestionSymbol: nil, suggestionOrdinal: nil, symbol: room.symbolName)
        case .unspecified:
            // Only the fallback room has this source, and it is never shared.
            return HubRoomSetting(id: room.id, nameKind: .custom, name: room.name, suggestionSymbol: nil, suggestionOrdinal: nil, symbol: room.symbolName)
        }
    }

    /// Derived module `UUID` → real module UUID, for every module the app can name: those in the
    /// hub's document and those in the current snapshot from that hub.
    static func rawIdentifiers(document: HubSettingsDocument?, snapshot: HomeSnapshot) -> [UUID: String] {
        var map: [UUID: String] = [:]
        for module in document?.modules ?? [] {
            let raw = module.uuid.lowercased()
            guard ModuleIdentity.isValidRawIdentifier(raw) else { continue }
            map[ModuleIdentity.stableUUID(forRawIdentifier: raw)] = raw
        }
        for module in snapshot.modules {
            if let raw = module.hardwareIdentifier?.lowercased(), ModuleIdentity.isValidRawIdentifier(raw) {
                map[module.id] = raw
            }
        }
        return map
    }
}
