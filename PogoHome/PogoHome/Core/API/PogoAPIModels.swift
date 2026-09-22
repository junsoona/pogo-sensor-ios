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
    let modules: [PogoModuleDTO]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAtUnixMs = "generated_at_unix_ms"
        case registryGeneration = "registry_generation"
        case modules
    }
}

nonisolated struct PogoModuleDTO: Decodable, Hashable, Sendable {
    /// Raw module identifier as sent by the API. NOT a Foundation `UUID` string — real
    /// hardware sends short hex identifiers (e.g. `"744dbdfffe65d357"`), which is why this
    /// is validated and mapped separately by `ModuleIdentity` rather than parsed with
    /// `UUID(uuidString:)`.
    let uuid: String
    let online: Bool
    let depth: Int
    let role: String?
    let sensorBitmap: Int?
    let generation: Int?
    let lastSeq: Int?
    let readings: [PogoReadingDTO]

    enum CodingKeys: String, CodingKey {
        case uuid, online, depth, role
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
    case malformedJSON(String)
    case transport(String)
}

nonisolated extension PogoAPIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(found, expected):
            return "지원하지 않는 schema_version입니다 (수신: \(found), 지원: \(expected))."
        case let .invalidModuleIdentifier(raw):
            return "모듈 UUID 형식이 올바르지 않습니다: \(raw)"
        case let .duplicateModuleIdentifier(raw):
            return "중복된 모듈 UUID가 있습니다: \(raw)"
        case let .malformedJSON(detail):
            return "손상된 JSON 응답입니다: \(detail)"
        case let .transport(detail):
            return "네트워크 오류: \(detail)"
        }
    }
}
