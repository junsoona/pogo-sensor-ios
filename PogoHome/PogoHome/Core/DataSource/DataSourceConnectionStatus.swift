import Foundation

/// Connection lifecycle for a `SensorDataSource`, surfaced to Settings so the user can see
/// whether Live mode is actually connected. `MockSensorDataSource` never reports anything
/// but `.connected` (see the default in `SensorDataSource`); this type only has real
/// texture for `LiveSensorDataSource`.
nonisolated enum DataSourceConnectionStatus: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(String)

    var displayText: String {
        switch self {
        case .idle: return String(localized: "대기 중", comment: "Connection status")
        case .connecting: return String(localized: "연결 중…", comment: "Connection status")
        case .connected: return String(localized: "연결됨", comment: "Connection status")
        case let .reconnecting(attempt): return String(localized: "재연결 중 (\(attempt)회)…", comment: "Connection status with attempt number")
        case let .failed(message): return String(localized: "오류: \(message)", comment: "Connection status with an error description")
        }
    }
}
