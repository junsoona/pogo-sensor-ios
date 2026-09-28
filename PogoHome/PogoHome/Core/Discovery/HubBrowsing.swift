import Foundation
import Network
import os

/// Something that went wrong while browsing.
nonisolated enum HubBrowseIssue: Hashable, Sendable {
    /// The user hasn't allowed (or has turned off) Local Network access for the app.
    case localNetworkDenied
    case other(String)
}

nonisolated enum HubBrowseEvent: Hashable, Sendable {
    case ready
    /// The complete current result set — a service that went away is missing from it.
    case results([HubBrowseResult])
    /// Browsing can't proceed for now but continues by itself once it can (e.g. permission granted).
    case waiting(HubBrowseIssue)
    /// Browsing stopped; the stream ends after this.
    case failed(HubBrowseIssue)
}

/// Looks for `_jogakbo._tcp` services. Each `browse()` is one independent browse that runs until
/// its stream's consumer stops iterating (or its task is cancelled).
nonisolated protocol HubBrowsing: Sendable {
    func browse() -> AsyncStream<HubBrowseEvent>
}

/// Turns a browse result into the address to connect to.
nonisolated protocol HubServiceResolving: Sendable {
    /// The base URL (`http://host:port`) of the service's HTTP API.
    func resolveBaseURL(_ endpoint: HubServiceEndpoint) async throws -> URL
}

/// Reads a hub's `/api/v1/health` body.
nonisolated protocol HubHealthFetching: Sendable {
    func fetchHealth(from url: URL) async throws -> Data
}

/// The app's own HTTP transport, which already validates status and content type.
nonisolated struct TransportHubHealthFetcher: HubHealthFetching {
    let transport: SensorAPITransport

    func fetchHealth(from url: URL) async throws -> Data {
        try await transport.fetchSnapshotData(from: url)
    }
}

/// Bonjour browsing with `NWBrowser` (Network framework).
nonisolated struct NetworkHubBrowser: HubBrowsing {
    /// `kDNSServiceErr_PolicyDenied`: Local Network privacy denies the app.
    static let policyDeniedError: Int32 = -65570

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.junsoona.PogoHome", category: "HubDiscovery")

    func browse() -> AsyncStream<HubBrowseEvent> {
        AsyncStream { continuation in
            let parameters = NWParameters()
            parameters.includePeerToPeer = false
            let browser = NWBrowser(
                for: .bonjourWithTXTRecord(type: HubBonjour.serviceType, domain: HubBonjour.domain),
                using: parameters
            )
            browser.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.yield(.ready)
                case let .waiting(error):
                    Self.logger.notice("browse waiting: \(String(describing: error), privacy: .public)")
                    continuation.yield(.waiting(Self.issue(error)))
                case let .failed(error):
                    Self.logger.error("browse failed: \(String(describing: error), privacy: .public)")
                    continuation.yield(.failed(Self.issue(error)))
                    continuation.finish()
                case .cancelled:
                    continuation.finish()
                default:
                    break
                }
            }
            browser.browseResultsChangedHandler = { results, _ in
                continuation.yield(.results(results.compactMap(Self.result)))
            }
            continuation.onTermination = { _ in browser.cancel() }
            browser.start(queue: DispatchQueue(label: "com.junsoona.PogoHome.hub-browser"))
        }
    }

    static func issue(_ error: NWError) -> HubBrowseIssue {
        if case let .dns(code) = error, code == policyDeniedError {
            return .localNetworkDenied
        }
        return .other(error.localizedDescription)
    }

    private static func result(_ result: NWBrowser.Result) -> HubBrowseResult? {
        guard case let .service(name, _, domain, interface) = result.endpoint else { return nil }
        var txt: [String: String] = [:]
        if case let .bonjour(record) = result.metadata {
            txt = record.dictionary
        }
        return HubBrowseResult(
            serviceName: name,
            domain: domain,
            txt: txt,
            endpoint: HubServiceEndpoint(
                key: "\(name).\(domain)@\(interface?.name ?? "any")",
                network: AnyHashable(result.endpoint)
            )
        )
    }
}

