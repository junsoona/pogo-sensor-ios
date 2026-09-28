import Foundation

/// Which `SensorDataSource` the app is currently using. Persisted via `@AppStorage`.
enum DataSourceMode: String, CaseIterable, Identifiable, Sendable {
    case live
    case mock

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .live: return String(localized: "실제 기기 (Live)", comment: "Data source option")
        case .mock: return String(localized: "모의 데이터", comment: "Data source option: simulated data")
        }
    }
}

enum PogoSettingsKeys {
    static let dataSourceMode = "pogohome.settings.dataSourceMode"
    static let liveBaseURL = "pogohome.settings.liveBaseURL"
    /// `SelectedHub.storedValue` of the hub picked in "Find hubs"; empty (or absent) when the
    /// Live connection uses the address typed in Settings.
    static let selectedHub = "pogohome.settings.selectedHub"
}

/// What the app should be connected to: which data source (`identity`) and, for a hub, at which
/// address. Two targets with the same identity but different addresses are the same hub moved.
nonisolated struct SensorSourceTarget: Hashable, Sendable {
    let identity: SensorSourceIdentity
    /// `nil` for simulated data.
    let address: URL?
    /// Set when the connection follows a hub picked in "Find hubs".
    let selectedHub: SelectedHub?
}

/// Builds a `SensorDataSource` for the requested mode. The one place that knows how a
/// `DataSourceMode` + URL string turns into a concrete data source, so Settings and the
/// app entry point never construct `LiveSensorDataSource`/`MockSensorDataSource` directly.
enum DataSourceFactory {
    /// The single rule for what the settings point at:
    /// - simulated data in mock mode;
    /// - in live mode, a hub picked in "Find hubs" is followed by its `hub_id` at its last verified
    ///   address (so the same hub at a new address stays the same source);
    /// - otherwise the address typed in Settings, identified by that address (the flow before
    ///   hubs could be found).
    static func target(mode: DataSourceMode, liveBaseURLString: String, selectedHubValue: String?) -> SensorSourceTarget {
        switch mode {
        case .mock:
            return SensorSourceTarget(identity: .simulated, address: nil, selectedHub: nil)
        case .live:
            if let hub = SelectedHub(storedValue: selectedHubValue), let url = hub.usableBaseURL {
                return SensorSourceTarget(identity: .hub(id: hub.hubID), address: url, selectedHub: hub)
            }
            let url = resolvedLiveBaseURL(from: liveBaseURLString)
            return SensorSourceTarget(identity: .hub(url), address: url, selectedHub: nil)
        }
    }

    /// `target(mode:liveBaseURLString:selectedHubValue:)` from the stored settings.
    static func target(in defaults: UserDefaults) -> SensorSourceTarget {
        target(
            mode: DataSourceMode(rawValue: defaults.string(forKey: PogoSettingsKeys.dataSourceMode) ?? "") ?? .live,
            liveBaseURLString: defaults.string(forKey: PogoSettingsKeys.liveBaseURL) ?? PogoAPIEndpoint.defaultBaseURLString,
            selectedHubValue: defaults.string(forKey: PogoSettingsKeys.selectedHub)
        )
    }

    static func makeDataSource(for target: SensorSourceTarget) -> SensorDataSource {
        guard let address = target.address else { return MockSensorDataSource() }
        return LiveSensorDataSource(endpoint: PogoAPIEndpoint(baseURL: address))
    }

    static func makeDataSource(mode: DataSourceMode, liveBaseURLString: String) -> SensorDataSource {
        makeDataSource(for: target(mode: mode, liveBaseURLString: liveBaseURLString, selectedHubValue: nil))
    }

    /// Which source `makeDataSource(mode:liveBaseURLString:)` connects to for the same settings —
    /// what `AppModel` compares to tell a new source from the one it already has.
    static func identity(mode: DataSourceMode, liveBaseURLString: String) -> SensorSourceIdentity {
        target(mode: mode, liveBaseURLString: liveBaseURLString, selectedHubValue: nil).identity
    }

    /// Makes `hub` the Live connection. The choice is written before the address: whichever change
    /// the app reacts to first already resolves to the new target, so the connection moves once.
    static func apply(_ hub: SelectedHub, in defaults: UserDefaults) {
        defaults.set(hub.storedValue, forKey: PogoSettingsKeys.selectedHub)
        defaults.set(hub.baseURL, forKey: PogoSettingsKeys.liveBaseURL)
        if DataSourceMode(rawValue: defaults.string(forKey: PogoSettingsKeys.dataSourceMode) ?? "") != .live {
            defaults.set(DataSourceMode.live.rawValue, forKey: PogoSettingsKeys.dataSourceMode)
        }
    }

    /// Falls back to the default host whenever the stored string is empty or isn't a
    /// valid URL, so a bad Settings edit can never leave the app without a usable source.
    static func resolvedLiveBaseURL(from string: String) -> URL {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil, url.host != nil {
            return url
        }
        return URL(string: PogoAPIEndpoint.defaultBaseURLString)!
    }
}
