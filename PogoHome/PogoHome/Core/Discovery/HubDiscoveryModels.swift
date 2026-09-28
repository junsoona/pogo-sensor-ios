import Foundation

/// What the Linux sensor hub announces over Bonjour, and the rules the app applies before it
/// trusts an announcement. Only the hub's HTTP API is ever looked for — never a Power Base or a
/// sensor module, and nothing about Thread or Apple Home. See the Linux side's
/// `docs/pogohome-api-v1.md` ("Bonjour").
nonisolated enum HubBonjour {
    /// Also listed under `NSBonjourServices` in Info.plist.
    static let serviceType = "_jogakbo._tcp"
    static let domain = "local."
    /// TXT `api` the app speaks — the API's `schema_version`.
    static let supportedAPIVersion = "1"
    /// TXT `path`: where `PogoAPIEndpoint` expects the routes under the advertised host and port.
    static let supportedBasePath = "/api/v1"
    /// `/api/v1/health` `service`.
    static let apiServiceName = "pogohome"
    static let supportedSchemaVersion = 1

    /// 32 lowercase hex digits, as the hub generates it.
    static func isValidHubID(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

/// Why an announcement can't be offered for connection, before anything is fetched from it.
nonisolated enum HubAdvertisementProblem: Hashable, Sendable {
    /// No valid `hub_id` in the TXT record: not a Jogakbo sensor hub the app can recognize again.
    case missingHubID
    /// An API version or base path this app doesn't speak.
    case unsupportedAPI(version: String?, path: String?)
}

/// The TXT record of one `_jogakbo._tcp` announcement.
nonisolated struct HubAdvertisement: Hashable, Sendable {
    let hubID: String?
    let apiVersion: String?
    let basePath: String?

    init(txt: [String: String]) {
        let id = txt["hub_id"]?.trimmingCharacters(in: .whitespaces).lowercased()
        hubID = id.flatMap { HubBonjour.isValidHubID($0) ? $0 : nil }
        apiVersion = txt["api"]
        basePath = txt["path"]
    }

    var problem: HubAdvertisementProblem? {
        guard hubID != nil else { return .missingHubID }
        var path = basePath ?? ""
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        guard apiVersion == HubBonjour.supportedAPIVersion, path == HubBonjour.supportedBasePath else {
            return .unsupportedAPI(version: apiVersion, path: basePath)
        }
        return nil
    }
}

/// Where a browse result can be reached — the Bonjour service itself, resolved only when the user
/// picks it. `key` identifies it in tests and logs; `network` is what the real resolver connects to.
nonisolated struct HubServiceEndpoint: Hashable, @unchecked Sendable {
    let key: String
    /// A `Network.NWEndpoint` (`.service`) for the real browser; `nil` for test doubles.
    let network: AnyHashable?

    init(key: String, network: AnyHashable? = nil) {
        self.key = key
        self.network = network
    }
}

/// One service instance as the browser currently sees it.
nonisolated struct HubBrowseResult: Hashable, Sendable {
    let serviceName: String
    let domain: String
    let txt: [String: String]
    let endpoint: HubServiceEndpoint
}

/// A hub in the "Find hubs" list: every browse result for the same hub collapsed into one row.
nonisolated struct DiscoveredHub: Identifiable, Hashable, Sendable {
    /// `hub:<hub_id>`, or `service:<name>` for an announcement without a valid hub_id.
    let id: String
    let serviceName: String
    let advertisement: HubAdvertisement
    /// Every endpoint announcing this hub (e.g. one per network interface), tried in order.
    let endpoints: [HubServiceEndpoint]

    var hubID: String? { advertisement.hubID }
    var problem: HubAdvertisementProblem? { advertisement.problem }

    /// The rows for a browser's current result set: one per hub_id (the same hub seen on two
    /// interfaces, or briefly under an old and a new name, is one row), sorted by name. Only what
    /// the browser currently reports — a service that went away is simply no longer here.
    static func merge(_ results: [HubBrowseResult]) -> [DiscoveredHub] {
        var order: [String] = []
        var grouped: [String: [HubBrowseResult]] = [:]
        for result in results {
            let advertisement = HubAdvertisement(txt: result.txt)
            let id = advertisement.hubID.map { "hub:" + $0 } ?? "service:" + result.serviceName.lowercased()
            if grouped[id] == nil { order.append(id) }
            grouped[id, default: []].append(result)
        }
        return order.compactMap { id -> DiscoveredHub? in
            guard let group = grouped[id] else { return nil }
            let sorted = group.sorted { lhs, rhs in
                lhs.serviceName != rhs.serviceName ? lhs.serviceName < rhs.serviceName : lhs.endpoint.key < rhs.endpoint.key
            }
            guard let first = sorted.first else { return nil }
            var endpoints: [HubServiceEndpoint] = []
            for result in sorted where !endpoints.contains(result.endpoint) {
                endpoints.append(result.endpoint)
            }
            return DiscoveredHub(
                id: id,
                serviceName: first.serviceName,
                advertisement: HubAdvertisement(txt: first.txt),
                endpoints: endpoints
            )
        }
        .sorted { lhs, rhs in
            switch lhs.serviceName.localizedStandardCompare(rhs.serviceName) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return lhs.id < rhs.id
            }
        }
    }
}

/// The hub the user chose from the list, remembered across launches. The Live connection follows
/// it by `hubID`: a new `baseURL` for the same hub is the same data source; another hub is not.
nonisolated struct SelectedHub: Codable, Hashable, Sendable {
    let hubID: String
    /// The Bonjour instance name when it was chosen — shown in Settings, never trusted.
    let serviceName: String
    /// The address `/api/v1/health` answered with this `hubID` from, e.g. `http://192.168.50.129:8787`.
    let baseURL: String
    let verifiedAt: Date

    /// The same hub, verified again at `baseURL`.
    func relocated(to baseURL: URL, serviceName: String, at date: Date) -> SelectedHub {
        SelectedHub(hubID: hubID, serviceName: serviceName, baseURL: baseURL.absoluteString, verifiedAt: date)
    }

    var usableBaseURL: URL? { WatchSettings.usableURL(baseURL) }

    /// The stored form (a JSON string, so `@AppStorage` can observe it). Empty means no selection.
    var storedValue: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    init(hubID: String, serviceName: String, baseURL: String, verifiedAt: Date) {
        self.hubID = hubID
        self.serviceName = serviceName
        self.baseURL = baseURL
        self.verifiedAt = verifiedAt
    }

    /// `nil` for an empty, damaged or unusable stored value — the app then connects by address,
    /// exactly as before the hub was chosen.
    init?(storedValue: String?) {
        guard
            let storedValue, !storedValue.isEmpty,
            let decoded = try? JSONDecoder().decode(SelectedHub.self, from: Data(storedValue.utf8)),
            HubBonjour.isValidHubID(decoded.hubID),
            decoded.usableBaseURL != nil
        else { return nil }
        self = decoded
    }
}

/// `GET /api/v1/health`, as far as recognizing a hub needs it. Unknown fields are ignored.
nonisolated struct HubHealthDTO: Decodable, Hashable, Sendable {
    let schemaVersion: Int
    let service: String?
    let hubID: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case service
        case hubID = "hub_id"
    }
}

