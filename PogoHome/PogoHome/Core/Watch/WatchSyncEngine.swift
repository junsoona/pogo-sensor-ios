import Foundation
import Observation
import os

// The Watch's side of POGO data: where it keeps it, how it gets it, and when its widgets redraw.
// Compiled into the iPhone app as well, so the whole policy is unit-tested there with scripted
// paths; the Watch app supplies the real bridge client, iPhone link and widget reloader.

/// Reads the POGO bridge's snapshot directly (`GET /api/v1/snapshot`).
@MainActor
protocol WatchHubFetching: AnyObject {
    func fetchSnapshot(from baseURL: URL) async throws -> HomeSnapshot
}

/// Asks the paired iPhone's PogoHome for the current state; iOS starts the app in the background
/// if it isn't running.
@MainActor
protocol WatchPhoneRelaying: AnyObject {
    /// Whether the iPhone can be asked right now (paired, in range, session active).
    var isPhoneReachable: Bool { get }
    func requestRefresh() async throws -> WatchRelayReply
}

nonisolated enum WatchPhoneRelayError: Error, Equatable, Sendable {
    case unreachable
    case timedOut
    case invalidReply
}

@MainActor
protocol WatchWidgetReloading: AnyObject {
    func reloadWidgets()
}

/// Keeps the Watch's copy of the home: hand-overs from the iPhone, and rounds that look for a way
/// to the bridge.
///
/// A round tries the bridge directly first (works only on the bridge's network), then — if that
/// didn't reach it — the iPhone (works only while it's reachable, and gives new values only if the
/// iPhone itself reaches the bridge). If neither confirms the state, the last values stay with
/// their confirmation time and the POGO state becomes "not confirmed"; the presentation turns them
/// "old" after `HomeGlanceFreshness.staleAfter`. Nothing is ever assumed to have arrived.
@MainActor
@Observable
final class WatchSyncEngine {
    private(set) var state: WatchStoredState
    private(set) var isRefreshing = false
    /// The link to the iPhone app as the Watch's session last reported it.
    private(set) var phoneLink: WatchPhoneLinkStatus = .activating

    @ObservationIgnored private let store: WatchStateStoring?
    @ObservationIgnored private let hub: WatchHubFetching
    @ObservationIgnored private let phone: WatchPhoneRelaying
    @ObservationIgnored private let reloader: WatchWidgetReloading
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let language: AppLanguage
    /// What the widgets were last asked to draw (approximately what they show).
    @ObservationIgnored private var reloadedGlance: HomeGlanceSnapshot?
    @ObservationIgnored private var reloadedSelection: [String]?
    @ObservationIgnored private var lastReloadAt: Date?
    @ObservationIgnored private var scheduledReload: Task<Void, Never>?
    @ObservationIgnored private var foregroundLoop: Task<Void, Never>?
    /// The iPhone became reachable during a round while the Watch had no settings.
    @ObservationIgnored private var asksPhoneAfterRound = false

    private static let logger = Logger(subsystem: "com.junsoona.PogoHome", category: "WatchSync")

    init(
        store: WatchStateStoring?,
        hub: WatchHubFetching,
        phone: WatchPhoneRelaying,
        reloader: WatchWidgetReloading,
        language: AppLanguage = .current,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.store = store
        self.hub = hub
        self.phone = phone
        self.reloader = reloader
        self.language = language
        self.now = now
        let stored = store?.load() ?? .empty
        self.state = stored
        self.reloadedGlance = stored.glance
        self.reloadedSelection = stored.settings?.selectedValueIDs
    }

    var glance: HomeGlanceSnapshot? { state.glance }
    var settings: WatchSettings? { state.settings }
    var record: WatchSyncRecord { state.record }

    var connectionStatus: WatchConnectionStatus {
        WatchGlancePresentation.connection(settings: state.settings, record: state.record, isChecking: isRefreshing)
    }

    // MARK: - Hand-overs from the iPhone

