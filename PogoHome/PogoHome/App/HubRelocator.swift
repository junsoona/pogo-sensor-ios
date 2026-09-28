import Foundation
import Observation
import os

/// Follows the hub the user chose when its address changes (a new DHCP lease, another API port).
///
/// While the Live connection to a *chosen* hub is failing, this browses `_jogakbo._tcp` for that
/// hub's `hub_id` only, resolves it, and requires `/api/v1/health` to answer with the same
/// `hub_id` before handing back the new address (`onRelocate`). It never moves to another hub —
/// announcements of other hubs are ignored — and it does nothing for an address typed by hand or
/// for simulated data. A new address for the same hub is the same data source, so the values on
/// screen stay (`AppModel.replace(dataSource:identity:address:)`).
///
/// At most one browse runs, only while disconnected; each announcement is checked at most once
/// per `retryInterval`, and a check still running when the connection recovers (or the choice
/// changes) is abandoned without effect.
@MainActor
@Observable
final class HubRelocator {
    /// Whether a relocation browse is running (for tests and diagnostics).
    private(set) var isSearching = false

    private let browser: HubBrowsing
    private let verifier: HubVerifier
    private let selection: @MainActor () -> SelectedHub?
    private let onRelocate: @MainActor (SelectedHub) -> Void
    private let retryInterval: Duration
    private let clock = ContinuousClock()

    private var generation = 0
    private var browseTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var verifyTask: Task<Void, Never>?
    private var candidates: [HubBrowseResult] = []
    private var lastAttempt: [HubServiceEndpoint: ContinuousClock.Instant] = [:]
    private var currentStatus: DataSourceConnectionStatus = .idle

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.junsoona.PogoHome", category: "HubDiscovery")

    init(
        browser: HubBrowsing = NetworkHubBrowser(),
        verifier: HubVerifier = .live(),
        retryInterval: Duration = .seconds(15),
        selection: @escaping @MainActor () -> SelectedHub?,
        onRelocate: @escaping @MainActor (SelectedHub) -> Void
    ) {
        self.browser = browser
        self.verifier = verifier
        self.retryInterval = retryInterval
        self.selection = selection
        self.onRelocate = onRelocate
    }

    /// Call with every Live connection status change (and again after the choice changed).
    func connectionStatusDidChange(_ status: DataSourceConnectionStatus) {
        currentStatus = status
        evaluate()
    }

    /// The chosen hub or its address changed (or was cleared): start over for the new choice.
    func selectionDidChange() {
        stopSearching()
        evaluate()
    }

    /// Stops everything — the app going to the background.
    func suspend() {
        currentStatus = .idle
        stopSearching()
    }

    private var shouldSearch: Bool {
        guard selection() != nil else { return false }
        switch currentStatus {
        case .failed, .reconnecting: return true
        case .idle, .connecting, .connected: return false
        }
    }

    private func evaluate() {
        if shouldSearch {
            startSearching()
        } else {
            stopSearching()
        }
    }

    private func startSearching() {
        guard browseTask == nil, let chosen = selection() else { return }
        generation += 1
        let session = generation
        isSearching = true
        candidates = []
        lastAttempt = [:]
        Self.logger.notice("looking for hub \(chosen.hubID, privacy: .public) after the connection failed")
        let stream = browser.browse()
        browseTask = Task { [weak self] in
            for await event in stream {
                guard let self, self.generation == session else { return }
                if case let .results(results) = event {
                    self.candidates = results.filter { HubAdvertisement(txt: $0.txt).hubID == chosen.hubID }
                    self.checkCandidates(session: session)
                }
            }
        }
        let retryInterval = retryInterval
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: retryInterval)
                guard !Task.isCancelled, let self, self.generation == session else { return }
                self.checkCandidates(session: session)
            }
        }
    }

    private func stopSearching() {
        generation += 1
        browseTask?.cancel()
        browseTask = nil
        retryTask?.cancel()
        retryTask = nil
        verifyTask?.cancel()
        verifyTask = nil
        candidates = []
        lastAttempt = [:]
        isSearching = false
    }

    /// Checks the next announcement of the chosen hub that wasn't checked within `retryInterval`.
    private func checkCandidates(session: Int) {
        guard verifyTask == nil, let chosen = selection() else { return }
        let now = clock.now
        guard let candidate = candidates.first(where: { candidate in
            guard HubAdvertisement(txt: candidate.txt).problem == nil else { return false }
            guard let last = lastAttempt[candidate.endpoint] else { return true }
            return now - last >= retryInterval
        }) else { return }
        lastAttempt[candidate.endpoint] = now
        let verifier = verifier
        verifyTask = Task { [weak self] in
            let outcome: Result<URL, Error>
            do {
                outcome = .success(try await verifier.verify(candidate.endpoint, expectedHubID: chosen.hubID))
            } catch {
                outcome = .failure(error)
            }
            guard let self, self.generation == session else { return }
            self.verifyTask = nil
            self.finishCheck(outcome, candidate: candidate, chosen: chosen, session: session)
        }
    }

    private func finishCheck(_ outcome: Result<URL, Error>, candidate: HubBrowseResult, chosen: SelectedHub, session: Int) {
        switch outcome {
        case let .success(url):
            // Still the same choice, still disconnected?
            guard let current = selection(), current.hubID == chosen.hubID, shouldSearch else { return }
            guard SensorSourceIdentity.hub(url) != current.usableBaseURL.map(SensorSourceIdentity.hub) else {
                // The hub is announced at the address already in use: it's just not answering
                // the Live connection yet. The Live connection keeps retrying on its own.
                checkCandidates(session: session)
                return
            }
            Self.logger.notice("hub \(chosen.hubID, privacy: .public) moved to \(url.absoluteString, privacy: .public)")
            stopSearching()
            onRelocate(current.relocated(to: url, serviceName: candidate.serviceName, at: Date()))
        case let .failure(error):
            if !(error is CancellationError) {
                let message = (error as? HubVerificationError)?.message ?? error.localizedDescription
                Self.logger.notice("hub relocation check failed: \(message, privacy: .public)")
            }
            checkCandidates(session: session)
        }
    }
}
