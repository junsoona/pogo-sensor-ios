import Foundation

/// Which Apple Home accessories the Control Center toggle may switch. Decided only from what
/// HomeKit exposes (`AppleHomeCapabilities`), the same way the device tile's icon is:
///
/// - exactly one on/off control on the whole accessory (a power strip with several outlets is
///   left out — which outlet the toggle means would be a guess),
/// - that control is `PowerState` — readable and writable — on a light, outlet or switch
///   service. Fans and air purifiers (`Active`, often with more modes), locks, doors,
///   thermostats and sensors are never offered.
///
/// Reachability doesn't matter for being listed (a device that is off at the wall should still
/// be selectable); it is checked when the toggle runs.
nonisolated enum AppleHomePowerEligibility {
    enum Verdict: Equatable, Sendable {
        case eligible(characteristicID: UUID, kind: AppleHomePowerTargetKind)
        case notEligible(Reason)
    }

    enum Reason: Equatable, Sendable {
        case noOnOffControl
        case multipleOnOffControls(Int)
        /// The only on/off control isn't a light's, outlet's or switch's `PowerState`.
        case unsupportedService
    }

    static func evaluate(_ accessory: AppleHomeAccessory) -> Verdict {
        let controls = AppleHomeQuickControl.onOffControls(of: accessory)
        guard let control = controls.first else { return .notEligible(.noOnOffControl) }
        guard controls.count == 1 else { return .notEligible(.multipleOnOffControls(controls.count)) }
        guard control.kind == .power,
              let service = accessory.services.first(where: { $0.characteristics.contains { $0.id == control.id } }),
              let kind = targetKind(of: service.kind)
        else { return .notEligible(.unsupportedService) }
        return .eligible(characteristicID: control.id, kind: kind)
    }

    static func targetID(of accessory: AppleHomeAccessory) -> AppleHomePowerTargetID? {
        guard case let .eligible(characteristicID, _) = evaluate(accessory) else { return nil }
        return AppleHomePowerTargetID(homeID: accessory.homeID, accessoryID: accessory.id, characteristicID: characteristicID)
    }

    private static func targetKind(of service: AppleHomeServiceKind) -> AppleHomePowerTargetKind? {
        switch service {
        case .lightbulb: return .light
        case .outlet: return .outlet
        case .switch: return .switch
        default: return nil
        }
    }
}

/// Turns what the app knows about Apple Home into the catalog the control reads.
nonisolated enum AppleHomePowerCatalogBuilder {
    /// A value the app has read from a device, with when it was read.
    struct ConfirmedPower: Equatable, Sendable {
        let isOn: Bool
        let at: Date
    }

    /// - Parameters:
    ///   - confirmedPower: the app's own confirmed state of a target (`nil` = not known now).
    ///   - previous: the stored catalog, whose newer states (e.g. from the toggle) are kept.
    /// - Returns: `nil` while Apple Home's state isn't settled (loading, or not started yet in
    ///   this process) — the stored catalog is then left as it is.
    static func build(
        isEnabled: Bool,
        snapshot: AppleHomeSnapshot,
        confirmedPower: (AppleHomeAccessory, UUID) -> ConfirmedPower?,
        previous: AppleHomePowerCatalog?,
        now: Date
    ) -> AppleHomePowerCatalog? {
        let knownNames = previous?.knownNames ?? [:]
        guard isEnabled else {
            return AppleHomePowerCatalog(writtenAt: now, availability: .off, targets: [], states: [:], knownNames: knownNames)
        }
        let availability: AppleHomePowerAvailability
        switch snapshot.accessState {
        case .ready: availability = .ready
        case .denied: availability = .denied
        case .restricted: availability = .restricted
        case .noHome: availability = .noHome
        case .off, .loading, .unsupported: return nil
        }
        guard availability == .ready else {
            return AppleHomePowerCatalog(writtenAt: now, availability: availability, targets: [], states: [:], knownNames: knownNames)
        }

        var targets: [AppleHomePowerTarget] = []
        var states: [String: AppleHomePowerState] = [:]
        var names = knownNames
        for accessory in snapshot.accessories {
            guard case let .eligible(characteristicID, kind) = AppleHomePowerEligibility.evaluate(accessory) else { continue }
            let id = AppleHomePowerTargetID(homeID: accessory.homeID, accessoryID: accessory.id, characteristicID: characteristicID)
            targets.append(AppleHomePowerTarget(
                id: id,
                name: accessory.name,
                roomName: accessory.roomName,
                homeName: snapshot.home(with: accessory.homeID)?.name ?? "",
                kind: kind
            ))
            names[id.stringValue] = accessory.name
            let stored = previous?.state(id)
            if let confirmed = confirmedPower(accessory, characteristicID),
               confirmed.at > (stored?.checkedAt ?? .distantPast) {
                states[id.stringValue] = AppleHomePowerState(
                    isOn: confirmed.isOn,
                    checkedAt: confirmed.at,
                    lastResult: stored?.lastResult,
                    resultAt: stored?.resultAt
                )
            } else if let stored {
                // Newer than anything the app read itself (e.g. the toggle just confirmed it).
                states[id.stringValue] = stored
            }
        }
        return AppleHomePowerCatalog(writtenAt: now, availability: .ready, targets: targets, states: states, knownNames: names)
    }
}
