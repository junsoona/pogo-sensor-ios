import Foundation

/// Which `SensorDataSource` the app is currently using. Persisted via `@AppStorage`.
enum DataSourceMode: String, CaseIterable, Identifiable, Sendable {
    case live
    case mock

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .live: return "실제 기기 (Live)"
        case .mock: return "모의 데이터"
        }
    }
}

enum PogoSettingsKeys {
    static let dataSourceMode = "pogohome.settings.dataSourceMode"
    static let liveBaseURL = "pogohome.settings.liveBaseURL"
}

/// Builds a `SensorDataSource` for the requested mode. The one place that knows how a
/// `DataSourceMode` + URL string turns into a concrete data source, so Settings and the
/// app entry point never construct `LiveSensorDataSource`/`MockSensorDataSource` directly.
enum DataSourceFactory {
    static func makeDataSource(mode: DataSourceMode, liveBaseURLString: String) -> SensorDataSource {
        switch mode {
        case .mock:
            return MockSensorDataSource()
        case .live:
            return LiveSensorDataSource(endpoint: PogoAPIEndpoint(baseURL: resolvedLiveBaseURL(from: liveBaseURLString)))
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
