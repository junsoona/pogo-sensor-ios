import Foundation

/// Where tapping a glance surface opens the app. Carried as a `pogohome://` URL
/// (`widgetURL`), and only ever navigates — no URL can change any state.
nonisolated enum HomeGlanceLink: Hashable, Sendable {
    /// The Dashboard (home tab) at its root.
    case dashboard
    /// The detail screen of one device, from its own source.
    case device(DeviceIdentifier)
    /// The Devices tab — where to check a selection that no longer exists.
    case devices

    static let scheme = "pogohome"

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .dashboard:
            components.host = "dashboard"
        case let .device(id):
            components.host = "device"
            components.path = "/\(id.source.rawValue)/\(id.rawValue.uuidString)"
        case .devices:
            components.host = "devices"
        }
        return components.url!
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, let host = url.host()?.lowercased() else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        switch (host, path.count) {
        case ("dashboard", 0):
            self = .dashboard
        case ("devices", 0):
            self = .devices
        case ("device", 2):
            guard let source = DeviceSource(rawValue: path[0]), let raw = UUID(uuidString: path[1]) else { return nil }
            self = .device(DeviceIdentifier(source: source, rawValue: raw))
        default:
            return nil
        }
    }
}
