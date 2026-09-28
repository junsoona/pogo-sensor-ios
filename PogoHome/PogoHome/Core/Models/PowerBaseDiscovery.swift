import Foundation

/// Watches for a Power Base the bridge starts reporting after a baseline moment (e.g. when
/// the "POGO Power Base 연결" screen opened). Only reports Bases that really appeared in bridge
/// data — it never claims a Base was registered by the app, because the app can't register one.
nonisolated struct PowerBaseDiscovery: Hashable, Sendable {
    let baselineIdentifiers: Set<String>

    init(baseline snapshot: HomeSnapshot) {
        self.baselineIdentifiers = Set(snapshot.powerBases.map(\.hardwareIdentifier))
    }

    /// Bases in `snapshot` that were not in the baseline, in the bridge's order.
    func newPowerBases(in snapshot: HomeSnapshot) -> [PowerBase] {
        snapshot.powerBases.filter { !baselineIdentifiers.contains($0.hardwareIdentifier) }
    }
}
