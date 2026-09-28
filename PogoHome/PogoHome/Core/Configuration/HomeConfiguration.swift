import Foundation

nonisolated struct ModuleConfiguration: Hashable, Sendable {
    let moduleID: UUID
    let customName: String?
    let roomID: UUID
    let updatedAt: Date
}

nonisolated struct HomeConfigurationSnapshot: Hashable, Sendable {
    let rooms: [Room]
    let modules: [UUID: ModuleConfiguration]
    /// The user's own home name, verbatim, or `nil` to show the localized default
    /// (`HomeConfigurationDefaults.homeName`). A PogoHome-only display name — it is never
    /// written to Apple Home.
    let customHomeName: String?

    init(rooms: [Room], modules: [UUID: ModuleConfiguration], customHomeName: String? = nil) {
        self.rooms = rooms
        self.modules = modules
        self.customHomeName = customHomeName
    }

    static var defaults: HomeConfigurationSnapshot {
        HomeConfigurationSnapshot(rooms: HomeConfigurationDefaults.rooms, modules: [:])
    }
}

nonisolated enum HomeConfigurationDefaults {
    static let livingRoomID = UUID(uuidString: "8A3B1C10-0001-4000-8000-000000000001")!
    static let bedroomID = UUID(uuidString: "8A3B1C10-0002-4000-8000-000000000002")!
    static let workspaceID = UUID(uuidString: "8A3B1C10-0003-4000-8000-000000000003")!

    /// The seeded rooms use the icon catalog's suggestion for their icon as an app-provided
    /// name, so they read `거실`/`Living Room`/`Sala` in each language until the user renames them.
    static func rooms(in language: AppLanguage) -> [Room] {
        [
            Room(id: livingRoomID, nameSource: .suggestion(symbolName: "sofa.fill", ordinal: 1), symbolName: "sofa.fill", sortOrder: 0, language: language),
            Room(id: bedroomID, nameSource: .suggestion(symbolName: "bed.double.fill", ordinal: 1), symbolName: "bed.double.fill", sortOrder: 1, language: language),
            Room(id: workspaceID, nameSource: .suggestion(symbolName: "desktopcomputer", ordinal: 1), symbolName: "desktopcomputer", sortOrder: 2, language: language),
            ModuleCatalog.unspecifiedRoom(in: language),
        ]
    }

    static var rooms: [Room] { rooms(in: .current) }
    static var livingRoom: Room { rooms[0] }
    static var bedroom: Room { rooms[1] }
    static var workspace: Room { rooms[2] }
    static var unspecifiedRoom: Room { ModuleCatalog.unspecifiedRoom }

    /// Exactly what builds before localization seeded (always Korean, whatever the device
    /// language). A stored row is treated as an app-provided default name only when it has one
    /// of these ids *and* still carries this exact name — i.e. the user never renamed it.
    /// Anything else saved back then is kept as a verbatim custom name.
    static let legacySeedNames: [UUID: (name: String, symbolName: String)] = [
        livingRoomID: ("거실", "sofa.fill"),
        bedroomID: ("침실", "bed.double.fill"),
        workspaceID: ("작업실", "desktopcomputer"),
    ]

    static let homeName: LocalizedStringResource = "우리 집"

    static func homeName(in language: AppLanguage) -> String {
        language.string(homeName)
    }
}

nonisolated enum HomeConfigurationError: LocalizedError, Equatable {
    case emptyName
    case nameTooLong(maximum: Int)
    case duplicateRoomName
    case roomNotFound
    case moduleNotFound
    case cannotModifyUnspecifiedRoom
    case persistence(String)

    var errorDescription: String? {
        switch self {
        case .emptyName: return String(localized: "이름을 입력해 주세요.")
        case let .nameTooLong(maximum): return String(localized: "이름은 최대 \(maximum)자까지 입력할 수 있습니다.")
        case .duplicateRoomName: return String(localized: "같은 이름의 방이 이미 있습니다.")
        case .roomNotFound: return String(localized: "선택한 방을 찾을 수 없습니다.")
        case .moduleNotFound: return String(localized: "센서 모듈을 찾을 수 없습니다.")
        case .cannotModifyUnspecifiedRoom: return String(localized: "미지정 공간은 수정하거나 삭제할 수 없습니다.")
        case let .persistence(message): return String(localized: "설정을 저장하지 못했습니다: \(message)")
        }
    }
}

nonisolated enum HomeConfigurationValidation {
    static let maximumNameLength = 30

    static func normalizedName(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HomeConfigurationError.emptyName }
        guard trimmed.count <= maximumNameLength else {
            throw HomeConfigurationError.nameTooLong(maximum: maximumNameLength)
        }
        return trimmed
    }

    /// The one definition of "two room names collide", shared by both stores' duplicate
    /// check and `RoomNameSuggestion`, so a suggested name is never one the store rejects.
    static func isSameRoomName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}
