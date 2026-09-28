import Foundation

/// Which POGO data source sensor data came from: the app's simulated data, or one particular Linux
/// sensor hub. Data from one source is never shown as another's: switching between simulated and
/// live data, or to another hub, starts again from nothing (`AppModel.replace(dataSource:identity:)`,
/// `HomeGlanceBuilder`, `WatchSyncEngine`), while the same hub reconnecting keeps its last values.
///
/// Compiled into the iPhone app and the Watch app.
nonisolated struct SensorSourceIdentity: Hashable, Sendable, CustomStringConvertible {
    /// Stable text form, stored with a glance's POGO part (`HomeGlancePogoSection.sourceID`).
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let simulated = SensorSourceIdentity(rawValue: "mock")

    /// The hub at `baseURL`. Addresses that differ only in letter case, an explicit default port
    /// or a trailing slash reach the same hub, so they are the same source.
    static func hub(_ baseURL: URL) -> SensorSourceIdentity {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return SensorSourceIdentity(rawValue: "hub:" + baseURL.absoluteString)
        }
        let scheme = components.scheme?.lowercased()
        components.scheme = scheme
        components.host = components.host?.lowercased()
        let defaultPort: Int? = switch scheme {
        case "http": 80
        case "https": 443
        default: nil
        }
        if let port = components.port, port == defaultPort {
            components.port = nil
        }
        while components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath.removeLast()
        }
        return SensorSourceIdentity(rawValue: "hub:" + (components.string ?? baseURL.absoluteString))
    }

    /// The hub with this `hub_id` (see `SelectedHub`), at whatever address it currently has — the
    /// identity of a hub picked in "Find hubs". Never equal to an address-based `hub(_:)`.
    static func hub(id hubID: String) -> SensorSourceIdentity {
        SensorSourceIdentity(rawValue: "hub-id:" + hubID.lowercased())
    }

    /// A source that is the same as no other — for a data source whose origin isn't known
    /// (tests), so replacing it always starts from nothing.
    static func unique() -> SensorSourceIdentity {
        SensorSourceIdentity(rawValue: "unique:" + UUID().uuidString)
    }

    var isSimulated: Bool { self == .simulated }

    /// A Linux sensor hub, identified by its address or by its `hub_id`.
    var isHub: Bool { rawValue.hasPrefix("hub:") || hubID != nil }

    /// The `hub_id` of a hub picked in "Find hubs"; `nil` for any other source.
    var hubID: String? {
        rawValue.hasPrefix("hub-id:") ? String(rawValue.dropFirst("hub-id:".count)) : nil
    }

    var description: String { rawValue }
}

nonisolated extension HomeGlancePogoSection {
    /// Whether this POGO part was written from `source`. A part written before glances recorded
    /// their source only says whether it was simulated.
    func isFrom(_ source: SensorSourceIdentity) -> Bool {
        if let sourceID { return sourceID == source.rawValue }
        return isSimulated == source.isSimulated
    }

    /// Nothing received yet from `source`.
    static func empty(from source: SensorSourceIdentity) -> HomeGlancePogoSection {
        var section = HomeGlancePogoSection.empty
        section.isSimulated = source.isSimulated
        section.sourceID = source.rawValue
        return section
    }
}

nonisolated extension HomeGlanceSnapshot {
    /// This glance, with its POGO part and values dropped unless they came from `source`. Apple
    /// Home's part is never touched.
    func keepingPogo(from source: SensorSourceIdentity) -> HomeGlanceSnapshot {
        guard !pogo.isFrom(source) else { return self }
        var glance = self
        glance.pogo = .empty(from: source)
        glance.sensors = appleHomeSensors
        return glance
    }
}

nonisolated extension WatchSettings {
    /// The POGO source these settings point at: simulated data, the hub with `hubID` (a hub picked
    /// in "Find hubs" on the iPhone), or the hub at `hubBaseURL`. `nil` in live mode without a
    /// usable address.
    var pogoSource: SensorSourceIdentity? {
        switch dataSourceMode {
        case .mock: return .simulated
        case .live:
            guard let url = directHubURL else { return nil }
            return hubID.map { SensorSourceIdentity.hub(id: $0) } ?? .hub(url)
        }
    }
}
