import Foundation

/// A 조각보 (POGO) sensor module that needs checking, and why.
nonisolated struct DashboardAttentionItem: Identifiable, Hashable, Sendable {
    enum Reason: Hashable, Sendable {
        /// The bridge reports the module offline; `isPowerBaseOffline` when its whole Power Base
        /// went offline with it.
        case offline(isPowerBaseOffline: Bool)
        /// One of its readings has a status that needs attention (stale, unavailable, error).
        case reading(SensorKind, SensorStatus)
    }

    let module: SensorModule
    /// Never empty. An offline module is listed as offline only: its readings can't be current
    /// while it is offline, so their statuses would only repeat that.
    let reasons: [Reason]

    var id: UUID { module.id }
}

/// One module's readings, as the Dashboard's sensor tile counts them.
nonisolated struct DashboardReadingGroup: Identifiable, Hashable, Sendable {
    let module: SensorModule
    let readings: [SensorReading]

    var id: UUID { module.id }
}

/// The Dashboard's three 조각보 sensor tiles ("온라인", "확인 필요", "센서") and the lists they
/// open. Each tile shows the count of the list computed here, so the number and the list can't
/// disagree. POGO data only — Apple Home devices are never counted here.
nonisolated enum DashboardMetrics {
    /// The online modules, or `nil` while the connection isn't verified: a count shown then
    /// would be a stale guess (see `HomeHealthState.isCurrentStateVerified`).
    static func onlineModules(_ snapshot: HomeSnapshot, health: HomeHealthState) -> [SensorModule]? {
        guard health.isCurrentStateVerified else { return nil }
        return sorted(snapshot.modules.filter(\.isOnline), in: snapshot)
    }

    /// The modules needing attention with their reasons, or `nil` while the connection isn't
    /// verified. Exactly `HomeSnapshot.modulesNeedingAttention`.
    static func attentionItems(_ snapshot: HomeSnapshot, health: HomeHealthState) -> [DashboardAttentionItem]? {
        guard health.isCurrentStateVerified else { return nil }
        return sorted(snapshot.modulesNeedingAttention, in: snapshot).map { module in
            DashboardAttentionItem(module: module, reasons: reasons(for: module, in: snapshot))
        }
    }

    static func reasons(for module: SensorModule, in snapshot: HomeSnapshot) -> [DashboardAttentionItem.Reason] {
        guard module.isOnline else {
            return [.offline(isPowerBaseOffline: snapshot.isOfflineBecausePowerBaseIsOffline(module))]
        }
        return module.sortedReadings
            .filter(\.status.needsAttention)
            .map { .reading($0.kind, $0.status) }
    }

    /// Every reading the snapshot holds (`HomeSnapshot.allReadings`), per module. Not gated on
    /// the connection: the tile always shows how many values are on screen, current or last
    /// received.
    static func readingGroups(_ snapshot: HomeSnapshot) -> [DashboardReadingGroup] {
        sorted(snapshot.modules, in: snapshot).compactMap { module in
            module.readings.isEmpty ? nil : DashboardReadingGroup(module: module, readings: module.sortedReadings)
        }
    }

    static func readingCount(_ groups: [DashboardReadingGroup]) -> Int {
        groups.reduce(0) { $0 + $1.readings.count }
    }

    /// By room (the rooms' own order, unplaced modules last), then name.
    private static func sorted(_ modules: [SensorModule], in snapshot: HomeSnapshot) -> [SensorModule] {
        modules.sorted { a, b in
            let roomA = snapshot.room(for: a)?.sortOrder ?? .max
            let roomB = snapshot.room(for: b)?.sortOrder ?? .max
            if roomA != roomB { return roomA < roomB }
            switch a.name.localizedStandardCompare(b.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.id.uuidString < b.id.uuidString
            }
        }
    }
}
