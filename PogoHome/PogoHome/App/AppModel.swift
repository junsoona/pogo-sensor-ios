import Foundation
import Observation
import os

/// App-wide state, backed by whichever `SensorDataSource` the entry point injects.
/// Views read `snapshot`/`health` and never talk to a data source directly.
@MainActor
@Observable
final class AppModel {
    private(set) var snapshot: HomeSnapshot
    /// Last accepted sensor state before user names and room placement are overlaid.
    private var sourceSnapshot: HomeSnapshot
    private(set) var connectionStatus: DataSourceConnectionStatus = .idle
    private(set) var configurationError: String?
    /// When the app last heard anything from the data source — any `updates()` value,
    /// empty or not. `health` uses this as a freshness backstop independent of
    /// `connectionStatus`, in case a data source ever reports `.connected` without actually
    /// still delivering data.
    private(set) var lastSyncAt: Date?

    private var dataSource: SensorDataSource
    /// Which source `dataSource` reads — and so which source `sourceSnapshot`, `lastSyncAt` and
    /// the registry-recovery baseline belong to. Only a *different* source clears them
    /// (`replace(dataSource:identity:)`); the same source stopping and starting again keeps them.
    private(set) var sourceIdentity: SensorSourceIdentity
    /// Where `dataSource` connects to (`nil` for simulated data or an unidentified source). A new
    /// address under the same `sourceIdentity` — the chosen hub moved — reconnects without
    /// dropping anything (`replace(dataSource:identity:address:)`).
    private(set) var sourceAddress: URL?
    private let configurationStore: HomeConfigurationStore
    /// The language app-provided names (default rooms, suggestions, the default home name)
    /// are resolved in. Always the app's UI language outside tests.
    let language: AppLanguage
    /// This device's own settings (`configurationStore`). Never changed by settings sharing: while
    /// the app uses a hub's shared settings, this is the untouched copy that comes back when sharing
    /// is turned off.
    private var localConfiguration: HomeConfigurationSnapshot
    /// Settings shared through the hub the app follows. See `SharedSettingsController`.
    let sharedSettings: SharedSettingsController

