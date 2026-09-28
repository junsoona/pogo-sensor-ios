import Foundation
import Observation
import os
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Where glance snapshots are kept between processes. `HomeGlanceStore` in the app; a fake in
/// tests.
protocol HomeGlanceStoring: Sendable {
    func load() -> HomeGlanceStore.LoadResult
    func save(_ snapshot: HomeGlanceSnapshot) throws
}

extension HomeGlanceStore: HomeGlanceStoring {}

/// Asks the system to redraw the widgets from the stored glance.
@MainActor
protocol HomeGlanceReloading: AnyObject {
    func reloadWidgets()
}

@MainActor
final class WidgetCenterReloader: HomeGlanceReloading {
    func reloadWidgets() {
        #if canImport(WidgetKit)
        for kind in HomeGlanceWidgetKind.all {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
        #endif
    }
}

/// Keeps the stored glance (and through it the widgets) in step with the app while the app is
/// in the foreground. Reads `AppModel` and `AppleHomeModel`, never changes them, and does
/// nothing while suspended — so the app stopping its POGO connection in the background is never
/// mistaken for the connection failing.
///
/// Each change is turned into a snapshot (`HomeGlanceBuilder`) and a decision
/// (`HomeGlanceRefreshPolicy`) about whether to write the file and whether to reload widgets.
@MainActor
@Observable
final class HomeGlancePublisher {
    @ObservationIgnored private let appModel: AppModel
    @ObservationIgnored private let appleHome: AppleHomeModel
    @ObservationIgnored private let store: HomeGlanceStoring?
    @ObservationIgnored private let reloader: HomeGlanceReloading
    @ObservationIgnored private let isSimulatedData: @MainActor () -> Bool
    @ObservationIgnored private let now: @MainActor () -> Date
    /// Coalesces bursts of model changes (one SSE event can touch several properties).
    @ObservationIgnored private let debounce: Duration

    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var sessionStartedAt = Date.distantPast
    /// The last snapshot built in this process — the base for the next one, so confirmation
    /// times carry forward even between throttled writes.
    @ObservationIgnored private var lastBuilt: HomeGlanceSnapshot?
    @ObservationIgnored private var persisted: HomeGlanceSnapshot?
    @ObservationIgnored private var reloaded: HomeGlanceSnapshot?
    @ObservationIgnored private var lastPersistAt: Date?
    @ObservationIgnored private var lastReloadAt: Date?
    @ObservationIgnored private var hasLoadedStore = false
    @ObservationIgnored private var pendingEvaluation: Task<Void, Never>?
    @ObservationIgnored private var scheduledReload: Task<Void, Never>?
    @ObservationIgnored private var observationGeneration = 0
    /// Called with every glance written to the store — the Apple Watch hand-over.
    @ObservationIgnored var onStored: (@MainActor (HomeGlanceSnapshot) -> Void)?

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.junsoona.PogoHome",
        category: "HomeGlance"
    )

    init(
        appModel: AppModel,
        appleHome: AppleHomeModel,
        store: HomeGlanceStoring?,
        reloader: HomeGlanceReloading,
        isSimulatedData: @escaping @MainActor () -> Bool,
        now: @escaping @MainActor () -> Date = { Date() },
        debounce: Duration = .milliseconds(750)
    ) {
        self.appModel = appModel
        self.appleHome = appleHome
        self.store = store
        self.reloader = reloader
        self.isSimulatedData = isSimulatedData
        self.now = now
        self.debounce = debounce
    }

    /// Starts following the models; call when the app becomes active. Idempotent.
    func resume() {
        guard !isActive else { return }
        isActive = true
        sessionStartedAt = now()
        loadStoreIfNeeded()
        observe()
        evaluate()
    }

    /// Writes and reloads whatever differs from what the widgets show, then stops following the
    /// models. Call when the app leaves the foreground, *before* the POGO connection is stopped.
    func suspend() {
        guard isActive else { return }
        pendingEvaluation?.cancel()
        pendingEvaluation = nil
        scheduledReload?.cancel()
        scheduledReload = nil
        let next = build()
        let decision = HomeGlanceRefreshPolicy.decideOnLeavingForeground(next: next, persisted: persisted, reloaded: reloaded)
        apply(decision, snapshot: next)
        isActive = false
        observationGeneration += 1
    }

