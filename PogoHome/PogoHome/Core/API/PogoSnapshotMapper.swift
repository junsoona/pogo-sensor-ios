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

        var powerBases: [PowerBase] = []
        var seenPowerBases: Set<String> = []
        for baseDTO in dto.powerBases ?? [] {
            let raw = baseDTO.uuid.lowercased()
            guard ModuleIdentity.isValidRawIdentifier(raw) else {
                throw PogoAPIError.invalidPowerBaseIdentifier(baseDTO.uuid)
            }
            guard seenPowerBases.insert(raw).inserted else {
                throw PogoAPIError.duplicatePowerBaseIdentifier(baseDTO.uuid)
            }
            powerBases.append(
                PowerBase(
                    hardwareIdentifier: raw,
                    isOnline: baseDTO.online,
                    moduleCount: baseDTO.moduleCount ?? 0,
                    onlineModuleCount: baseDTO.onlineModuleCount ?? 0,
                    management: managementSupport(baseDTO.management),
                    eraseConfirmation: PowerBaseEraseConfirmation(wire: baseDTO.eraseConfirmation),
                    record: baseDTO.record,
                    removalSerial: baseDTO.removalSerial
                )
            )
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

            let powerBaseRaw = try moduleDTO.powerBaseUUID.map { try validatedPowerBaseIdentifier($0) }
            let parentRaw = moduleDTO.parentUUID.map { $0.lowercased() }.flatMap {
                ModuleIdentity.isValidRawIdentifier($0) ? $0 : nil
            }

            let descriptor = ModuleCatalog.descriptor(
                forRawIdentifier: raw,
                apiRole: moduleDTO.role,
                sensorBitmap: moduleDTO.sensorBitmap,
                readingKinds: moduleDTO.readings.map(\.kindRaw)
            )
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
                    hardwareName: descriptor.displayName,
                    hardwareIdentifier: raw,
                    roomID: descriptor.room.id,
                    readings: readings,
                    representativeSensorKind: descriptor.representativeSensorKind,
                    isOnline: moduleDTO.online,
                    lastSeen: generatedAt,
                    roleDescription: descriptor.roleDescription,
                    powerBaseIdentifier: powerBaseRaw,
                    parentIdentifier: parentRaw
                )
            )
        }

        let rooms = ModuleCatalog.allRooms
            .filter { usedRoomIDs.contains($0.id) }
            .sorted { $0.sortOrder < $1.sortOrder }

        // A record this app cannot read (a malformed id, a state from a newer hub) is left out;
        // it never fails the whole snapshot and is never shown as something it is not.
        let forgets = (dto.powerBaseForgets ?? []).compactMap(\.forget)
        // A removal whose command may be with the board when its Base is taken out of the list is
        // kept by the hub and named by that list removal (`kept_removal_id`); a newer hub also
        // says so on the job itself (`list_removed`). Either way it is the same job.
        let keptRemovalIDs = Set(forgets.compactMap(\.keptRemovalID))
        let removals = (dto.powerBaseRemovals ?? []).compactMap(\.removal).map { removal -> PowerBaseRemoval in
            guard keptRemovalIDs.contains(removal.id), removal.state == .sent || removal.state == .accepted else { return removal }
            var kept = removal
            kept.powerBaseListRemoved = true
            return kept
        }

        return HomeSnapshot(
            timestamp: generatedAt,
            rooms: rooms,
            modules: modules,
            powerBases: powerBases,
            reportsPowerBases: dto.powerBases != nil,
            hubSettings: hubSettingsSignal(dto),
            powerBaseRemovals: removals,
            reportsPowerBaseManagement: dto.powerBaseRemovals != nil,
            powerBaseForgets: forgets,
            reportsPowerBaseForget: dto.powerBaseForgets != nil,
            // An entry this app cannot read names no Base; it never fails the snapshot.
            powerBaseDepartures: (dto.powerBaseDepartures ?? []).compactMap(\.departure),
            reportsPowerBaseDepartures: dto.powerBaseDepartures != nil,
            delivery: SnapshotDelivery(hubOrder: hubOrder(dto))
        )
    }

    /// Where the hub says this snapshot stands, or `nil` when it does not say -- or says
    /// something that is no stream id or no count: then the snapshot is one from a hub that does
    /// not say.
    private static func hubOrder(_ dto: PogoSnapshotDTO) -> HubSnapshotOrder? {
        guard let stream = dto.snapshotStream, PowerBaseRemovalID.isValid(stream),
              let sequence = dto.snapshotSequence, sequence >= 1 else { return nil }
        return HubSnapshotOrder(stream: stream, sequence: sequence)
    }

    /// Only the two documented words mean something; anything else (a hub without management, a
    /// newer hub's word) is "the hub does not say".
    private static func managementSupport(_ value: String?) -> PowerBaseManagementSupport {
        switch value {
        case "supported": return .supported
        case "unsupported": return .unsupported
        default: return .unknown
        }
    }

    /// `nil` unless the hub offers settings sharing (`settings_api` 1). An unknown state is treated
    /// as unavailable rather than guessed.
    private static func hubSettingsSignal(_ dto: PogoSnapshotDTO) -> HubSettingsSignal? {
        guard dto.settingsAPI == 1 else { return nil }
        let state = dto.settingsState.flatMap(HubSettingsSignal.State.init(rawValue:)) ?? .unavailable
        return HubSettingsSignal(state: state, revision: state == .ready ? dto.settingsRevision : nil)
    }

    private static func validatedPowerBaseIdentifier(_ value: String) throws -> String {
        let raw = value.lowercased()
        guard ModuleIdentity.isValidRawIdentifier(raw) else {
            throw PogoAPIError.invalidPowerBaseIdentifier(value)
        }
        return raw
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
