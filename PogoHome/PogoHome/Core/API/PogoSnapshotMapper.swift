import Foundation

/// Turns a decoded `PogoSnapshotDTO` into the UI-facing `HomeSnapshot`, validating the
/// wire contract along the way. Kept separate from `Decodable` conformance so schema
/// validation (version, identifier shape, duplicates) is easy to unit test independent of
/// JSON parsing itself.
nonisolated enum PogoSnapshotMapper {
    static let supportedSchemaVersion = 1

    /// - Parameter generatedAt: The moment the app received/generated this snapshot data.
    ///   The API has no per-reading measurement timestamp, so this single value is reused
    ///   as every module's `lastSeen` and every reading's `timestamp`. It represents when
    ///   the app saw the data, not when a sensor actually measured it — callers must not
    ///   treat it as a measurement time.
    static func map(_ dto: PogoSnapshotDTO, generatedAt: Date) throws -> HomeSnapshot {
        guard dto.schemaVersion == supportedSchemaVersion else {
            throw PogoAPIError.unsupportedSchemaVersion(found: dto.schemaVersion, expected: supportedSchemaVersion)
        }

        var seenIdentifiers: Set<String> = []
        var usedRoomIDs: Set<UUID> = []
        var modules: [SensorModule] = []
        modules.reserveCapacity(dto.modules.count)

        for moduleDTO in dto.modules {
            let raw = moduleDTO.uuid.lowercased()
            guard ModuleIdentity.isValidRawIdentifier(raw) else {
                throw PogoAPIError.invalidModuleIdentifier(moduleDTO.uuid)
            }
            guard seenIdentifiers.insert(raw).inserted else {
                throw PogoAPIError.duplicateModuleIdentifier(moduleDTO.uuid)
            }

            let descriptor = ModuleCatalog.descriptor(forRawIdentifier: raw, apiRole: moduleDTO.role)
            usedRoomIDs.insert(descriptor.room.id)

            let readings: [SensorReading] = moduleDTO.readings.compactMap { readingDTO in
                guard let kind = readingDTO.mappedKind else { return nil }
                return SensorReading(
                    kind: kind,
                    value: readingDTO.value,
                    timestamp: generatedAt,
                    status: readingDTO.mappedStatus
                )
            }

            modules.append(
                SensorModule(
                    id: ModuleIdentity.stableUUID(forRawIdentifier: raw),
                    name: descriptor.displayName,
                    roomID: descriptor.room.id,
                    readings: readings,
                    isOnline: moduleDTO.online,
                    lastSeen: generatedAt,
                    roleDescription: descriptor.roleDescription
                )
            )
        }

        let rooms = ModuleCatalog.allRooms
            .filter { usedRoomIDs.contains($0.id) }
            .sorted { $0.sortOrder < $1.sortOrder }

        return HomeSnapshot(timestamp: generatedAt, rooms: rooms, modules: modules)
    }

    /// Decodes raw JSON `Data` into a `HomeSnapshot`, wrapping JSON errors in
    /// `PogoAPIError.malformedJSON` instead of letting `DecodingError` escape.
    static func decodeSnapshot(from data: Data) throws -> HomeSnapshot {
        let dto: PogoSnapshotDTO
        do {
            dto = try JSONDecoder().decode(PogoSnapshotDTO.self, from: data)
        } catch {
            throw PogoAPIError.malformedJSON(String(describing: error))
        }
        let generatedAt = Date(timeIntervalSince1970: Double(dto.generatedAtUnixMs) / 1000)
        return try map(dto, generatedAt: generatedAt)
    }
}
