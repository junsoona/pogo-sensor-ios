import Foundation

/// Default presentation derived from the module's current advertised channels.
nonisolated struct ModuleCatalogDescriptor: Hashable, Sendable {
    let displayName: String
    let roleDescription: String?
    let representativeSensorKind: SensorKind?
    let room: Room
}

/// A board's identifier survives reflashing, so it cannot identify the attached sensor.
/// API v1 supplies channel capabilities, not a sensor model number: use category names
/// without guessing an SHT41/SHT45 (or any other exact model). Shared user names and room
/// assignments are applied separately and remain untouched.
nonisolated enum ModuleCatalog {
    static let unspecifiedRoomID = UUID(uuidString: "9C6B8B2E-0000-4000-8000-000000000000")!
    static let unspecifiedRoomSortOrder = 999
    static let unspecifiedRoomName: LocalizedStringResource = "미지정 공간"

    static var unspecifiedRoom: Room { unspecifiedRoom(in: .current) }

    static func unspecifiedRoom(in language: AppLanguage) -> Room {
        Room(id: unspecifiedRoomID, nameSource: .unspecified, symbolName: "square.dashed", sortOrder: unspecifiedRoomSortOrder, language: language)
    }

    /// Raw data is mapped before applying the user's room assignment.
    static var allRooms: [Room] {
        [unspecifiedRoom]
    }

    static func descriptor(
        forRawIdentifier _: String,
        apiRole: String?,
        sensorBitmap: Int? = nil,
        readingKinds: [String] = [],
        language: AppLanguage = .current
    ) -> ModuleCatalogDescriptor {
        // A supplied bitmap is authoritative even while offline or before the first sample.
        // Unknown/invalid/mixed capabilities stay generic; never discard unfamiliar bits.
        let bitmap = sensorBitmap ?? bitmapFromReadings(readingKinds)
        let (name, representativeSensorKind): (LocalizedStringResource, SensorKind?) = switch bitmap {
        case 0x0002: ("온도 센서", .temperature)
        case 0x0004: ("습도 센서", .humidity)
        case 0x0006: ("온습도 센서", .temperature)
        case 0x0001: ("조도 센서", .illuminance)
        case 0x0018: ("VOC 가스 센서", .vocIndex)
        case 0x0060: ("NOx 가스 센서", .noxIndex)
        case 0x0078: ("VOC/NOx 가스 센서", .vocIndex)
        case 0x0380: ("미세먼지 센서", .pm2_5)
        default: ("센서 모듈", nil)
        }
        return ModuleCatalogDescriptor(
            displayName: language.string(name),
            // `role` is a free-form wire value from the hub, shown as-is.
            roleDescription: apiRole,
            representativeSensorKind: representativeSensorKind,
            room: unspecifiedRoom(in: language)
        )
    }

    /// Older API snapshots may omit the bitmap. Use every wire kind, including unknown
    /// ones, so a mixed future sensor is not mislabeled from only its recognized readings.
    private static func bitmapFromReadings(_ kinds: [String]) -> Int? {
        guard !kinds.isEmpty else { return nil }
        let bits = ["temperature": 0x0002, "humidity": 0x0004, "illuminance": 0x0001,
                    "voc_raw": 0x0008, "voc_index": 0x0010, "nox_raw": 0x0020,
                    "nox_index": 0x0040, "pm1": 0x0080, "pm2_5": 0x0100, "pm10": 0x0200]
        var result = 0
        for kind in kinds {
            guard let bit = bits[kind] else { return nil }
            result |= bit
        }
        return result
    }
}
