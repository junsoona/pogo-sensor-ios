import Foundation

/// Everything the live data source needs to turn a raw wire module identifier into a
/// display name, an optional role description, and the room it belongs to.
nonisolated struct ModuleCatalogDescriptor: Hashable, Sendable {
    let displayName: String
    let roleDescription: String?
    let room: Room
}

/// The single place that knows about specific, real PogoHome module identifiers.
///
/// The real API has no concept of user-assigned room names yet, so every known module
/// currently resolves to `unspecifiedRoom`. This is still centralized here — not
/// scattered as `if uuid == "..."` checks across mapping/view code — so that adding real
/// room assignment later, or a new known module, is a one-place change. An identifier
/// that isn't in `entries` is never treated as an error: it safely falls back to "새 센서
/// 모듈" ("new sensor module") in `unspecifiedRoom", so an unrecognized module still shows
/// up with all of its sensor data intact.
///
/// Product names and roles are app-provided text, so they are resolved in the current UI
/// language every time a snapshot is mapped; a user's own module name is a separate
/// persisted override (`ModuleConfiguration.customName`) and is never touched by this.
nonisolated enum ModuleCatalog {
    static let unspecifiedRoomID = UUID(uuidString: "9C6B8B2E-0000-4000-8000-000000000000")!
    static let unspecifiedRoomSortOrder = 999
    static let unspecifiedRoomName: LocalizedStringResource = "미지정 공간"

    static var unspecifiedRoom: Room { unspecifiedRoom(in: .current) }

    static func unspecifiedRoom(in language: AppLanguage) -> Room {
        Room(id: unspecifiedRoomID, nameSource: .unspecified, symbolName: "square.dashed", sortOrder: unspecifiedRoomSortOrder, language: language)
    }

    private struct Entry {
        let rawIdentifier: String
        let displayName: LocalizedStringResource
        let roleDescription: LocalizedStringResource
    }

    private static let entries: [Entry] = [
        Entry(
            rawIdentifier: "744dbdfffe65d357",
            displayName: "SGP41 가스 센서",
            roleDescription: "VOC/NOx 센서 · depth 1"
        ),
        Entry(
            rawIdentifier: "744dbdfffe65d07a",
            displayName: "PMS5003 미세먼지 센서",
            roleDescription: "PM1/PM2.5/PM10 센서 · depth 2"
        ),
    ]

    /// All rooms a snapshot could ever reference, including the fallback room for unknown
    /// modules. Kept here so mapping code can consult it without duplicating room objects.
    /// Every known module currently lives in `unspecifiedRoom`, so that is the only one.
    static var allRooms: [Room] {
        [unspecifiedRoom]
    }

    static func descriptor(
        forRawIdentifier raw: String,
        apiRole: String?,
        language: AppLanguage = .current
    ) -> ModuleCatalogDescriptor {
        let room = unspecifiedRoom(in: language)
        if let entry = entries.first(where: { $0.rawIdentifier == raw.lowercased() }) {
            return ModuleCatalogDescriptor(
                displayName: language.string(entry.displayName),
                roleDescription: language.string(entry.roleDescription),
                room: room
            )
        }
        return ModuleCatalogDescriptor(
            displayName: language.string("새 센서 모듈"),
            // `role` is a free-form wire value from the hub, shown as-is.
            roleDescription: apiRole,
            room: room
        )
    }
}
