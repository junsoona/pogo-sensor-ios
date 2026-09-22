import Foundation

nonisolated struct SensorModule: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let roomID: UUID
    let readings: [SensorReading]
    let isOnline: Bool
    let lastSeen: Date
    /// Optional human-readable role, e.g. "환경 모듈", shown as secondary text in lists.
    let roleDescription: String?

    init(
        id: UUID,
        name: String,
        roomID: UUID,
        readings: [SensorReading],
        isOnline: Bool,
        lastSeen: Date,
        roleDescription: String? = nil
    ) {
        self.id = id
        self.name = name
        self.roomID = roomID
        self.readings = readings
        self.isOnline = isOnline
        self.lastSeen = lastSeen
        self.roleDescription = roleDescription
    }

    var sortedReadings: [SensorReading] {
        readings.sorted { $0.kind.sortOrder < $1.kind.sortOrder }
    }

    var hasAttentionNeeded: Bool {
        !isOnline || readings.contains { $0.status.needsAttention }
    }
}
