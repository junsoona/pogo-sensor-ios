import Foundation
import Observation
import os

/// Drives the "Find hubs" sheet: one Bonjour browse while the sheet is open, and checking the hub
/// the user picks. Finding hubs never changes the connection — only a hub the user picked *and*
/// that passed `HubVerifier` is handed back, for Settings to apply.
///
/// Every browse and every check belongs to a session (`generation`); `stop()` ends the session, so
/// an event or a check result that arrives afterwards is dropped instead of changing the list or
/// connecting. Opening the sheet again starts a fresh session — there is never more than one browse.
@MainActor
@Observable
final class HubDiscoveryModel {
    enum SearchState: Equatable {
        case idle
        case searching
        case localNetworkDenied
        case failed(String)
    }

    private(set) var searchState: SearchState = .idle
    /// Only what the browser currently reports, one row per hub.
    private(set) var hubs: [DiscoveredHub] = []
    /// Set once a search has run for `quietPeriod` without finding anything.
    private(set) var searchedWithoutResults = false
    /// The row being checked, if any.
    private(set) var verifyingHubID: DiscoveredHub.ID?
    /// The last check that failed, shown under its row.
    private(set) var verificationFailure: (hubID: DiscoveredHub.ID, message: String)?

    /// "Nothing found" is shown only after the browse has had a fair chance.
    var showsNoResults: Bool {
        searchState == .searching && hubs.isEmpty && searchedWithoutResults
    }

    private let browser: HubBrowsing
    private let verifier: HubVerifier
    private let quietPeriod: Duration
    private var generation = 0
    private var browseTask: Task<Void, Never>?
    private var quietTask: Task<Void, Never>?
    private var verifyTask: Task<SelectedHub, Error>?

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.junsoona.PogoHome", category: "HubDiscovery")

    init(browser: HubBrowsing = NetworkHubBrowser(), verifier: HubVerifier = .live(), quietPeriod: Duration = .seconds(6)) {
        self.browser = browser
        self.verifier = verifier
        self.quietPeriod = quietPeriod
    }

    /// Starts browsing unless a browse is already running. Safe to call on every appearance.
    func start() {
        guard browseTask == nil else { return }
        generation += 1
        let session = generation
        hubs = []
        searchedWithoutResults = false
        searchState = .searching
        let stream = browser.browse()
        browseTask = Task { [weak self] in
            for await event in stream {
                guard let self, self.generation == session else { return }
                self.handle(event)
            }
            guard let self, self.generation == session else { return }
            self.browseTask = nil
        }
        startQuietTimer(session: session)
    }

    /// Ends the session: stops the browse, abandons a running check, and forgets the list.
    func stop() {
        generation += 1
        browseTask?.cancel()
        browseTask = nil
        quietTask?.cancel()
        quietTask = nil
        verifyTask?.cancel()
        verifyTask = nil
        verifyingHubID = nil
        searchState = .idle
    }

    /// "Search again": a new session from nothing.
    func restart() {
        stop()
        hubs = []
        verificationFailure = nil
        start()
    }

    /// Checks `hub` and returns the selection to apply, or `nil` when the check failed (the reason
    /// is in `verificationFailure`), was replaced by a check of another row, or the sheet closed.
    func select(_ hub: DiscoveredHub) async -> SelectedHub? {
        verificationFailure = nil
        if let problem = hub.problem {
            verificationFailure = (hub.id, HubVerificationError.invalidAdvertisement(problem).message)
            return nil
        }
        verifyTask?.cancel()
        let session = generation
        let verifier = verifier
        let task = Task { try await verifier.verify(hub) }
        verifyTask = task
        verifyingHubID = hub.id
        let result = await task.result
        // Another row was picked meanwhile, or the sheet closed: this result is not wanted.
        guard verifyTask == task, generation == session else { return nil }
        verifyTask = nil
        verifyingHubID = nil
        switch result {
        case let .success(selection):
            Self.logger.notice("hub verified: \(selection.hubID, privacy: .public) at \(selection.baseURL, privacy: .public)")
            return selection
        case let .failure(error):
            if error is CancellationError { return nil }
            let message = (error as? HubVerificationError)?.message ?? error.localizedDescription
            Self.logger.notice("hub check failed for \(hub.id, privacy: .public): \(message, privacy: .public)")
            verificationFailure = (hub.id, message)
            return nil
        }
    }

    private func handle(_ event: HubBrowseEvent) {
        switch event {
        case .ready:
            if searchState != .searching && hubs.isEmpty { searchState = .searching }
        case let .results(results):
            hubs = DiscoveredHub.merge(results)
            // Results arriving means browsing works (e.g. permission was just granted).
            searchState = .searching
            if let failed = verificationFailure?.hubID, !hubs.contains(where: { $0.id == failed }) {
                verificationFailure = nil
            }
        case let .waiting(issue):
            searchState = Self.state(for: issue)
        case let .failed(issue):
            searchState = Self.state(for: issue)
            browseTask = nil
        }
    }

    private static func state(for issue: HubBrowseIssue) -> SearchState {
        switch issue {
        case .localNetworkDenied: return .localNetworkDenied
        case let .other(message): return .failed(message)
        }
    }

    private func startQuietTimer(session: Int) {
        quietTask?.cancel()
        let quietPeriod = quietPeriod
        quietTask = Task { [weak self] in
            try? await Task.sleep(for: quietPeriod)
            guard !Task.isCancelled, let self, self.generation == session else { return }
            self.searchedWithoutResults = true
        }
    }
}