    /// What every screen, the widgets and the Watch show: the hub's shared settings while this
    /// device uses them, otherwise the device's own.
    private var homeConfiguration: HomeConfigurationSnapshot {
        sharedSettings.activeConfiguration ?? localConfiguration
    }
    private var updatesTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    /// Independent of `updatesTask`/SSE entirely — see `SensorDataSource.periodicRefreshInterval`
    /// and `runPeriodicRefresh(source:interval:generation:)`. `nil` whenever the current data
    /// source opts out (its `periodicRefreshInterval` is `nil`, as `MockSensorDataSource`'s is).
    private var refreshTask: Task<Void, Never>?
    /// Bumped on every `stop()`. `updatesTask`/`statusTask`/`refreshTask` capture the
    /// generation that was current when they started and stop applying anything as soon as
    /// it no longer matches — guards against a just-replaced data source's in-flight
    /// callback (already requested to cancel, but not yet actually torn down) overwriting
    /// the new data source's status or snapshot.
    private var connectionGeneration = 0
    /// Consecutive failed periodic refreshes, used only to rate-limit failure logging —
    /// never affects retry timing or the snapshot on screen.
    private var periodicRefreshFailureStreak = 0
    /// The `(module count, complete)` pair last written by a "periodic refresh received"
    /// log, used only to suppress logging an unchanged result again — every steady-state
    /// tick that finds nothing new would otherwise log identically every interval forever.
    /// Never read for anything but this comparison; `applyIncoming`'s own state
    /// (`completeModuleIDs`/`isRegistryRecovering`) is what actually governs behavior.
    private var lastLoggedPeriodicRefreshResult: (moduleCount: Int, complete: Bool)?

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.junsoona.PogoHome",
        category: "AppModel"
    )
    /// Module identities from the last snapshot whose online modules all had readings.
    /// The Linux registry retains removed/detached modules as explicit offline entries, so
    /// a strict subset during process restart is recovery progress rather than removal.
    private var completeModuleIDs: Set<UUID> = []
    private(set) var isRegistryRecovering = false

    init(
        dataSource: SensorDataSource,
        sourceIdentity: SensorSourceIdentity = .unique(),
        sourceAddress: URL? = nil,
        initialSnapshot: HomeSnapshot? = nil,
        configurationStore: HomeConfigurationStore? = nil,
        configurationStoreLaunchError: String? = nil,
        sharedSettings: SharedSettingsController? = nil,
        language: AppLanguage = .current
    ) {
        self.dataSource = dataSource
        self.sourceIdentity = sourceIdentity
        self.sourceAddress = sourceAddress
        self.language = language
        let initial = initialSnapshot ?? HomeSnapshot(timestamp: Date(), rooms: [], modules: [])
        self.sourceSnapshot = initial
        self.snapshot = initial
        // A nil store keeps legacy/unit-test construction source-backed. The real app and
        // previews inject an explicit persistent/in-memory configuration store.
        let resolvedStore = configurationStore ?? InMemoryHomeConfigurationStore(rooms: [], language: language)
        self.configurationStore = resolvedStore
        // Surfaces a failure to even construct the persistent store (e.g. `PogoHomeApp`
        // falling back to an in-memory store) so it isn't silently swallowed — see Settings.
        self.configurationError = configurationStoreLaunchError
        do {
            self.localConfiguration = try resolvedStore.load()
        } catch {
            self.localConfiguration = HomeConfigurationSnapshot(rooms: HomeConfigurationDefaults.rooms(in: language), modules: [:])
            self.configurationError = error.localizedDescription
        }
        // Tests and previews get a controller that can't reach any hub unless they pass one.
        self.sharedSettings = sharedSettings ?? SharedSettingsController(
            credentials: InMemoryHubCredentialStore(),
            cache: InMemorySharedSettingsCache(),
            language: language
        )
        self.snapshot = Self.apply(localConfiguration, to: initial)
        if initial.onlineModulesHaveReadings {
            self.completeModuleIDs = Set(initial.modules.map(\.id))
        }
        self.sharedSettings.sourceSnapshot = { [weak self] in
            self?.sourceSnapshot ?? HomeSnapshot(timestamp: Date(), rooms: [], modules: [])
        }
        self.sharedSettings.onConfigurationChange = { [weak self] in
            self?.configurationDidChange()
        }
        self.sharedSettings.sourceDidChange(hubID: sourceIdentity.hubID, baseURL: sourceAddress)
    }

    /// The Dashboard's connection/health verdict — see `HomeHealthEvaluator`.
    var health: HomeHealthState {
        HomeHealthEvaluator.evaluate(
            snapshot: snapshot,
            connectionStatus: connectionStatus,
            lastSyncAt: lastSyncAt,
            isRegistryRecovering: isRegistryRecovering
        )
    }

    /// While there are no modules at all: whether the source is still being reached, can't be
    /// reached, or answered without data yet. `nil` once any module is on screen.
    var dataWait: HomeDataWait? {
        HomeHealthEvaluator.dataWait(snapshot: snapshot, connectionStatus: connectionStatus)
    }

    /// Begins listening for snapshot updates. Idempotent: call from the root view's
    /// `.task` modifier without worrying about duplicate update loops across tab switches.
    ///
    /// Deliberately consumes only `updates()`, not `currentSnapshot()` as well: a data
    /// source's `updates()` is expected to deliver its current state as its first element
    /// (both `LiveSensorDataSource` and `MockSensorDataSource` do), so calling both here
    /// would mean two redundant fetches on every `start()` for `LiveSensorDataSource`
    /// (`currentSnapshot()`'s own GET, plus the GET `updates()` performs before opening its
    /// SSE connection) racing to set `snapshot` first.
    func start() {
        guard updatesTask == nil else { return }
        // Changes another device made while this one was in the background.
        sharedSettings.resume()
        let source = dataSource
        let generation = connectionGeneration
        updatesTask = Task { [weak self] in
            guard let self else { return }
            for await next in source.updates() {
                guard self.connectionGeneration == generation else { break }
                self.applyIncoming(next)
            }
        }
        statusTask = Task { [weak self] in
            guard let self else { return }
            for await status in source.connectionStatusUpdates() {
                guard self.connectionGeneration == generation else { break }
                self.connectionStatus = status
                self.sharedSettings.connectionStatusDidChange(status)
            }
        }
        if let interval = source.periodicRefreshInterval {
            periodicRefreshFailureStreak = 0
            lastLoggedPeriodicRefreshResult = nil
            refreshTask = Task { [weak self] in
                guard let self else { return }
                await self.runPeriodicRefresh(source: source, interval: interval, generation: generation)
            }
        }
    }

    /// Stops listening. `snapshot` is deliberately left as-is (the last good value stays on
    /// screen); only `connectionStatus` moves to `.idle` to reflect that nothing is live. This is
    /// the same source pausing (the app going to the background) — switching to another source
    /// goes through `replace(dataSource:identity:)`, which also clears its data.
    func stop() {
        connectionGeneration += 1
        updatesTask?.cancel()
        updatesTask = nil
        statusTask?.cancel()
        statusTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        connectionStatus = .idle
    }

    /// Swaps in a new data source, cancelling and cleaning up the old one first, then
    /// starting exactly one fresh connection — used when Settings changes the data source
    /// mode or the live URL.
    ///
    /// A different source (simulated ↔ live, or another hub) starts from nothing: the old
    /// source's modules, readings, last sync time and recovery baseline are dropped at once, so
    /// nothing it said is ever shown as the new source's — the screen says "connecting",
    /// "waiting for data" or "can't connect" until the new source itself delivers. The user's
    /// home name, rooms and device names/placement are configuration, not source data, and stay.
    ///
    /// `identity` equal to the current one (a Settings edit that still resolves to the same hub,
    /// or the same change reported by a second window) changes nothing: the running connection
    /// and its last values stay. `nil` means an unidentified source, never the same as another.
    ///
    /// The same `identity` at a different `address` is the same hub reached somewhere else (a hub
    /// picked in "Find hubs" whose address changed): the connection moves to `newDataSource`, and
    /// the modules, readings, last sync time and recovery baseline stay — their freshness keeps
    /// being judged by `lastSyncAt`, exactly as while reconnecting to the old address.
    ///
    /// Moving between a typed address and the hub found at that same address (or back) keeps the
    /// running connection and its values too: they already came from that address. Only the
    /// identity they are filed under changes. Two different `hub_id`s are always two sources,
    /// even at one address.
    func replace(dataSource newDataSource: SensorDataSource, identity: SensorSourceIdentity? = nil, address: URL? = nil) {
        if let identity, identity != sourceIdentity, identity.isHub, sourceIdentity.isHub,
           (identity.hubID == nil) != (sourceIdentity.hubID == nil),
           let address, let sourceAddress, SensorSourceIdentity.hub(address) == SensorSourceIdentity.hub(sourceAddress) {
            Self.logger.notice("same address, now identified as \(identity.rawValue, privacy: .public)")
            sourceIdentity = identity
            sharedSettings.sourceDidChange(hubID: identity.hubID, baseURL: address)
            return
        }
        if let identity, identity == sourceIdentity {
            guard address != sourceAddress else { return }
            Self.logger.notice("same source at a new address: \(address?.absoluteString ?? "none", privacy: .public)")
            stop()
            dataSource = newDataSource
            sourceAddress = address
            sharedSettings.sourceDidChange(hubID: sourceIdentity.hubID, baseURL: address)
            start()
            return
        }
        stop()
        dataSource = newDataSource
        sourceIdentity = identity ?? .unique()
        sourceAddress = address
        clearSourceData()
        // Another source: another hub's shared settings (or none) — never this one's.
        sharedSettings.sourceDidChange(hubID: sourceIdentity.hubID, baseURL: address)
        start()
    }

    /// Forgets everything the previous source delivered. Only for a source change — a pause of
    /// the same source (`stop()`) keeps it all.
    private func clearSourceData() {
        let empty = HomeSnapshot(timestamp: Date(), rooms: [], modules: [])
        sourceSnapshot = empty
        snapshot = Self.apply(homeConfiguration, to: empty)
        lastSyncAt = nil
        completeModuleIDs = []
        isRegistryRecovering = false
        periodicRefreshFailureStreak = 0
        lastLoggedPeriodicRefreshResult = nil
    }

    /// `source` with the user's names and room placement, exactly as `snapshot` would show it —
    /// for a snapshot fetched outside the live connection (the Apple Watch's refresh request).
    func applyingConfiguration(to source: HomeSnapshot) -> HomeSnapshot {
        Self.apply(homeConfiguration, to: source)
    }

    func module(with id: UUID) -> SensorModule? {
        snapshot.modules.first { $0.id == id }
    }

    func room(with id: UUID) -> Room? {
        snapshot.rooms.first { $0.id == id }
    }

    var editableRooms: [Room] {
        homeConfiguration.rooms.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// The gray placeholder the room editor shows for `symbolName` while its name field is
    /// empty — and exactly the name it saves in that case. See `RoomNameSuggestion`.
    func suggestedRoomName(for symbolName: String, excludingRoomID: UUID? = nil) -> String {
        suggestedRoomNameSource(for: symbolName, excludingRoomID: excludingRoomID).displayName(in: language)
    }

    /// `suggestedRoomName`, as the app-provided name source the editor saves when its field is
    /// left empty (so the saved name keeps following the app language).
    func suggestedRoomNameSource(for symbolName: String, excludingRoomID: UUID? = nil) -> RoomNameSource {
        RoomNameSuggestion.availableSource(
            for: symbolName,
            existingRooms: editableRooms,
            excludingRoomID: excludingRoomID,
            language: language
        )
    }

    /// The Dashboard title: the user's own home name, or the localized default ("우리 집").
    /// PogoHome-only — never read from or written to Apple Home.
    var homeName: String {
        homeConfiguration.customHomeName ?? defaultHomeName
    }

    var defaultHomeName: String {
        HomeConfigurationDefaults.homeName(in: language)
    }

    var customHomeName: String? {
        homeConfiguration.customHomeName
    }

    /// Whether the settings on screen can be changed right now. Always true for the device's own
    /// settings; while sharing, only when the hub is reachable and has confirmed the copy on screen.
    var canEditConfiguration: Bool { sharedSettings.canEdit }

    /// Why editing is off right now (shown under the disabled controls).
    var configurationEditBlockedReason: String? { sharedSettings.editBlockedReason }

    /// Whether the settings on screen are the hub's shared settings.
    var usesSharedSettings: Bool { sharedSettings.isActive }

    /// Recorded by an editor when it shows the current values (on opening, and again after a
    /// conflict), and passed back with its save: while sharing, the save is refused instead of
    /// sent when a newer copy arrived meanwhile. See `SharedSettingsController.performEdit`.
    var configurationEditBase: ConfigurationEditBase { .revision(sharedSettings.entry?.revision) }

    /// This device's own settings, whether or not they are on screen (see `localConfiguration`).
    var deviceConfiguration: HomeConfigurationSnapshot { localConfiguration }

    /// The current source's sensor state, before names and rooms are applied.
    var sensorSnapshot: HomeSnapshot { sourceSnapshot }

    /// Saves the home-name editor's field: empty (or the default name itself) goes back to the
    /// localized default; anything else is stored verbatim. See `HomeNameInput`.
    func updateHomeName(input: String, basedOn base: ConfigurationEditBase = .current) async throws {
        let customName = HomeNameInput.customName(input: input, defaultName: defaultHomeName)
        try await editConfiguration(basedOn: base) { store in try store.updateHomeName(customName) }
    }

    /// The user's persisted custom name for a module, or `nil` when it shows its product name.
    func customName(forModule id: UUID) -> String? {
        homeConfiguration.modules[id]?.customName
    }

    /// A room with a user-typed name.
    @discardableResult
    func createRoom(name: String, symbolName: String) async throws -> Room {
        try await createRoom(nameSource: .custom(name), symbolName: symbolName)
    }

    @discardableResult
    func createRoom(nameSource: RoomNameSource, symbolName: String) async throws -> Room {
        try await editConfiguration { store in try store.createRoom(nameSource: nameSource, symbolName: symbolName) }
    }

    func updateRoom(id: UUID, name: String, symbolName: String) async throws {
        try await updateRoom(id: id, nameSource: .custom(name), symbolName: symbolName)
    }

    func updateRoom(id: UUID, nameSource: RoomNameSource, symbolName: String, basedOn base: ConfigurationEditBase = .current) async throws {
        try await editConfiguration(basedOn: base) { store in try store.updateRoom(id: id, nameSource: nameSource, symbolName: symbolName) }
    }

    /// Its modules move to "미지정 공간" in the same change.
    func deleteRoom(id: UUID, basedOn base: ConfigurationEditBase = .current) async throws {
        try await editConfiguration(basedOn: base) { store in try store.deleteRoom(id: id) }
    }

    /// `orderedIDs` is the user's desired order for every *non-fallback* room; the
    /// fallback ("미지정 공간") room is never included and always sorts last regardless of
    /// what is passed here — see `HomeConfigurationStore.reorderRooms`.
    func reorderRooms(orderedIDs: [UUID], basedOn base: ConfigurationEditBase = .current) async throws {
        try await editConfiguration(basedOn: base) { store in try store.reorderRooms(orderedIDs: orderedIDs) }
    }

    func updateModule(id: UUID, customName: String?, roomID: UUID, basedOn base: ConfigurationEditBase = .current) async throws {
        guard sourceSnapshot.modules.contains(where: { $0.id == id }) else {
            throw HomeConfigurationError.moduleNotFound
        }
        try await editConfiguration(basedOn: base) { store in try store.updateModule(id: id, customName: customName, roomID: roomID) }
    }

    /// One change to the settings on screen: through the hub while sharing (done once the hub has
    /// stored it), otherwise straight into this device's store. Both check it the same way. `base`
    /// only matters while sharing: this device's own settings change nowhere else.
    private func editConfiguration<T>(basedOn base: ConfigurationEditBase = .current, _ edit: (HomeConfigurationStore) throws -> T) async throws -> T {
        if sharedSettings.isActive {
            // Errors (a duplicate name, a conflict, the hub offline) are shown by the editor that
            // made the change; nothing about this device's own storage went wrong.
            return try await sharedSettings.performEdit(basedOn: base, edit)
        }
        do {
            let result = try edit(configurationStore)
            try reloadConfiguration()
            return result
        } catch {
            configurationError = error.localizedDescription
            throw error
        }
    }

    func clearConfigurationError() {
        configurationError = nil
    }

    /// Applies one incoming snapshot from the data source — the single application path for
    /// both `updates()` and `runPeriodicRefresh(source:interval:generation:)`, so recovery
    /// via polling follows exactly the same merge policy as recovery via a pushed update.
    ///
    /// Per the PogoHome API v1 contract (see `docs/pogohome-api-v1.md` and the
    /// `ingest::Registry` it mirrors), a snapshot's `modules` array is always the complete,
    /// authoritative membership for that generation: a module that is merely offline
    /// (unreachable, rebooting, a transient radio/service hiccup) stays IN the array with
    /// `online == false`; a module is absent from the array only once the Linux Registry has
    /// actually torn it down (a confirmed POGO detach). So a *complete* incoming snapshot —
    /// every currently-present online module already has at least one reading — is applied
    /// immediately regardless of whether it is smaller than the last complete snapshot: a
    /// shrunk-but-complete snapshot means a real removal, not a communication gap, and must
    /// be reflected on screen right away (a module reappearing later under the same UUID is
    /// just a fresh incoming snapshot like any other, and the overlay in `apply(_:to:)` below
    /// restores its saved name/room automatically since that configuration is never deleted).
    ///
    /// The only thing ever held back once a complete baseline exists is genuinely
    /// *incomplete* data — an online module topology has just been (re)established for,
    /// before its first sample has arrived, reports an empty `readings` array, which is a
    /// transitional per-module state, not proof anything was removed. Before any complete
    /// baseline exists yet (cold start), incomplete progress is still shown (so first-boot
    /// topology-before-sample state is visible) rather than held.
    private func applyIncoming(_ incoming: HomeSnapshot) {
        lastSyncAt = Date()
        // Read even from a snapshot held back below: the settings revision is independent of
        // registry recovery.
        sharedSettings.observe(incoming.hubSettings)

        let incomingIDs = Set(incoming.modules.map(\.id))
        let incomingIsComplete = incoming.onlineModulesHaveReadings

        if !completeModuleIDs.isEmpty && !incomingIsComplete {
            if !isRegistryRecovering {
                Self.logger.notice(
                    "registry recovery entered: \(incoming.modules.count, privacy: .public) module(s), complete=\(incomingIsComplete, privacy: .public)"
                )
            }
            isRegistryRecovering = true
            return
        }

        sourceSnapshot = incoming
        snapshot = Self.apply(homeConfiguration, to: incoming)
        if incomingIsComplete {
            completeModuleIDs = incomingIDs
            if isRegistryRecovering {
                Self.logger.notice(
                    "registry recovery cleared: \(incoming.modules.count, privacy: .public) module(s), all with readings"
                )
            }
            isRegistryRecovering = false
        } else {
            // With no complete baseline yet, showing topology progress is useful, but it is
            // still waiting-for-data rather than a healthy home.
            isRegistryRecovering = !incoming.modules.isEmpty
        }
    }

    /// Independently re-fetches `source.currentSnapshot()` every `interval` seconds for the
    /// lifetime of one `start()`/`stop()` cycle, layered on top of (never replacing)
    /// `updates()`. This is what lets recovery converge even when the live connection never
    /// delivers another usable signal that it has — see `SensorDataSource.periodicRefreshInterval`.
    ///
    /// Every result — success or failure — is checked against `generation` before touching
    /// any state, exactly like `updatesTask`/`statusTask` in `start()`, so a tick from a
    /// since-stopped/replaced data source can never land. A failed fetch only logs
    /// (rate-limited) and waits for the next tick: it must never clear the last known-good
    /// snapshot, retry faster, or spin up a competing reconnect mechanism — `LiveSensorDataSource`'s
    /// own SSE reconnect/backoff state machine is untouched by this loop.
    private func runPeriodicRefresh(source: SensorDataSource, interval: Double, generation: Int) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return
            }
            guard connectionGeneration == generation else {
                Self.logger.debug("periodic refresh: discarding tick from a stale generation")
                return
            }

            do {
                let refreshed = try await source.currentSnapshot()
                guard connectionGeneration == generation else {
                    Self.logger.debug("periodic refresh: discarding result from a stale generation")
                    return
                }
                if periodicRefreshFailureStreak > 0 {
                    Self.logger.notice(
                        "periodic refresh recovered after \(self.periodicRefreshFailureStreak, privacy: .public) failed attempt(s)"
                    )
                    periodicRefreshFailureStreak = 0
                }
                logPeriodicRefreshResultIfChanged(refreshed)
                applyIncoming(refreshed)
            } catch {
                periodicRefreshFailureStreak += 1
                // Rate-limited: always log the first failure of a streak, then no more than
                // roughly once a minute while it continues, instead of once per tick — a
                // steady-state failure (e.g. the hub genuinely unreachable) must never spam
                // one line every 5s.
                if periodicRefreshFailureStreak == 1 || Double(periodicRefreshFailureStreak) * interval >= 60 {
                    Self.logger.error(
                        "periodic refresh failed (streak=\(self.periodicRefreshFailureStreak, privacy: .public)): \(String(describing: error), privacy: .public)"
                    )
                    if Double(periodicRefreshFailureStreak) * interval >= 60 {
                        periodicRefreshFailureStreak = 0
                    }
                }
            }
        }
    }

    /// Logs a periodic-refresh result only when it differs from the last one logged — a
    /// steady healthy state (or a steady recovering state that isn't itself progressing)
    /// would otherwise log an identical line every `interval` seconds forever. This is
    /// purely a logging decision: `applyIncoming(_:)` below still runs on every tick
    /// regardless of whether this logs anything.
    private func logPeriodicRefreshResultIfChanged(_ incoming: HomeSnapshot) {
        let result = (moduleCount: incoming.modules.count, complete: incoming.onlineModulesHaveReadings)
        guard lastLoggedPeriodicRefreshResult.map({ $0 != result }) ?? true else { return }
        lastLoggedPeriodicRefreshResult = result
        Self.logger.debug(
            "periodic refresh received \(result.moduleCount, privacy: .public) module(s), complete=\(result.complete, privacy: .public)"
        )
    }

    private func reloadConfiguration() throws {
        localConfiguration = try configurationStore.load()
        configurationError = nil
        snapshot = Self.apply(homeConfiguration, to: sourceSnapshot)
    }

    /// The shared settings in use changed (confirmed by the hub, another device's change, sharing
    /// turned on or off, another hub): every screen, the widgets and the Watch follow `snapshot`.
    private func configurationDidChange() {
        snapshot = Self.apply(homeConfiguration, to: sourceSnapshot)
    }

    /// Applies only user-facing metadata. Sensor readings, online state, timestamps and
    /// roles always come from `source` unchanged.
    private nonisolated static func apply(
        _ configuration: HomeConfigurationSnapshot,
        to source: HomeSnapshot
    ) -> HomeSnapshot {
        guard !configuration.rooms.isEmpty else { return source }
        let roomIDs = Set(configuration.rooms.map(\.id))
        let fallbackID = ModuleCatalog.unspecifiedRoomID
        let modules = source.modules.map { module in
            let preference = configuration.modules[module.id]
            let preferredRoomID = preference?.roomID ?? module.roomID
            let roomID = roomIDs.contains(preferredRoomID) ? preferredRoomID : fallbackID
            return SensorModule(
                id: module.id,
                name: preference?.customName ?? module.hardwareName,
                hardwareName: module.hardwareName,
                hardwareIdentifier: module.hardwareIdentifier,
                roomID: roomID,
                readings: module.readings,
                isOnline: module.isOnline,
                lastSeen: module.lastSeen,
                roleDescription: module.roleDescription,
                powerBaseIdentifier: module.powerBaseIdentifier,
                parentIdentifier: module.parentIdentifier
            )
        }
        return HomeSnapshot(
            timestamp: source.timestamp,
            rooms: configuration.rooms.sorted { $0.sortOrder < $1.sortOrder },
            modules: modules,
            powerBases: source.powerBases,
            reportsPowerBases: source.reportsPowerBases,
            hubSettings: source.hubSettings
        )
    }
}

extension AppModel {
    /// A deterministic instance for SwiftUI previews; never starts its update loop, but is
    /// seeded as already-connected so previews show the healthy state by default instead of
    /// the "reconnecting" banner an unstarted `AppModel` would otherwise report.
    static var preview: AppModel {
        let model = AppModel(
            dataSource: MockSensorDataSource(),
            initialSnapshot: MockSensorFixtures.previewSnapshot,
            configurationStore: InMemoryHomeConfigurationStore()
        )
        model.connectionStatus = .connected
        model.lastSyncAt = Date()
        return model
    }
}