/// Resolves a Bonjour service by opening a TCP connection to it (`NWConnection`) and reading the
/// address that actually connected — so the URL uses an address the hub really listens on. The
/// connection is closed right away; nothing is sent over it.
nonisolated struct NetworkHubServiceResolver: HubServiceResolving {
    var timeout: Duration = .seconds(6)

    func resolveBaseURL(_ endpoint: HubServiceEndpoint) async throws -> URL {
        guard let target = endpoint.network?.base as? NWEndpoint else {
            throw HubVerificationError.resolveFailed("no service endpoint")
        }
        let connection = NWConnection(to: target, using: .tcp)
        let outcome = ResolveOutcome()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                outcome.set(continuation)
                let queue = DispatchQueue(label: "com.junsoona.PogoHome.hub-resolver")
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        let remote = connection.currentPath?.remoteEndpoint
                        connection.cancel()
                        if let url = remote.flatMap(Self.baseURL(for:)) {
                            outcome.finish(.success(url))
                        } else {
                            outcome.finish(.failure(HubVerificationError.resolveFailed("no address")))
                        }
                    case let .waiting(error), let .failed(error):
                        connection.cancel()
                        outcome.finish(.failure(HubVerificationError.resolveFailed(error.localizedDescription)))
                    case .cancelled:
                        outcome.finish(.failure(CancellationError()))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                queue.asyncAfter(deadline: .now() + seconds) {
                    outcome.finish(.failure(HubVerificationError.resolveFailed(String(localized: "시간 초과", comment: "Hub discovery: resolving timed out"))))
                    connection.cancel()
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// `http://<address>:<port>`; an IPv6 link-local address keeps its interface as a zone.
    static func baseURL(for endpoint: NWEndpoint) -> URL? {
        guard case let .hostPort(host, port) = endpoint else { return nil }
        let hostText: String
        switch host {
        case let .ipv4(address):
            hostText = "\(address)".split(separator: "%").first.map(String.init) ?? "\(address)"
        case let .ipv6(address):
            let parts = "\(address)".split(separator: "%", maxSplits: 1).map(String.init)
            guard let bare = parts.first else { return nil }
            if address.isLinkLocal, parts.count == 2 {
                hostText = "[\(bare)%25\(parts[1])]"
            } else {
                hostText = "[\(bare)]"
            }
        case let .name(name, _):
            hostText = name
        @unknown default:
            return nil
        }
        return URL(string: "http://\(hostText):\(port.rawValue)")
    }

    /// Resumes the continuation exactly once, whichever of ready/failure/timeout/cancel comes first.
    private final class ResolveOutcome: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<URL, Error>?

        func set(_ continuation: CheckedContinuation<URL, Error>) {
            lock.withLock { self.continuation = continuation }
        }

        func finish(_ result: Result<URL, Error>) {
            let pending = lock.withLock { () -> CheckedContinuation<URL, Error>? in
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(with: result)
        }
    }
}

/// Confirms that a discovered hub is the Jogakbo sensor API it claims to be: resolves one of its
/// endpoints, then requires `/api/v1/health` to answer as a supported API with the announced hub_id.
nonisolated struct HubVerifier: Sendable {
    let resolver: HubServiceResolving
    let health: HubHealthFetching
    var now: @Sendable () -> Date = { Date() }

    static func live() -> HubVerifier {
        // A hub that doesn't answer should fail the check in seconds, not after URLSession's
        // default minute.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 6
        return HubVerifier(
            resolver: NetworkHubServiceResolver(),
            health: TransportHubHealthFetcher(transport: URLSessionSensorAPITransport(session: URLSession(configuration: configuration)))
        )
    }

    /// Only a hub whose announcement is usable is checked. Returns the selection to apply.
    func verify(_ hub: DiscoveredHub) async throws -> SelectedHub {
        if let problem = hub.problem { throw HubVerificationError.invalidAdvertisement(problem) }
        guard let hubID = hub.hubID else { throw HubVerificationError.invalidAdvertisement(.missingHubID) }
        var lastError: Error = HubVerificationError.resolveFailed("no endpoint")
        for endpoint in hub.endpoints {
            try Task.checkCancellation()
            do {
                let baseURL = try await verify(endpoint, expectedHubID: hubID)
                return SelectedHub(hubID: hubID, serviceName: hub.serviceName, baseURL: baseURL.absoluteString, verifiedAt: now())
            } catch let error as HubVerificationError {
                switch error {
                case .resolveFailed, .unreachable:
                    lastError = error // another endpoint (interface) may still work
                default:
                    throw error // the hub itself answered wrongly: never try to work around that
                }
            }
        }
        throw lastError
    }

    /// The verified base URL of `endpoint`, which must answer for `expectedHubID`.
    func verify(_ endpoint: HubServiceEndpoint, expectedHubID: String) async throws -> URL {
        let baseURL = try await resolver.resolveBaseURL(endpoint)
        try Task.checkCancellation()
        let data: Data
        do {
            data = try await health.fetchHealth(from: PogoAPIEndpoint(baseURL: baseURL).healthURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HubVerificationError.unreachable((error as NSError).localizedDescription)
        }
        _ = try HubHealthCheck.verify(data, expectedHubID: expectedHubID)
        return baseURL
    }
}
