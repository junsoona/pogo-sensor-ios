import Foundation

nonisolated struct SensorModule: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    /// Name derived from the hardware catalog. User customization changes `name` only.
    let hardwareName: String
    /// Raw hexadecimal identifier sent by the PogoHome API, when available.
    let hardwareIdentifier: String?
    let roomID: UUID
    let readings: [SensorReading]
    let representativeSensorKind: SensorKind?
    let isOnline: Bool
    let lastSeen: Date
    /// Optional human-readable role, e.g. "환경 모듈", shown as secondary text in lists.
    let roleDescription: String?
    /// Raw identifier of the Power Base this module is docked under, as the bridge reports it.
    /// `nil` when the bridge predates Power Base reporting (or for mock data).
    let powerBaseIdentifier: String?
    /// Raw identifier of the module's POGO parent: the Power Base itself for a directly docked
    /// module, otherwise the upstream module. `nil` when the bridge doesn't report it.
    let parentIdentifier: String?

    init(
        id: UUID,
        name: String,
        hardwareName: String? = nil,
        hardwareIdentifier: String? = nil,
        roomID: UUID,
        readings: [SensorReading],
        representativeSensorKind: SensorKind? = nil,
        isOnline: Bool,
        lastSeen: Date,
        roleDescription: String? = nil,
        powerBaseIdentifier: String? = nil,
        parentIdentifier: String? = nil
    ) {
        self.id = id
        self.name = name
        self.hardwareName = hardwareName ?? name
        self.hardwareIdentifier = hardwareIdentifier
        self.roomID = roomID
        self.readings = readings
        self.representativeSensorKind = representativeSensorKind
        self.isOnline = isOnline
        self.lastSeen = lastSeen
        self.roleDescription = roleDescription
        self.powerBaseIdentifier = powerBaseIdentifier
        self.parentIdentifier = parentIdentifier
    }

    /// Docked straight onto its Power Base rather than behind another module.
    var isDirectlyOnPowerBase: Bool {
        guard let powerBaseIdentifier, let parentIdentifier else { return false }
        return powerBaseIdentifier == parentIdentifier
    }

    var representativeSensorSymbolName: String {
        let kind = representativeSensorKind ?? readings.min { $0.kind.sortOrder < $1.kind.sortOrder }?.kind
        return kind?.symbolName ?? "sensor.fill"
    }

    var sortedReadings: [SensorReading] {
        readings.sorted { $0.kind.sortOrder < $1.kind.sortOrder }
    }

    var hasAttentionNeeded: Bool {
        !isOnline || readings.contains { $0.status.needsAttention }
    }
}
