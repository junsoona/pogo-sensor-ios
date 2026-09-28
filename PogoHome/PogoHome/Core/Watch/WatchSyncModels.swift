import Foundation

// What the iPhone app and the Apple Watch app exchange over WatchConnectivity, and what the Watch
// remembers about reaching the POGO bridge. Plain `Codable` values only — no WatchConnectivity
// types — so the rules are unit-tested in the iPhone test target. Compiled into the iPhone app,
// the Watch app and the Watch widget extension.
//
// Who does what:
// - The iPhone is the only writer of settings: the bridge address, the data source mode, which
//   values the Watch lists, and the user's module/room names. It sends them with every glance it
//   hands over (`WatchSyncPayload`), so the Watch never has a glance without matching settings.
// - The Watch reads the bridge itself when it can (`WatchPogoPath.direct`) and otherwise asks the
//   iPhone (`.phone`). Neither can reach the bridge from outside the home network; then the Watch
//   keeps the last values with the time they were confirmed and never presents them as current.

/// How a POGO confirmation reached the Watch.
nonisolated enum WatchPogoPath: String, Codable, Hashable, Sendable {
    /// The Watch fetched the bridge's snapshot itself (it was on the bridge's network).
    case direct
    /// The iPhone app confirmed it — over its live connection, or with a fetch it made when the
    /// Watch asked.
    case phone
}

/// The name and room the user gave a POGO module on the iPhone. The Watch has no configuration
/// store of its own, so values it fetches directly are named with these.
nonisolated struct WatchModuleLabel: Codable, Hashable, Sendable {
    let moduleID: UUID
    let name: String
    let roomName: String?
}

/// The iPhone's settings as far as the Watch needs them.
nonisolated struct WatchSettings: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1
    /// The most values the Watch screen lists.
    static let maximumSelectedValues = 4

    enum DataSourceMode: String, Codable, Hashable, Sendable {
        case live
        case mock
    }

    var schemaVersion: Int
    /// When the iPhone produced these settings (its clock). The Watch keeps the newest it received,
    /// so a late-delivered older message never undoes a newer one.
    var updatedAt: Date
    var dataSourceMode: DataSourceMode
    /// The bridge address the iPhone itself connects to; `nil` if it isn't a usable http(s) URL.
    var hubBaseURL: String?
    /// The `hub_id` of the hub the iPhone picked in "Find hubs"; `nil` for an address typed by hand
    /// (and in settings from an iPhone app that predates it). Values of the same hub at a new
    /// address stay this Watch's; see `pogoSource`.
    var hubID: String?
    /// `HomeGlanceValueID.stringValue`s, in the order the Watch lists them.
    var selectedValueIDs: [String]
    var moduleLabels: [WatchModuleLabel]

    init(
        updatedAt: Date,
        dataSourceMode: DataSourceMode,
        hubBaseURL: String?,
        hubID: String? = nil,
        selectedValueIDs: [String],
        moduleLabels: [WatchModuleLabel],
        schemaVersion: Int = WatchSettings.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.dataSourceMode = dataSourceMode
        self.hubBaseURL = hubBaseURL.flatMap { Self.usableURL($0)?.absoluteString }
        self.hubID = hubID
        self.selectedValueIDs = Self.normalizedSelection(selectedValueIDs)
        self.moduleLabels = moduleLabels
    }

    /// The bridge to fetch from directly: only in live mode, and only with a usable address.
    var directHubURL: URL? {
        guard dataSourceMode == .live else { return nil }
        return hubBaseURL.flatMap(Self.usableURL)
    }

    var selectedValues: [HomeGlanceValueID] {
        selectedValueIDs.compactMap(HomeGlanceValueID.init(stringValue:))
    }

    /// An absolute http(s) URL with a host, or `nil`.
    static func usableURL(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }

    /// Parseable, without duplicates, at most `maximumSelectedValues`, first choices first.
    static func normalizedSelection(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for id in ids where HomeGlanceValueID(stringValue: id) != nil && seen.insert(id).inserted {
            result.append(id)
            if result.count == maximumSelectedValues { break }
        }
        return result
    }

    /// Whether the Watch should replace `current` with `incoming`.
    static func shouldAccept(_ incoming: WatchSettings, over current: WatchSettings?) -> Bool {
        guard incoming.schemaVersion == currentSchemaVersion else { return false }
        guard let current else { return true }
        return incoming.updatedAt >= current.updatedAt
    }
}

/// One hand-over from the iPhone: its latest glance of the home, and its settings.
nonisolated struct WatchSyncPayload: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let sentAt: Date
    /// `nil` if the iPhone has nothing yet (e.g. its first launch, before any data).
    let glance: HomeGlanceSnapshot?
    let settings: WatchSettings

    init(sentAt: Date, glance: HomeGlanceSnapshot?, settings: WatchSettings, schemaVersion: Int = WatchSyncPayload.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.sentAt = sentAt
        self.glance = glance
        self.settings = settings
    }
}

