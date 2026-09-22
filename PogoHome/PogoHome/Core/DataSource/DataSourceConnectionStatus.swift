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
        case .idle: return "대기 중"
        case .connecting: return "연결 중…"
        case .connected: return "연결됨"
        case let .reconnecting(attempt): return "재연결 중 (\(attempt)회)…"
        case let .failed(message): return "오류: \(message)"
        }
    }
}
