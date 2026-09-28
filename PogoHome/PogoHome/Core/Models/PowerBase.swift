import Foundation

/// One POGO Power Base as the Linux bridge reports it (`power_bases` in the API snapshot).
///
/// A Power Base is identified by its own eFuse EUI-64 (`hardwareIdentifier`, 16 hex digits),
/// which the Base sends with every message. It is the root of one POGO chain: every module in
/// `HomeSnapshot.modules` whose `powerBaseIdentifier` matches belongs to this Base.
nonisolated struct PowerBase: Identifiable, Hashable, Sendable {
    let id: UUID
    let hardwareIdentifier: String
    /// The bridge heard from this Base (heartbeat or report) within its stale timeout.
    let isOnline: Bool
    /// Modules the bridge currently lists under this Base, and how many of them are online.
    let moduleCount: Int
    let onlineModuleCount: Int

    init(hardwareIdentifier: String, isOnline: Bool, moduleCount: Int, onlineModuleCount: Int) {
        let raw = hardwareIdentifier.lowercased()
        self.id = PowerBaseIdentity.stableUUID(forRawIdentifier: raw)
        self.hardwareIdentifier = raw
        self.isOnline = isOnline
        self.moduleCount = moduleCount
        self.onlineModuleCount = onlineModuleCount
    }

    /// Short label that tells two Bases apart without showing the full identifier, e.g.
    /// "Power Base ··d357". Uses the same last-two-bytes suffix as the firmware and bridge logs.
    var shortLabel: String {
        "Power Base ··\(hardwareIdentifier.suffix(4))"
    }
}

nonisolated enum PowerBaseIdentity {
    /// Same derivation as `ModuleIdentity.stableUUID`, in its own namespace, so a Base and a
    /// module can never map to the same app identifier.
    static func stableUUID(forRawIdentifier raw: String) -> UUID {
        ModuleIdentity.stableUUID(forRawIdentifier: raw, namespace: "pogohome.powerbase.v1")
    }
}
