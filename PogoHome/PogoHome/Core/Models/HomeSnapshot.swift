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

/// Where a snapshot stands among the snapshots of one run of the hub (`snapshot_stream`,
/// `snapshot_sequence` -- firmware repository, docs/pogohome-api-v1.md).
///
/// The hub makes its snapshots one at a time and numbers them as it does, whether they go out as
/// the answer to a `GET` or as an event. Of two snapshots of one stream, the one with the larger
/// sequence says nothing older than the other -- whichever arrives first. Two streams are two
/// runs of the hub (it was started again): their numbers say nothing about each other.
nonisolated struct HubSnapshotOrder: Hashable, Sendable {
    /// One value per run of the hub: 32 lower-case hex digits.
    let stream: String
    /// 1, 2, 3, ... in the order the hub made its snapshots.
    let sequence: Int64
}

/// How a snapshot got to the app -- **not part of what it says**. Two snapshots that say the
/// same are equal however they arrived, so this never takes part in comparing or hashing
/// (`HomeSnapshot` is compared to decide whether the screen has to change).
nonisolated struct SnapshotDelivery: Hashable, Sendable {
    /// Where the hub says the snapshot stands; `nil` from a hub that does not say.
    var hubOrder: HubSnapshotOrder?
    /// When this app **asked** for it: the ordinal of the request that brought it (the `GET`, or
    /// the event stream it arrived on) among this app's requests -- a later request has a larger
    /// one. Not a time. `nil` for a snapshot that came from no request (tests, simulated data).
    var requestOrdinal: UInt64?

    init(hubOrder: HubSnapshotOrder? = nil, requestOrdinal: UInt64? = nil) {
        self.hubOrder = hubOrder
        self.requestOrdinal = requestOrdinal
    }

    static func == (lhs: SnapshotDelivery, rhs: SnapshotDelivery) -> Bool { true }
    func hash(into hasher: inout Hasher) {}
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
    /// The hub's Power Base removal (unenroll) jobs: those still under way, and those that ended
    /// recently. Empty for a hub without Power Base management -- check
    /// `reportsPowerBaseManagement` before reading "no job".
    let powerBaseRemovals: [PowerBaseRemoval]
    /// Whether the hub offers Power Base management at all (the API's `power_base_removals` field
    /// was present). `false`: a Base cannot be removed through this hub, and the app says so
    /// instead of offering a removal that would only hide it.
    let reportsPowerBaseManagement: Bool
    /// The Power Bases the hub took out of its list recently ("허브 목록에서 제거"). Not removals:
    /// nothing here says a board was erased. Empty for a hub that cannot do that -- check
    /// `reportsPowerBaseForget`.
    let powerBaseForgets: [PowerBaseForget]
    /// Whether the hub can take an offline Power Base out of its list (the API's
    /// `power_base_forgets` field was present). `false`: the app does not offer it.
    let reportsPowerBaseForget: Bool
    /// The Power Bases the hub says are out of its list NOW: their registration ended and they
    /// have not been registered again. The hub's present state, in every snapshot for as long as
    /// it is so -- not history that is shown for a while. Empty for a hub that does not say;
    /// check `reportsPowerBaseDepartures`.
    let powerBaseDepartures: [PowerBaseDeparture]
    /// Whether the hub names the Bases that are out of its list (the API's
    /// `power_base_departures` field was present).
    let reportsPowerBaseDepartures: Bool
    /// How this snapshot arrived (see `SnapshotDelivery`): what `AppModel` needs to tell a
    /// snapshot that is older than one it already applied. Never compared.
    var delivery = SnapshotDelivery()

    init(
        timestamp: Date,
        rooms: [Room],
        modules: [SensorModule],
        powerBases: [PowerBase] = [],
        reportsPowerBases: Bool = false,
        hubSettings: HubSettingsSignal? = nil,
        powerBaseRemovals: [PowerBaseRemoval] = [],
        reportsPowerBaseManagement: Bool = false,
        powerBaseForgets: [PowerBaseForget] = [],
        reportsPowerBaseForget: Bool = false,
        powerBaseDepartures: [PowerBaseDeparture] = [],
        reportsPowerBaseDepartures: Bool = false,
        delivery: SnapshotDelivery = SnapshotDelivery()
    ) {
        self.timestamp = timestamp
        self.rooms = rooms
        self.modules = modules
        self.powerBases = powerBases
        self.reportsPowerBases = reportsPowerBases
        self.hubSettings = hubSettings
        self.powerBaseRemovals = powerBaseRemovals
        self.reportsPowerBaseManagement = reportsPowerBaseManagement
        self.powerBaseForgets = powerBaseForgets
        self.reportsPowerBaseForget = reportsPowerBaseForget
        self.powerBaseDepartures = powerBaseDepartures
        self.reportsPowerBaseDepartures = reportsPowerBaseDepartures
        self.delivery = delivery
    }

    /// The same snapshot, marked as the answer to the request with this ordinal.
    func requested(at ordinal: UInt64) -> HomeSnapshot {
        var copy = self
        copy.delivery.requestOrdinal = ordinal
        return copy
    }

    /// The removal job to show for a Base: the one that is not final if there is one, otherwise
    /// the one that ended last.
    ///
    /// For a Base the hub lists with its registration (`PowerBase.record`), only the jobs of that
    /// registration: a job the hub names another registration for is an earlier registration's,
    /// and never stands for the listed Base (or hides a job of its own).
    func removal(forPowerBase identifier: String) -> PowerBaseRemoval? {
        let listedRecord = powerBases.first { $0.hardwareIdentifier == identifier }?.record
        let own = powerBaseRemovals.filter { removal in
            guard removal.powerBaseIdentifier == identifier else { return false }
            guard let listedRecord, let record = removal.record else { return true }
            return record == listedRecord
        }
        return own.first { !$0.state.isFinal } ?? own.max { $0.updatedAt < $1.updatedAt }
    }

    /// Removal jobs for Bases the hub no longer lists (a Base that was removed, or one that has
    /// been silent since the hub restarted): they are still shown, so that a job the user started
    /// never just vanishes from the app.
    var removalsWithoutPowerBase: [PowerBaseRemoval] {
        let known = Set(powerBases.map(\.hardwareIdentifier))
        var seen: Set<String> = []
        return powerBaseRemovals
            .filter { !known.contains($0.powerBaseIdentifier) }
            .sorted { ($0.state.isFinal ? 1 : 0, $1.updatedAt) < ($1.state.isFinal ? 1 : 0, $0.updatedAt) }
            .filter { seen.insert($0.powerBaseIdentifier).inserted }
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