/// The iPhone's answer when the Watch asks it for the home's current state.
nonisolated struct WatchRelayReply: Codable, Hashable, Sendable {
    enum Outcome: String, Codable, Hashable, Sendable {
        /// The iPhone confirmed the POGO state just now; the payload's glance carries it.
        case confirmed
        /// The iPhone reached the bridge, but its module list isn't complete yet; the previous
        /// values stay, not confirmed.
        case hubRecovering
        /// The iPhone couldn't reach the bridge either; the glance is its last stored state.
        case hubUnreachable
        /// The iPhone shows simulated data, not the bridge.
        case simulated
    }

    let outcome: Outcome
    let payload: WatchSyncPayload
}

/// WatchConnectivity carries property-list dictionaries. Payloads travel as JSON `Data` under
/// one key, so a damaged or foreign message is simply ignored.
nonisolated enum WatchSyncCoding {
    static let payloadKey = "pogo.payload"
    static let replyKey = "pogo.reply"
    static let requestKey = "pogo.request"
    static let refreshRequest = "refresh.v1"

    static func message(for payload: WatchSyncPayload) throws -> [String: Any] {
        [payloadKey: try encoder.encode(payload)]
    }

    static func payload(from message: [String: Any]) -> WatchSyncPayload? {
        guard
            let data = message[payloadKey] as? Data,
            let payload = try? decoder.decode(WatchSyncPayload.self, from: data),
            payload.schemaVersion == WatchSyncPayload.currentSchemaVersion,
            payload.glance.map({ $0.schemaVersion == HomeGlanceSnapshot.currentSchemaVersion }) ?? true
        else { return nil }
        return payload
    }

    static func message(for reply: WatchRelayReply) throws -> [String: Any] {
        [replyKey: try encoder.encode(reply)]
    }

    static func reply(from message: [String: Any]) -> WatchRelayReply? {
        guard
            let data = message[replyKey] as? Data,
            let reply = try? decoder.decode(WatchRelayReply.self, from: data),
            reply.payload.schemaVersion == WatchSyncPayload.currentSchemaVersion
        else { return nil }
        return reply
    }

    static var refreshRequestMessage: [String: Any] { [requestKey: refreshRequest] }

    static func isRefreshRequest(_ message: [String: Any]) -> Bool {
        message[requestKey] as? String == refreshRequest
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}

// MARK: - The Watch's own record

/// Why one way of reaching the POGO bridge produced no confirmation.
nonisolated enum WatchPathFailure: String, Codable, Hashable, Sendable {
    /// The Watch has no bridge address yet (the iPhone hasn't sent its settings).
    case notConfigured
    /// The iPhone shows simulated data; there is no bridge to read.
    case simulated
    /// No answer from the bridge address: not on the bridge's network, bridge off, time-out.
    case hubUnreachable
    /// The bridge answered with something unusable (HTTP error, damaged JSON, unknown schema).
    case badResponse
    /// The bridge answered, but its module list isn't complete yet (e.g. right after a restart):
    /// the previous values stay, not confirmed.
    case hubRecovering
    /// The iPhone can't be reached from the Watch right now.
    case phoneUnreachable
    /// The iPhone answered, but couldn't reach the bridge either.
    case phoneCannotReachHub
    /// The iPhone didn't answer in time.
    case phoneTimedOut
}

nonisolated enum WatchPathResult: Codable, Hashable, Sendable {
    case notTried
    case confirmed
    case failed(WatchPathFailure)

    var failure: WatchPathFailure? {
        if case let .failed(failure) = self { return failure }
        return nil
    }
}

/// One attempt to confirm the POGO state: the direct path first, then the iPhone.
nonisolated struct WatchSyncRound: Codable, Hashable, Sendable {
    let at: Date
    let direct: WatchPathResult
    let phone: WatchPathResult

    var confirmedBy: WatchPogoPath? {
        if direct == .confirmed { return .direct }
        if phone == .confirmed { return .phone }
        return nil
    }
}

/// Where and when the POGO values the Watch holds were last confirmed.
nonisolated struct WatchConfirmation: Codable, Hashable, Sendable {
    let path: WatchPogoPath
    let at: Date
}

nonisolated struct WatchSyncRecord: Codable, Hashable, Sendable {
    /// The latest finished round.
    var lastRound: WatchSyncRound?
    /// Matches the stored glance's POGO confirmation (`pogo.verifiedAt`).
    var lastConfirmation: WatchConfirmation?
    /// When the iPhone last handed over a glance on its own (not as an answer).
    var lastPushAt: Date?

    static let empty = WatchSyncRecord(lastRound: nil, lastConfirmation: nil, lastPushAt: nil)
}

/// Everything the Watch keeps between launches, in one file its widgets read too.
nonisolated struct WatchStoredState: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var glance: HomeGlanceSnapshot?
    var settings: WatchSettings?
    var record: WatchSyncRecord

    init(glance: HomeGlanceSnapshot?, settings: WatchSettings?, record: WatchSyncRecord, schemaVersion: Int = WatchStoredState.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.glance = glance
        self.settings = settings
        self.record = record
    }

    static let empty = WatchStoredState(glance: nil, settings: nil, record: .empty)
}
