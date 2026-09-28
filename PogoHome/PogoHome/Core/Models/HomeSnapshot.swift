import Foundation

/// What a snapshot says about the hub's shared home settings (`settings_state`/`settings_revision`,
/// additive fields of `/api/v1/snapshot`). `nil` on `HomeSnapshot` means the source doesn't offer
/// settings sharing at all. Also compiled into the Watch app, which ignores it.
nonisolated struct HubSettingsSignal: Hashable, Sendable {
    enum State: String, Sendable {
        case ready
        case uninitialized
        case unavailable
    }

    let state: State
    let revision: String?
}

nonisolated struct HomeSnapshot: Hashable, Sendable {
    let timestamp: Date
    let rooms: [Room]
    let modules: [SensorModule]
    /// Every Power Base the bridge knows, in the bridge's order. Empty for a bridge that
    /// predates Power Base reporting — check `reportsPowerBases` before reading "no Bases".
    let powerBases: [PowerBase]
    /// Whether the data source reports Power Bases at all (the API's `power_bases` field was
    /// present). `false` means "unknown", never "none connected".
    let reportsPowerBases: Bool
    /// What the hub said about its shared home settings in this snapshot; `nil` for a source
    /// without settings sharing (simulated data, an older hub). See `SharedSettingsController`.
    let hubSettings: HubSettingsSignal?

    init(
        timestamp: Date,
        rooms: [Room],
        modules: [SensorModule],
        powerBases: [PowerBase] = [],
        reportsPowerBases: Bool = false,
        hubSettings: HubSettingsSignal? = nil
    ) {
        self.timestamp = timestamp
        self.rooms = rooms
        self.modules = modules
        self.powerBases = powerBases
        self.reportsPowerBases = reportsPowerBases
        self.hubSettings = hubSettings
    }

    func powerBase(for module: SensorModule) -> PowerBase? {
        guard let identifier = module.powerBaseIdentifier else { return nil }
        return powerBases.first { $0.hardwareIdentifier == identifier }
    }

    func modules(on powerBase: PowerBase) -> [SensorModule] {
        modules.filter { $0.powerBaseIdentifier == powerBase.hardwareIdentifier }
    }

    /// Modules not attributable to any listed Power Base (e.g. from an older bridge).
    var modulesWithoutPowerBase: [SensorModule] {
        let known = Set(powerBases.map(\.hardwareIdentifier))
        return modules.filter { module in
            guard let identifier = module.powerBaseIdentifier else { return true }
            return !known.contains(identifier)
        }
    }

    /// The Base's modules in POGO chain order — those docked on the Base first, then each
    /// module after its parent — following the bridge-reported `parentIdentifier` links, never
    /// guessed from depth. Modules whose parent isn't in the chain keep snapshot order at the end.
    func chainOrderedModules(on powerBase: PowerBase) -> [SensorModule] {
        let members = modules(on: powerBase)
        var ordered: [SensorModule] = []
        var placed: Set<String> = []
        var frontier: [String] = [powerBase.hardwareIdentifier]
        while !frontier.isEmpty {
            var next: [String] = []
            for parent in frontier {
                for module in members where module.parentIdentifier == parent {
                    guard let id = module.hardwareIdentifier, placed.insert(id).inserted else { continue }
                    ordered.append(module)
                    next.append(id)
                }
            }
            frontier = next
        }
        ordered += members.filter { module in
            guard let id = module.hardwareIdentifier else { return true }
            return !placed.contains(id)
        }
        return ordered
    }

    /// The module's POGO parent when that parent is another module in this snapshot.
    func parentModule(of module: SensorModule) -> SensorModule? {
        guard let parent = module.parentIdentifier, !module.isDirectlyOnPowerBase else { return nil }
        return modules.first { $0.hardwareIdentifier == parent }
    }

    /// The module is offline because the bridge lost its whole Power Base — not a fault of
    /// the module itself as far as anyone can tell.
    func isOfflineBecausePowerBaseIsOffline(_ module: SensorModule) -> Bool {
        guard !module.isOnline, let base = powerBase(for: module) else { return false }
        return !base.isOnline
    }

    var sortedRooms: [Room] {
        rooms.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Rooms to *render* in room lists (Rooms tab, Dashboard, room management) and to count.
    /// Display-only: the fallback "미지정 공간" is left out while no module is placed in it,
    /// but it stays in `rooms`, in persisted configuration, and in the sensor editor's room
    /// picker. Computed from `modules` exactly as displayed, so an offline module still in the
    /// snapshot keeps the room visible, and it reappears the moment any module lands there.
    var visibleRooms: [Room] {
        let showsUnspecifiedRoom = hasModulesInUnspecifiedRoom
        return sortedRooms.filter { $0.id != ModuleCatalog.unspecifiedRoomID || showsUnspecifiedRoom }
    }

    var hasModulesInUnspecifiedRoom: Bool {
        modules.contains { $0.roomID == ModuleCatalog.unspecifiedRoomID }
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
