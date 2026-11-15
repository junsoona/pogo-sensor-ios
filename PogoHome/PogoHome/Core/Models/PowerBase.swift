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
    /// Whether the hub can unenroll this Base remotely (see `PowerBaseManagementSupport`).
    let management: PowerBaseManagementSupport
    /// How the erase behind a removal of this Base would be confirmed to the hub, as the hub says.
    /// `unspecified` from a hub that does not say, and for a Base it cannot remove.
    let eraseConfirmation: PowerBaseEraseConfirmation
    /// The registration the hub lists for this Base (32 lower-case hex digits, no secret): what a
    /// request to take the Base out of the hub's list must name, so that it can never remove a
    /// later registration. `nil` from a hub that cannot do that, or that has no record of the Base.
    let record: String?
    /// How many removals were asked of the listed registration so far, as the hub says
    /// (`removal_serial`). A request for a removal names the registration **and** this number,
    /// both as they were when the user confirmed (`removalBinding`): the hub then carries the
    /// request out only for that registration, and at most once. `nil` from a hub that takes no
    /// such request (Linux bridge 0.4.2 and earlier), and for a Base it cannot remove.
    /// `Int64`, not `Int`: the hub counts in 32 bits unsigned (`PowerBaseRemovalBinding.serialRange`).
    let removalSerial: Int64?

    init(
        hardwareIdentifier: String, isOnline: Bool, moduleCount: Int, onlineModuleCount: Int,
        management: PowerBaseManagementSupport = .unknown,
        eraseConfirmation: PowerBaseEraseConfirmation = .unspecified,
        record: String? = nil,
        removalSerial: Int64? = nil
    ) {
        let raw = hardwareIdentifier.lowercased()
        self.id = PowerBaseIdentity.stableUUID(forRawIdentifier: raw)
        self.hardwareIdentifier = raw
        self.isOnline = isOnline
        self.moduleCount = moduleCount
        self.onlineModuleCount = onlineModuleCount
        self.management = management
        self.eraseConfirmation = management == .supported ? eraseConfirmation : .unspecified
        self.record = record.flatMap { PowerBaseRemovalID.isValid($0) ? $0 : nil }
        // Said of a Base the hub can remove, and of no other; a number that is no count is no word.
        self.removalSerial = management == .supported
            ? removalSerial.flatMap { PowerBaseRemovalBinding.isValidSerial($0) ? $0 : nil } : nil
    }

    /// What a request for this Base's removal names: the registration the hub lists and that
    /// registration's removal serial. `nil` when the hub does not give both -- then no removal
    /// is asked of it at all (a request that named the Base alone could reach another
    /// registration than the one on screen).
    var removalBinding: PowerBaseRemovalBinding? {
        guard management == .supported, let record, let removalSerial else { return nil }
        return PowerBaseRemovalBinding(record: record, serial: removalSerial)
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
