import Foundation
import Observation
import os

/// App-wide state, backed by whichever `SensorDataSource` the entry point injects.
/// Views read `snapshot`/`health` and never talk to a data source directly.
@MainActor
@Observable
final class AppModel {
    private(set) var snapshot: HomeSnapshot
    private(set) var connectionStatus: DataSourceConnectionStatus = .idle
    /// When the app last heard anything from the data source — any `updates()` value,
    /// empty or not. `health` uses this as a freshness backstop independent of
    /// `connectionStatus`, in case a data source ever reports `.connected` without actually
    /// still delivering data.
    private(set) var lastSyncAt: Date?

    private var dataSource: SensorDataSource
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

    init(dataSource: SensorDataSource, initialSnapshot: HomeSnapshot? = nil) {
        self.dataSource = dataSource
        self.snapshot = initialSnapshot ?? HomeSnapshot(timestamp: Date(), rooms: [], modules: [])
        if self.snapshot.onlineModulesHaveReadings {
            self.completeModuleIDs = Set(self.snapshot.modules.map(\.id))
        }
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
    /// screen); only `connectionStatus` moves to `.idle` to reflect that nothing is live.
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
    func replace(dataSource newDataSource: SensorDataSource) {
        stop()
        dataSource = newDataSource
        completeModuleIDs = []
        isRegistryRecovering = false
        start()
    }

    func module(with id: UUID) -> SensorModule? {
        snapshot.modules.first { $0.id == id }
    }

    func room(with id: UUID) -> Room? {
        snapshot.rooms.first { $0.id == id }
    }

    /// Applies one incoming snapshot from the data source — the single application path for
    /// both `updates()` and `runPeriodicRefresh(source:interval:generation:)`, so recovery
    /// via polling follows exactly the same merge policy as recovery via a pushed update.
    ///
    /// A restarted Linux registry repopulates asynchronously: topology can arrive one module
    /// at a time, before that module has any samples. A real removal is represented by an
    /// explicit offline node, so an empty registry, a strict subset of the last complete
    /// module set, or an online module with no readings is recovery progress. Those
    /// snapshots update freshness but cannot erase the last complete state on screen.
    private func applyIncoming(_ incoming: HomeSnapshot) {
        lastSyncAt = Date()

        let incomingIDs = Set(incoming.modules.map(\.id))
        let incomingIsComplete = incoming.onlineModulesHaveReadings

        if !completeModuleIDs.isEmpty {
            let containsLastCompleteSet = completeModuleIDs.isSubset(of: incomingIDs)
            guard containsLastCompleteSet, incomingIsComplete else {
                if !isRegistryRecovering {
                    Self.logger.notice(
                        "registry recovery entered: \(incoming.modules.count, privacy: .public) module(s), complete=\(incomingIsComplete, privacy: .public)"
                    )
                }
                isRegistryRecovering = true
                return
            }
        }

        snapshot = incoming
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
}

extension AppModel {
    /// A deterministic instance for SwiftUI previews; never starts its update loop, but is
    /// seeded as already-connected so previews show the healthy state by default instead of
    /// the "reconnecting" banner an unstarted `AppModel` would otherwise report.
    static var preview: AppModel {
        let model = AppModel(dataSource: MockSensorDataSource(), initialSnapshot: MockSensorFixtures.previewSnapshot)
        model.connectionStatus = .connected
        model.lastSyncAt = Date()
        return model
    }
}