    /// Whether the publisher follows the models now (the app is in the foreground).
    var isFollowingModels: Bool { isActive }

    /// The newest glance: built from the models now while following them, otherwise the last one
    /// built or stored (e.g. when the app was launched in the background).
    func latestSnapshot() -> HomeGlanceSnapshot? {
        guard isActive else {
            loadStoreIfNeeded()
            return lastBuilt
        }
        return build()
    }

    /// Builds the current snapshot and applies the refresh policy. Called after every observed
    /// change (debounced); exposed for tests.
    func evaluate() {
        guard isActive else { return }
        let next = build()
        let decision = HomeGlanceRefreshPolicy.decide(
            next: next,
            persisted: persisted,
            reloaded: reloaded,
            lastPersistAt: lastPersistAt,
            lastReloadAt: lastReloadAt,
            now: now()
        )
        apply(decision, snapshot: next)
    }

    // MARK: - Building

    private func build() -> HomeGlanceSnapshot {
        let layout = appleHome.layout(pogo: appModel.snapshot)
        let next = HomeGlanceBuilder.build(
            homeName: appModel.homeName,
            pogo: HomeGlanceBuilder.PogoInput(
                snapshot: appModel.snapshot,
                health: appModel.health,
                connectionStatus: appModel.connectionStatus,
                lastSyncAt: appModel.lastSyncAt,
                isSimulated: isSimulatedData(),
                sessionStartedAt: sessionStartedAt,
                source: appModel.sourceIdentity
            ),
            appleHome: HomeGlanceBuilder.AppleHomeInput(
                isEnabled: appleHome.isEnabled,
                accessState: appleHome.snapshot.accessState,
                visibleAccessories: layout.visibleAccessories
            ),
            previous: lastBuilt,
            now: now()
        )
        lastBuilt = next
        return next
    }

    private func loadStoreIfNeeded() {
        guard !hasLoadedStore else { return }
        hasLoadedStore = true
        let stored = store?.load().snapshot
        lastBuilt = stored
        persisted = stored
        // What the widgets show is whatever they last read — the stored file.
        reloaded = stored
    }

    // MARK: - Applying

    private func apply(_ decision: HomeGlanceRefreshPolicy.Decision, snapshot: HomeGlanceSnapshot) {
        if decision.persist {
            do {
                try store?.save(snapshot)
                persisted = snapshot
                lastPersistAt = now()
            } catch {
                Self.logger.error("glance write failed: \(String(describing: error), privacy: .public)")
                return
            }
            onStored?(snapshot)
        }
        switch decision.reload {
        case .none:
            break
        case .now:
            scheduledReload?.cancel()
            scheduledReload = nil
            reloader.reloadWidgets()
            reloaded = snapshot
            lastReloadAt = now()
        case let .at(date):
            scheduleReevaluation(at: date)
        }
    }

    private func scheduleReevaluation(at date: Date) {
        guard scheduledReload == nil else { return }
        let delay = max(0, date.timeIntervalSince(now()))
        scheduledReload = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.scheduledReload = nil
            self.evaluate()
        }
    }

    // MARK: - Observation

    private func observe() {
        let generation = observationGeneration
        withObservationTracking {
            _ = appModel.sourceIdentity
            _ = appModel.snapshot
            _ = appModel.connectionStatus
            _ = appModel.lastSyncAt
            _ = appModel.isRegistryRecovering
            _ = appModel.homeName
            _ = appleHome.snapshot
            _ = appleHome.isEnabled
            _ = appleHome.links
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.modelsChanged(generation: generation)
            }
        }
    }

    private func modelsChanged(generation: Int) {
        guard isActive, generation == observationGeneration else { return }
        guard pendingEvaluation == nil else { return }
        pendingEvaluation = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard let self, !Task.isCancelled, self.isActive, generation == self.observationGeneration else { return }
            self.pendingEvaluation = nil
            // Re-arm first: `withObservationTracking` reports one change per registration.
            self.observe()
            self.evaluate()
        }
    }
}
