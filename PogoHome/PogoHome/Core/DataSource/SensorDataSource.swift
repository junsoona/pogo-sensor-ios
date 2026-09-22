import Foundation

/// Abstraction over wherever sensor data comes from. `MockSensorDataSource` and
/// `LiveSensorDataSource` (backed by the Linux PogoHome API) both conform, and `AppModel`
/// never talks to either one directly.
protocol SensorDataSource {
    func currentSnapshot() async throws -> HomeSnapshot
    func updates() -> AsyncStream<HomeSnapshot>

    /// Connection lifecycle updates for display in Settings. Defaults to a single
    /// `.connected` value, which is all a source with no real connection concept (like
    /// `MockSensorDataSource`) needs to report.
    func connectionStatusUpdates() -> AsyncStream<DataSourceConnectionStatus>

    /// How often, in seconds, `AppModel` should independently call `currentSnapshot()` on
    /// top of whatever `updates()` delivers — `nil` (the default) disables this entirely.
    ///
    /// This exists because `updates()` alone cannot be trusted to always carry a timely
    /// signal that a source has converged on a full, authoritative state: for
    /// `LiveSensorDataSource`, an SSE connection can stay technically open and "alive"
    /// (heartbeats or not) without ever delivering another `snapshot` event, so a data
    /// source that wants recovery to be independently guaranteed opts into periodic
    /// polling here instead of `AppModel` special-casing any concrete type.
    var periodicRefreshInterval: Double? { get }
}

extension SensorDataSource {
    func connectionStatusUpdates() -> AsyncStream<DataSourceConnectionStatus> {
        AsyncStream { continuation in
            continuation.yield(.connected)
            continuation.finish()
        }
    }

    var periodicRefreshInterval: Double? { nil }
}
