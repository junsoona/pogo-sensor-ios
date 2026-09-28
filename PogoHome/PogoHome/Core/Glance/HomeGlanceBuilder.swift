import Foundation

/// Turns the app's live POGO and Apple Home state into the next `HomeGlanceSnapshot`, merged
/// with the one written before.
///
/// Each source's section is rewritten only from a *conclusive* state of that source, and is
/// otherwise carried over unchanged from `previous`:
///
/// - POGO: rewritten once a complete snapshot has arrived in this app session (`lastSyncAt` ≥
///   `sessionStartedAt`); marked unverified (values kept) when the connection fails or the
///   bridge's registry is incomplete. Launching, returning from the background and connecting
///   are not a verdict, so they never replace the last confirmed state with an empty one — and
///   only a complete snapshot can make a value disappear (a deleted/detached module). The
///   previous POGO part is used only if it came from the same source (`SensorSourceIdentity`):
///   after a switch between simulated and live data, or to another hub, nothing of the old
///   source is carried over — not even as unverified — until the new one delivers.
/// - Apple Home: rewritten when PogoHome reads Apple Home with access (`.ready`) and cleared —
///   devices and values dropped — as soon as Apple Home is turned off in PogoHome or access is
///   denied/restricted/unavailable/without a home. `.loading` keeps what was there.
///
/// Confirmation times only move forward on confirmation: while a source or device can't be
/// confirmed its `verifiedAt`/`checkedAt` stay at the last confirmed moment.
nonisolated enum HomeGlanceBuilder {
    struct PogoInput: Sendable {
        let snapshot: HomeSnapshot
        let health: HomeHealthState
        let connectionStatus: DataSourceConnectionStatus
        let lastSyncAt: Date?
        let isSimulated: Bool
        /// When the app (re)started listening; data older than this is from an earlier session.
        let sessionStartedAt: Date
        /// Where `snapshot` comes from. A previous POGO part from another source is never reused.
        let source: SensorSourceIdentity
    }

    struct AppleHomeInput: Sendable {
        let isEnabled: Bool
        let accessState: AppleHomeAccessState
        /// The accessories the Dashboard lists — `DeviceDirectory`'s visible ones, i.e. without
        /// Apple Home entries the user marked as the same device as a POGO module.
        let visibleAccessories: [AppleHomeAccessory]
    }

    static func build(
        homeName: String,
        pogo: PogoInput,
        appleHome: AppleHomeInput,
        previous: HomeGlanceSnapshot?,
        now: Date
    ) -> HomeGlanceSnapshot {
        let (pogoSection, pogoSensors) = pogoPart(pogo, previous: previous)
        let (appleHomeSection, appleHomeSensors) = appleHomePart(appleHome, previous: previous, now: now)
        return HomeGlanceSnapshot(
            writtenAt: now,
            homeName: homeName,
            pogo: pogoSection,
            appleHome: appleHomeSection,
            sensors: pogoSensors + appleHomeSensors
        )
    }

    // MARK: - POGO

    static func pogoPart(_ input: PogoInput, previous: HomeGlanceSnapshot?) -> (HomeGlancePogoSection, [HomeGlanceSensor]) {
        let hasSessionData = input.lastSyncAt.map { $0 >= input.sessionStartedAt } ?? false
        // Another source's values are not this source's last known state.
        let previous = previous.flatMap { $0.pogo.isFrom(input.source) ? $0 : nil }
        let previousSection = previous?.pogo ?? .empty(from: input.source)
        let previousSensors = previous?.pogoSensors ?? []
        // The last confirmed data stays, but is no longer presented as confirmed.
        let keptUnverified: (HomeGlancePogoSection, [HomeGlanceSensor]) = {
            var section = previousSection
            if section.state != .waitingForData { section.state = .unverified }
            return (section, previousSensors)
        }()

        guard hasSessionData else {
            switch input.connectionStatus {
            case .reconnecting, .failed:
                // Couldn't reach the bridge in this session.
                return keptUnverified
            case .idle, .connecting, .connected:
                return (previousSection, previousSensors)
            }
        }

        let snapshot = input.snapshot
        // Only a complete snapshot (every online module has readings) is the bridge's full
        // module list — `AppModel` applies the same rule. An empty or half-built registry (bridge
        // restart, first samples still missing) must not make stored values look deleted.
        guard snapshot.onlineModulesHaveReadings else {
            return previous == nil ? (.empty(from: input.source), []) : keptUnverified
        }

        let isVerified = input.health.isCurrentStateVerified
        let verifiedAt = isVerified ? input.lastSyncAt : previousSection.verifiedAt
        let section = HomeGlancePogoSection(
            state: state(for: input.health),
            verifiedAt: verifiedAt,
            moduleCount: snapshot.modules.count,
            onlineCount: snapshot.modules.filter(\.isOnline).count,
            attention: snapshot.modulesNeedingAttention.map { module in
                HomeGlanceAttentionItem(device: .pogoModule(module.id), name: module.name, reason: attentionReason(module))
            },
            isSimulated: input.isSimulated,
            sourceID: input.source.rawValue
        )

        let previousCheckedAt = Dictionary(previousSensors.map { ($0.id, $0.checkedAt) }, uniquingKeysWith: { first, _ in first })
        let sensors = orderedModules(snapshot).flatMap { module in
            module.sortedReadings.map { reading -> HomeGlanceSensor in
                let id = HomeGlanceValueID.pogo(module: module.id, kind: reading.kind)
                // Only a reading from an online module over a confirmed connection counts as
                // checked now; anything else keeps the time it was last confirmed.
                let checkedAt = isVerified && module.isOnline ? input.lastSyncAt : previousCheckedAt[id] ?? nil
                return HomeGlanceSensor(
                    id: id,
                    deviceName: module.name,
                    roomName: snapshot.room(for: module)?.name,
                    kindRawValue: reading.kind.rawValue,
                    value: reading.value,
                    status: status(for: reading.status),
                    isDeviceConnected: module.isOnline,
                    checkedAt: checkedAt
                )
            }
        }
        return (section, sensors)
    }

    static func state(for health: HomeHealthState) -> HomeGlancePogoState {
        switch health {
        case .waitingForData: return .waitingForData
        case .reconnecting, .recoveringRegistry: return .unverified
        case .healthy: return .healthy
        case .attentionNeeded: return .attentionNeeded
        }
    }

    static func status(for status: SensorStatus) -> HomeGlanceValueStatus {
        switch status {
        case .normal: return .normal
        case .conditioning: return .conditioning
        case .stale: return .stale
        case .unavailable: return .unavailable
        case .error: return .error
        }
    }

    private static func attentionReason(_ module: SensorModule) -> HomeGlanceAttentionReason {
        if !module.isOnline { return .offline }
        if module.readings.contains(where: { $0.status == .stale }) { return .stale }
        if module.readings.contains(where: { $0.status == .error }) { return .error }
        return .unavailable
    }

    /// Rooms in the user's order, then modules by name — the order a value picker lists them.
    private static func orderedModules(_ snapshot: HomeSnapshot) -> [SensorModule] {
        let roomOrder = Dictionary(snapshot.rooms.map { ($0.id, $0.sortOrder) }, uniquingKeysWith: { first, _ in first })
        return snapshot.modules.sorted { a, b in
            let orderA = roomOrder[a.roomID] ?? .max
            let orderB = roomOrder[b.roomID] ?? .max
            if orderA != orderB { return orderA < orderB }
            switch a.name.localizedStandardCompare(b.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.id.uuidString < b.id.uuidString
            }
        }
    }

    // MARK: - Apple Home

    static func appleHomePart(
        _ input: AppleHomeInput,
        previous: HomeGlanceSnapshot?,
        now: Date
    ) -> (HomeGlanceAppleHomeSection, [HomeGlanceSensor]) {
        guard input.isEnabled else { return (.off, []) }
        let cleared = { (access: HomeGlanceAppleHomeAccess) in
            (HomeGlanceAppleHomeSection(access: access, verifiedAt: nil, accessoryCount: 0, notRespondingCount: 0), [HomeGlanceSensor]())
        }
        switch input.accessState {
        case .denied: return cleared(.denied)
        case .restricted: return cleared(.restricted)
        case .unsupported: return cleared(.unsupported)
        case .noHome: return cleared(.noHome)
        case .off, .loading:
            // Turned on but not (yet) answered: neither confirms nor revokes anything.
            return (previous?.appleHome ?? .off, previous?.appleHomeSensors ?? [])
        case .ready:
            let accessories = input.visibleAccessories
            let section = HomeGlanceAppleHomeSection(
                access: .ready,
                verifiedAt: now,
                accessoryCount: accessories.count,
                notRespondingCount: accessories.filter { !$0.isOperable }.count
            )
            return (section, accessories.flatMap(sensors(of:)))
        }
    }

    /// The accessory's readable values that the app lists as values (not as controls).
    static func sensors(of accessory: AppleHomeAccessory) -> [HomeGlanceSensor] {
        accessory.services
            .filter { $0.kind != .accessoryInformation }
            .flatMap { service in
                service.characteristics.compactMap { characteristic -> HomeGlanceSensor? in
                    guard characteristic.isReadable, AppleHomeCapabilities.controlKind(for: characteristic, in: service) == nil else { return nil }
                    let needsAttention = characteristic.value.map { AppleHomeCapabilities.needsAttention(characteristic.kind, $0) } ?? false
                    return HomeGlanceSensor(
                        id: .appleHome(accessory: accessory.id, characteristic: characteristic.id),
                        deviceName: accessory.name,
                        roomName: accessory.roomName,
                        kindRawValue: characteristic.kind.rawValue,
                        value: characteristic.value?.doubleValue,
                        status: needsAttention ? .attention : .normal,
                        isDeviceConnected: accessory.isOperable,
                        checkedAt: characteristic.confirmedAt
                    )
                }
            }
    }
}
