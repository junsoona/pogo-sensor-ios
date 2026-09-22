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
nonisolated enum ModuleCatalog {
    static let unspecifiedRoom = Room(
        id: UUID(uuidString: "9C6B8B2E-0000-4000-8000-000000000000")!,
        name: "미지정 공간",
        symbolName: "square.dashed",
        sortOrder: 0
    )

    private struct Entry {
        let rawIdentifier: String
        let displayName: String
        let roleDescription: String
        let room: Room
    }

    private static let entries: [Entry] = [
        Entry(
            rawIdentifier: "744dbdfffe65d357",
            displayName: "SGP41 가스 센서",
            roleDescription: "VOC/NOx 센서 · depth 1",
            room: unspecifiedRoom
        ),
        Entry(
            rawIdentifier: "744dbdfffe65d07a",
            displayName: "PMS5003 미세먼지 센서",
            roleDescription: "PM1/PM2.5/PM10 센서 · depth 2",
            room: unspecifiedRoom
        ),
    ]

    /// All rooms a snapshot could ever reference, including the fallback room for unknown
    /// modules. Kept here so mapping code can consult it without duplicating room objects.
    static var allRooms: [Room] {
        var seen: Set<UUID> = []
        var rooms: [Room] = []
        for entry in entries where seen.insert(entry.room.id).inserted {
            rooms.append(entry.room)
        }
        if seen.insert(unspecifiedRoom.id).inserted {
            rooms.append(unspecifiedRoom)
        }
        return rooms
    }

    static func descriptor(forRawIdentifier raw: String, apiRole: String?) -> ModuleCatalogDescriptor {
        if let entry = entries.first(where: { $0.rawIdentifier == raw.lowercased() }) {
            return ModuleCatalogDescriptor(
                displayName: entry.displayName,
                roleDescription: entry.roleDescription,
                room: entry.room
            )
        }
        return ModuleCatalogDescriptor(
            displayName: "새 센서 모듈",
            roleDescription: apiRole,
            room: unspecifiedRoom
        )
    }
}