    /// A glance and settings the iPhone sent by itself (application context, complication update).
    func receivePush(_ payload: WatchSyncPayload) {
        state.record.lastPushAt = now()
        accept(payload, via: "push")
        persistAndReload()
    }

    private func accept(_ payload: WatchSyncPayload, via source: String) {
        if WatchSettings.shouldAccept(payload.settings, over: state.settings) {
            if payload.settings != state.settings {
                Self.logger.notice("settings from iPhone (\(source, privacy: .public)): mode=\(payload.settings.dataSourceMode.rawValue, privacy: .public) hub=\(payload.settings.hubBaseURL != nil, privacy: .public) selected=\(payload.settings.selectedValueIDs.count, privacy: .public)")
            }
            state.settings = payload.settings
        } else {
            Self.logger.notice("older settings from iPhone ignored (\(source, privacy: .public))")
        }
        // The iPhone switched to simulated data or another hub: the values of the one it left
        // are no longer this Watch's either — neither the stored ones nor any arriving late.
        if let pogoSource = state.settings?.pogoSource {
            state.glance = state.glance?.keepingPogo(from: pogoSource)
            if let glance = payload.glance {
                apply(glance.keepingPogo(from: pogoSource), via: .phone)
            }
        } else if let glance = payload.glance {
            apply(glance, via: .phone)
        }
    }

    /// Merges `incoming`, noting the path when it brought a newer POGO confirmation.
    private func apply(_ incoming: HomeGlanceSnapshot, via path: WatchPogoPath) {
        let before = state.glance?.pogo.verifiedAt
        let merged = WatchGlanceMerger.merge(current: state.glance, incoming: incoming)
        state.glance = merged
        if let after = merged.pogo.verifiedAt, after != before, after == incoming.pogo.verifiedAt {
            state.record.lastConfirmation = WatchConfirmation(path: path, at: after)
        }
    }

    /// The Watch's session reported a change in the link to the iPhone. A Watch without settings
    /// asks a newly reachable iPhone right away: the round at launch usually runs before the
    /// session has activated, and would otherwise leave it without settings until the next round.
    func phoneLinkDidChange(_ status: WatchPhoneLinkStatus) {
        guard status != phoneLink else { return }
        phoneLink = status
        guard status == .reachable, state.settings == nil else { return }
        if isRefreshing {
            asksPhoneAfterRound = true
        } else {
            Self.logger.notice("asking the iPhone for settings")
            Task { await self.refresh() }
        }
    }

    // MARK: - Rounds

    /// Looks for a way to the bridge now. `allowsPhone` is `false` in a background refresh, where
    /// the iPhone isn't asked. Returns `nil` if a round was already running or this one was
    /// cancelled.
    @discardableResult
    func refresh(allowsPhone: Bool = true) async -> WatchSyncRound? {
        guard !isRefreshing else { return nil }
        isRefreshing = true
        defer {
            isRefreshing = false
            if asksPhoneAfterRound {
                asksPhoneAfterRound = false
                if state.settings == nil, allowsPhone { Task { await self.refresh() } }
            }
        }

        let direct = await tryDirect()
        if Task.isCancelled { return nil }

        var phoneResult = WatchPathResult.notTried
        // The bridge answered (confirmed, or still rebuilding): the iPhone would get the same.
        let bridgeAnswered = direct == .confirmed || direct == .failed(.hubRecovering)
        if !bridgeAnswered && allowsPhone {
            phoneResult = await tryPhone()
            if Task.isCancelled { return nil }
        }

        let round = WatchSyncRound(at: now(), direct: direct, phone: phoneResult)
        state.record.lastRound = round
        if round.confirmedBy == nil && !bridgeAnswered {
            state.glance = WatchGlanceMerger.markingUnreachable(state.glance, at: round.at)
        }
        Self.logger.notice("round: direct=\(String(describing: direct), privacy: .public) phone=\(String(describing: phoneResult), privacy: .public) link=\(self.phoneLink.rawValue, privacy: .public) settings=\(self.state.settings != nil, privacy: .public)")
        persistAndReload()
        return round
    }

