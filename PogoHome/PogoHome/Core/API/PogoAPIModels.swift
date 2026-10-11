import Foundation

/// Wire-format snapshot from the Linux PogoHome API (`GET /api/v1/snapshot`, and the
/// payload carried by `snapshot` events on `GET /api/v1/events`). Deliberately kept
/// separate from `HomeSnapshot`/`SensorModule`/`SensorReading`, which are UI-facing models:
/// this layer exists so a schema change on the wire never silently reshapes the UI models,
/// and so every field the API sends can be preserved here even when the UI doesn't use it.
nonisolated struct PogoSnapshotDTO: Decodable, Hashable, Sendable {
    let schemaVersion: Int
    let generatedAtUnixMs: Int64
    let registryGeneration: Int
    /// Added to API v1 by the multi-Power-Base milestone (additive; `schema_version` stays 1).
    /// `nil` when the bridge predates it — distinct from `[]`, "no Power Base heard from yet".
    let powerBases: [PogoPowerBaseDTO]?
    let modules: [PogoModuleDTO]
    /// Added by the settings-sharing revision (additive): `1` when the hub offers shared home
    /// settings, with `settings_state` (`ready`/`uninitialized`/`unavailable`) and the current
    /// `settings_revision`. All `nil` from a hub without it.
    let settingsAPI: Int?
    let settingsState: String?
    let settingsRevision: String?
    /// Added by the Power Base management revision (additive): the hub's removal (unenroll) jobs.
    /// `nil` from a hub without management -- distinct from `[]`, "no job".
    let powerBaseRemovals: [PowerBaseRemovalDTO]?
    /// Added later (additive): the Power Bases the hub took out of its list. `nil` from a hub that
    /// cannot do that -- distinct from `[]`, "none".
    let powerBaseForgets: [PowerBaseForgetDTO]?
    /// Added later (additive): the Power Bases that are out of the hub's list now -- their
    /// registration ended and they were not registered again. `nil` from a hub that does not say
    /// (Linux bridge 0.4.1 and earlier) -- distinct from `[]`, "none".
    let powerBaseDepartures: [PowerBaseDepartureDTO]?
    /// Added later (additive): where this snapshot stands among the snapshots of one run of the
    /// hub. `snapshot_stream` (32 lower-case hex digits) is made when the bridge starts;
    /// `snapshot_sequence` counts the snapshots of that run in the order they were made, whether
    /// they went out as a `GET` answer or as an event. Both `nil` from a hub that does not say
    /// (Linux bridge 0.4.2 and earlier).
    let snapshotStream: String?
    let snapshotSequence: Int64?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAtUnixMs = "generated_at_unix_ms"
        case registryGeneration = "registry_generation"
        case powerBases = "power_bases"
        case powerBaseRemovals = "power_base_removals"
        case powerBaseForgets = "power_base_forgets"
        case powerBaseDepartures = "power_base_departures"
        case snapshotStream = "snapshot_stream"
        case snapshotSequence = "snapshot_sequence"
        case modules
        case settingsAPI = "settings_api"
        case settingsState = "settings_state"
        case settingsRevision = "settings_revision"
    }
}

nonisolated struct PogoPowerBaseDTO: Decodable, Hashable, Sendable {
    /// The Base's eFuse EUI-64 as 16 lowercase hex digits.
    let uuid: String
    let online: Bool
    let moduleCount: Int?
    let onlineModuleCount: Int?
    /// Added by the Power Base management revision: `"supported"` when the hub can unenroll this
    /// Base remotely, `"unsupported"` when it holds no management credential for it. `nil` from a
    /// hub without management.
    let management: String?
    /// Added later (additive), with `management` `"supported"`: `"automatic"` when the board
    /// confirms the erase behind a removal to the hub itself, `"manual"` when that has to be done
    /// near the board over Bluetooth. `nil` from a hub that predates it.
    let eraseConfirmation: String?
    /// Added later (additive): the registration the hub lists for this Base, 32 lower-case hex
    /// digits. `nil` from a hub that cannot take a Base out of its list.
    let record: String?
    /// Added later (additive), with `management` `"supported"`: how many removals were asked of
    /// the listed registration so far. `nil` from a hub whose removal request names the Base
    /// alone (Linux bridge 0.4.2 and earlier).
    let removalSerial: Int?

    enum CodingKeys: String, CodingKey {
        case uuid, online, management, record
        case moduleCount = "module_count"
        case onlineModuleCount = "online_module_count"
        case eraseConfirmation = "erase_confirmation"
        case removalSerial = "removal_serial"
    }
}

