import Foundation

nonisolated struct HomeSnapshot: Hashable, Sendable {
    let timestamp: Date
    let rooms: [Room]
    let modules: [SensorModule]

    var sortedRooms: [Room] {
        rooms.sorted { $0.sortOrder < $1.sortOrder }
    }

    func modules(in room: Room) -> [SensorModule] {
        modules.filter { $0.roomID == room.id }
    }

    func room(for module: SensorModule) -> Room? {
        rooms.first { $0.id == module.roomID }
    }

    /// `false` when there are no modules at all — an empty registry (e.g. mid-restart) is
    /// never "all online"; `allSatisfy` on an empty collection is vacuously `true`, which is
    /// exactly the trap this guards against.
    var allOnline: Bool {
        !modules.isEmpty && modules.allSatisfy(\.isOnline)
    }

    /// Whether every module that currently claims to be online has delivered at least one
    /// reading.  During Linux registry reconstruction topology arrives before samples, so
    /// `online == true` with an empty reading list is a transitional state, not proof that
    /// the sensor is ready.
    var onlineModulesHaveReadings: Bool {
        !modules.isEmpty && modules.allSatisfy { !$0.isOnline || !$0.readings.isEmpty }
    }

    var staleModules: [SensorModule] {
        modules.filter { module in
            module.readings.contains { $0.status == .stale }
        }
    }

    var modulesNeedingAttention: [SensorModule] {
        modules.filter(\.hasAttentionNeeded)
    }

    var allReadings: [SensorReading] {
        modules.flatMap(\.readings)
    }
}