    private func tryDirect() async -> WatchPathResult {
        guard let settings = state.settings else { return .failed(.notConfigured) }
        guard settings.dataSourceMode == .live else { return .failed(.simulated) }
        guard let url = settings.directHubURL else { return .failed(.notConfigured) }
        do {
            let fetched = try await hub.fetchSnapshot(from: url)
            let fetchedAt = now()
            let labelled = PogoGlanceRefresher.applyingLabels(settings.moduleLabels, to: fetched)
            let incoming = PogoGlanceRefresher.refreshed(
                previous: state.glance,
                fetched: labelled,
                from: settings.pogoSource ?? .hub(url),
                fetchedAt: fetchedAt,
                homeName: state.glance?.homeName ?? HomeConfigurationDefaults.homeName(in: language)
            )
            apply(incoming, via: .direct)
            return incoming.pogo.verifiedAt == fetchedAt ? .confirmed : .failed(.hubRecovering)
        } catch {
            return .failed(Self.classify(error))
        }
    }

    private func tryPhone() async -> WatchPathResult {
        guard phone.isPhoneReachable else { return .failed(.phoneUnreachable) }
        do {
            let reply = try await phone.requestRefresh()
            accept(reply.payload, via: "reply")
            switch reply.outcome {
            case .confirmed, .simulated: return .confirmed
            case .hubRecovering: return .failed(.hubRecovering)
            case .hubUnreachable: return .failed(.phoneCannotReachHub)
            }
        } catch WatchPhoneRelayError.timedOut {
            return .failed(.phoneTimedOut)
        } catch {
            return .failed(.phoneUnreachable)
        }
    }

    /// No answer at all is "unreachable"; an answer that can't be used is "bad response".
    nonisolated static func classify(_ error: Error) -> WatchPathFailure {
        if error is URLError { return .hubUnreachable }
        if error is PogoAPIError { return .badResponse }
        return .hubUnreachable
    }

    // MARK: - Foreground updates

    /// Refreshes now and then every `interval` seconds until `stopForegroundUpdates()`. Idempotent.
    func startForegroundUpdates(interval: Double = 30, sleeper: AsyncSleeping = RealAsyncSleeper()) {
        guard foregroundLoop == nil else { return }
        foregroundLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await sleeper.sleep(seconds: interval) } catch { return }
            }
        }
    }

    func stopForegroundUpdates() {
        foregroundLoop?.cancel()
        foregroundLoop = nil
    }

    // MARK: - Persisting and widgets

    private func persistAndReload() {
        do {
            try store?.save(state)
        } catch {
            Self.logger.error("watch state write failed: \(String(describing: error), privacy: .public)")
        }
        guard let glance = state.glance else { return }
        let selection = state.settings?.selectedValueIDs
        if selection != reloadedSelection {
            reload(glance)
            return
        }
        let decision = HomeGlanceRefreshPolicy.decide(
            next: glance,
            persisted: nil,
            reloaded: reloadedGlance,
            lastPersistAt: nil,
            lastReloadAt: lastReloadAt,
            now: now()
        )
        switch decision.reload {
        case .none:
            break
        case .now:
            reload(glance)
        case let .at(date):
            scheduleReload(at: date)
        }
    }

    private func reload(_ glance: HomeGlanceSnapshot) {
        scheduledReload?.cancel()
        scheduledReload = nil
        reloader.reloadWidgets()
        reloadedGlance = glance
        reloadedSelection = state.settings?.selectedValueIDs
        lastReloadAt = now()
    }

    private func scheduleReload(at date: Date) {
        guard scheduledReload == nil else { return }
        let delay = max(0, date.timeIntervalSince(now()))
        scheduledReload = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.scheduledReload = nil
            if let glance = self.state.glance { self.reload(glance) }
        }
    }
}
