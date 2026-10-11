import Foundation

/// The Dashboard's connection/health verdict. Deliberately its own testable type instead of
/// scattered `if`s inside `HomeStatusCard`/`DashboardView` — those views should only render
/// this, never derive it.
nonisolated enum HomeHealthState: Equatable, Sendable {
    /// No module has ever been received yet (first launch, or a fresh data source that
    /// hasn't delivered anything at all).
    case waitingForData
    /// The live data source isn't currently connected, or hasn't synced recently enough to
    /// trust — but a previously good snapshot is still on screen.
    case reconnecting
    /// The API connection is live, but the Linux registry has not yet rebuilt the complete
    /// module/readings set that was previously observed.
    case recoveringRegistry
    /// Connected, fresh, at least one module, and nothing needs attention.
    case healthy
    /// Connected and fresh, but one or more modules are offline or need attention.
    case attentionNeeded
}

nonisolated enum HomeHealthEvaluator {
    /// How long a snapshot may go without a fresh sync before it's no longer trusted, even
    /// if `connectionStatus` still claims `.connected`. Deliberately larger than the SSE
    /// liveness watchdog's own idle timeout (see `SSELivenessWatchdog`) — that watchdog is
    /// the primary mechanism that flips `connectionStatus` away from `.connected`, and this
    /// is only a backstop against a data source that ever gets that wrong.
    static let defaultFreshnessWindow: TimeInterval = 60

    static func evaluate(
        snapshot: HomeSnapshot,
        connectionStatus: DataSourceConnectionStatus,
        lastSyncAt: Date?,
        isRegistryRecovering: Bool = false,
        now: Date = Date(),
        freshnessWindow: TimeInterval = defaultFreshnessWindow
    ) -> HomeHealthState {
        let isConnected = connectionStatus == .connected
        let isFresh = lastSyncAt.map { now.timeIntervalSince($0) <= freshnessWindow } ?? false
        let hasData = !snapshot.modules.isEmpty

        guard isConnected, isFresh else {
            return hasData ? .reconnecting : .waitingForData
        }
        guard hasData else {
            return .waitingForData
        }
        guard snapshot.onlineModulesHaveReadings else {
            return .waitingForData
        }
        guard !isRegistryRecovering else {
            return .recoveringRegistry
        }
        guard snapshot.allOnline, snapshot.modulesNeedingAttention.isEmpty else {
            return .attentionNeeded
        }
        return .healthy
    }
}

/// Why there is nothing to show yet: no module has been received from the current source.
/// Refines `HomeHealthState.waitingForData` for the Dashboard, so a source that is still being
/// reached, one that can't be reached, and one that answered without modules read differently.
nonisolated enum HomeDataWait: Equatable, Sendable {
    /// Connecting for the first time to this source.
    case connecting
    /// The source couldn't be reached; it's being retried.
    case unreachable
    /// Connected, but no module has been reported yet.
    case noModulesYet
}

nonisolated extension HomeHealthEvaluator {
    /// `nil` once any module is on screen — then `evaluate` alone describes the state.
    static func dataWait(snapshot: HomeSnapshot, connectionStatus: DataSourceConnectionStatus) -> HomeDataWait? {
        guard snapshot.modules.isEmpty else { return nil }
        switch connectionStatus {
        case .idle, .connecting: return .connecting
        case .reconnecting, .failed: return .unreachable
        case .connected: return .noModulesYet
        }
    }
}

nonisolated extension HomeHealthEvaluator {
    /// Whether the hub's word about its Power Bases can be stated as a fact: the connection is
    /// live, something was received within `freshnessWindow`, and the Bases on screen are not
    /// ones kept from an earlier snapshot while the sensors recover.
    ///
    /// Deliberately not derived from `HomeHealthState`: that verdict is about the sensors (none
    /// yet, or one without a first reading, is "waiting for data"), while a Power Base is heard by
    /// the hub whether or not anything is docked on it. This never makes the home's health any
    /// better -- it only decides whether a Base's "connected"/"disconnected" is shown as current.
    static func isPowerBaseStateVerified(
        connectionStatus: DataSourceConnectionStatus,
        lastSyncAt: Date?,
        isHoldingBackSensorData: Bool,
        now: Date = Date(),
        freshnessWindow: TimeInterval = defaultFreshnessWindow
    ) -> Bool {
        guard connectionStatus == .connected, let lastSyncAt, now.timeIntervalSince(lastSyncAt) <= freshnessWindow else {
            return false
        }
        return !isHoldingBackSensorData
    }
}

extension HomeHealthState {
    /// True only when the connection and registry are current enough for per-module online
    /// badges and counts to be stated as facts. For a Power Base's own state see
    /// `HomeHealthEvaluator.isPowerBaseStateVerified`.
    nonisolated var isCurrentStateVerified: Bool {
        switch self {
        case .healthy, .attentionNeeded:
            return true
        case .waitingForData, .reconnecting, .recoveringRegistry:
            return false
        }
    }
}