nonisolated struct PogoModuleDTO: Decodable, Hashable, Sendable {
    /// Raw module identifier as sent by the API. NOT a Foundation `UUID` string — real
    /// hardware sends short hex identifiers (e.g. `"744dbdfffe65d357"`), which is why this
    /// is validated and mapped separately by `ModuleIdentity` rather than parsed with
    /// `UUID(uuidString:)`.
    let uuid: String
    /// The Power Base this module is docked under (multi-Power-Base milestone; optional so an
    /// older bridge's snapshot still decodes).
    let powerBaseUUID: String?
    /// The module's POGO parent: its Power Base, or the upstream module.
    let parentUUID: String?
    let online: Bool
    let depth: Int
    let role: String?
    let sensorBitmap: Int?
    let generation: Int?
    let lastSeq: Int?
    let readings: [PogoReadingDTO]

    enum CodingKeys: String, CodingKey {
        case uuid, online, depth, role
        case powerBaseUUID = "power_base_uuid"
        case parentUUID = "parent_uuid"
        case sensorBitmap = "sensor_bitmap"
        case generation
        case lastSeq = "last_seq"
        case readings
    }
}

nonisolated struct PogoReadingDTO: Decodable, Hashable, Sendable {
    /// Raw `kind` string from the wire. Kept as a string (not a `SensorKind`-backed enum)
    /// so a future, unrecognized sensor kind never fails decoding of the whole snapshot.
    let kindRaw: String
    let rawValue: Double?
    let scale: Double?
    let value: Double
    let unit: String?
    /// Raw `status` string from the wire, preserved verbatim; see `mappedStatus` for the
    /// safe, lossy mapping into the UI's `SensorStatus`.
    let statusRaw: String
    let sampleSeq: Int?

    enum CodingKeys: String, CodingKey {
        case kindRaw = "kind"
        case rawValue = "raw_value"
        case scale
        case value
        case unit
        case statusRaw = "status"
        case sampleSeq = "sample_seq"
    }
}

nonisolated extension PogoReadingDTO {
    /// Maps the wire `kind` string to one of the app's 10 known `SensorKind` cases.
    /// Returns `nil` for anything else (a future sensor kind) so the caller can skip the
    /// reading instead of failing the whole snapshot.
    var mappedKind: SensorKind? {
        switch kindRaw {
        case "illuminance": return .illuminance
        case "temperature": return .temperature
        case "humidity": return .humidity
        case "voc_raw": return .vocRaw
        case "voc_index": return .vocIndex
        case "nox_raw": return .noxRaw
        case "nox_index": return .noxIndex
        case "pm1": return .pm1
        case "pm2_5": return .pm2_5
        case "pm10": return .pm10
        default: return nil
        }
    }

    /// Maps the wire `status` string to `SensorStatus`. Only exact, known-good strings map
    /// to `.normal`/`.conditioning`/`.error`; anything else — including a future status the
    /// server might introduce — safely falls back to `.unavailable` rather than guessing.
    var mappedStatus: SensorStatus {
        switch statusRaw {
        case "ok": return .normal
        case "conditioning": return .conditioning
        case "error": return .error
        default: return .unavailable
        }
    }
}

/// Errors from decoding or validating a `PogoSnapshotDTO`. Each case carries enough detail
/// to log or surface a clear message, without ever crashing the app.
nonisolated enum PogoAPIError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(found: Int, expected: Int)
    case invalidModuleIdentifier(String)
    case duplicateModuleIdentifier(String)
    case invalidPowerBaseIdentifier(String)
    case duplicatePowerBaseIdentifier(String)
    case malformedJSON(String)
    case transport(String)
}

nonisolated extension PogoAPIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(found, expected):
            return String(localized: "지원하지 않는 schema_version입니다 (수신: \(found), 지원: \(expected)).", comment: "API error; schema_version is a technical field name, do not translate it")
        case let .invalidModuleIdentifier(raw):
            return String(localized: "모듈 UUID 형식이 올바르지 않습니다: \(raw)", comment: "API error")
        case let .duplicateModuleIdentifier(raw):
            return String(localized: "중복된 모듈 UUID가 있습니다: \(raw)", comment: "API error")
        case let .invalidPowerBaseIdentifier(raw):
            return String(localized: "Power Base UUID 형식이 올바르지 않습니다: \(raw)", comment: "API error")
        case let .duplicatePowerBaseIdentifier(raw):
            return String(localized: "중복된 Power Base UUID가 있습니다: \(raw)", comment: "API error")
        case let .malformedJSON(detail):
            return String(localized: "손상된 JSON 응답입니다: \(detail)", comment: "API error")
        case let .transport(detail):
            return String(localized: "네트워크 오류: \(detail)", comment: "API error")
        }
    }
}