/// Why a discovered hub wasn't connected to. Nothing is applied in any of these cases.
nonisolated enum HubVerificationError: Error, Hashable, Sendable {
    case invalidAdvertisement(HubAdvertisementProblem)
    /// The Bonjour service couldn't be resolved to an address (it may have just gone away).
    case resolveFailed(String)
    /// The address didn't answer `/api/v1/health`.
    case unreachable(String)
    /// It answered, but not as the Jogakbo sensor API.
    case notSensorAPI
    case unsupportedSchemaVersion(Int)
    /// The API is too old to report a hub_id.
    case missingHubID
    /// The API answered for another hub than the one announced (or remembered).
    case hubIDMismatch(expected: String, answered: String)

    var message: String {
        switch self {
        case .invalidAdvertisement(.missingHubID), .missingHubID:
            return String(localized: "허브 ID를 알려주지 않는 서비스라 연결할 수 없습니다. 허브를 최신 버전으로 업데이트하세요.", comment: "Hub discovery: the service has no hub_id")
        case .invalidAdvertisement(.unsupportedAPI), .unsupportedSchemaVersion:
            return String(localized: "이 앱이 지원하지 않는 API 버전입니다.", comment: "Hub discovery: unsupported API version")
        case let .resolveFailed(detail):
            return String(localized: "허브 주소를 확인하지 못했습니다. (\(detail))", comment: "Hub discovery: Bonjour service could not be resolved; argument is a technical detail")
        case let .unreachable(detail):
            return String(localized: "허브가 응답하지 않습니다. (\(detail))", comment: "Hub discovery: health check failed; argument is a technical detail")
        case .notSensorAPI:
            return String(localized: "조각보 센서 API가 아닙니다.", comment: "Hub discovery: the answering server is not the sensor API")
        case .hubIDMismatch:
            return String(localized: "광고한 허브와 응답한 허브가 달라 연결하지 않았습니다.", comment: "Hub discovery: advertised and answered hub_id differ")
        }
    }
}

nonisolated enum HubHealthCheck {
    /// Accepts `data` only as the Jogakbo sensor API, a supported version, answering for
    /// `expectedHubID`.
    static func verify(_ data: Data, expectedHubID: String) throws -> HubHealthDTO {
        guard let health = try? JSONDecoder().decode(HubHealthDTO.self, from: data) else {
            throw HubVerificationError.notSensorAPI
        }
        guard health.service == HubBonjour.apiServiceName else { throw HubVerificationError.notSensorAPI }
        guard health.schemaVersion == HubBonjour.supportedSchemaVersion else {
            throw HubVerificationError.unsupportedSchemaVersion(health.schemaVersion)
        }
        guard let answered = health.hubID?.lowercased(), HubBonjour.isValidHubID(answered) else {
            throw HubVerificationError.missingHubID
        }
        guard answered == expectedHubID.lowercased() else {
            throw HubVerificationError.hubIDMismatch(expected: expectedHubID, answered: answered)
        }
        return health
    }
}
