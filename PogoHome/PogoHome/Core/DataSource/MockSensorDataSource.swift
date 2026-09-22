import Foundation

/// Produces mock sensor data for the app before a real Linux-backed data source exists.
///
/// Module identifiers and room placement come from `MockSensorFixtures` and never change
/// for the lifetime of an instance. Only `.normal`/`.conditioning` readings on online
/// modules drift over time, so the stale/unavailable fixtures stay meaningful examples of
/// those states throughout a run.
@MainActor
final class MockSensorDataSource: SensorDataSource {
    private var snapshot: HomeSnapshot
    private let tickInterval: Duration

    init(tickInterval: Duration = .seconds(4)) {
        self.tickInterval = tickInterval
        self.snapshot = HomeSnapshot(
            timestamp: Date(),
            rooms: MockSensorFixtures.rooms,
            modules: MockSensorFixtures.modules(referenceDate: Date())
        )
    }

    func currentSnapshot() async throws -> HomeSnapshot {
        snapshot
    }

    func updates() -> AsyncStream<HomeSnapshot> {
        AsyncStream { continuation in
            let task = Task { [tickInterval] in
                // `AppModel` relies on `updates()` delivering current state as its first
                // element instead of separately calling `currentSnapshot()`, so the very
                // first tick can't wait a full `tickInterval`.
                continuation.yield(self.snapshot)
                while !Task.isCancelled {
                    try? await Task.sleep(for: tickInterval)
                    if Task.isCancelled { break }
                    let next = self.jittered(self.snapshot)
                    self.snapshot = next
                    continuation.yield(next)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func jittered(_ snapshot: HomeSnapshot) -> HomeSnapshot {
        let updatedModules = snapshot.modules.map { module -> SensorModule in
            guard module.isOnline else { return module }
            let updatedReadings = module.readings.map { reading -> SensorReading in
                guard reading.status == .normal || reading.status == .conditioning else {
                    return reading
                }
                return SensorReading(
                    id: reading.id,
                    kind: reading.kind,
                    value: driftedValue(for: reading.kind, from: reading.value),
                    timestamp: Date(),
                    status: reading.status
                )
            }
            return SensorModule(
                id: module.id,
                name: module.name,
                roomID: module.roomID,
                readings: updatedReadings,
                isOnline: module.isOnline,
                lastSeen: Date(),
                roleDescription: module.roleDescription
            )
        }
        return HomeSnapshot(timestamp: Date(), rooms: snapshot.rooms, modules: updatedModules)
    }

    private func driftedValue(for kind: SensorKind, from currentValue: Double) -> Double {
        let range = plausibleRange(for: kind)
        let step = (range.upperBound - range.lowerBound) * 0.02
        let delta = Double.random(in: -step...step)
        return min(max(currentValue + delta, range.lowerBound), range.upperBound)
    }

    private func plausibleRange(for kind: SensorKind) -> ClosedRange<Double> {
        switch kind {
        case .temperature: return 15...30
        case .humidity: return 25...70
        case .illuminance: return 0...2000
        case .pm1: return 0...50
        case .pm2_5: return 0...80
        case .pm10: return 0...120
        case .vocRaw, .noxRaw: return 0...500
        case .vocIndex, .noxIndex: return 1...500
        }
    }
}
