import Foundation

// What the Watch app and its widgets may say about the stored state at a given moment. Views
// only render these verdicts; every rule about age, connection and what may be called current
// lives here, on top of `HomeGlancePresentation`, so the Watch and the iPhone widgets agree.

/// The POGO line at the top of the Watch app and in the home status complication.
nonisolated enum WatchPogoHeadline: Equatable, Sendable {
    /// Nothing has reached the Watch yet.
    case noData
    /// The bridge answered, but hasn't reported complete readings yet.
    case waitingForData
    case healthy(online: Int, total: Int, confirmedAt: Date)
    case attentionNeeded(count: Int, online: Int, total: Int, confirmedAt: Date)
    /// The latest attempt couldn't confirm the state. The last values are still shown, with
    /// their time, until they turn stale.
    case notConfirmed(lastConfirmedAt: Date?)
    /// The last confirmation is older than `HomeGlanceFreshness.staleAfter`.
    case stale(lastConfirmedAt: Date?)

    var confirmedAt: Date? {
        switch self {
        case .noData, .waitingForData: return nil
        case let .healthy(_, _, at), let .attentionNeeded(_, _, _, at): return at
        case let .notConfirmed(at), let .stale(at): return at
        }
    }

    /// A recent confirmation the Watch may state as the home's state.
    var isCurrent: Bool {
        switch self {
        case .healthy, .attentionNeeded: return true
        case .noData, .waitingForData, .notConfirmed, .stale: return false
        }
    }
}

/// How the Watch got — or failed to get — the POGO state, for the connection line.
nonisolated enum WatchConnectionStatus: Equatable, Sendable {
    /// The iPhone hasn't sent a bridge address yet.
    case notConfigured
    /// The iPhone shows simulated data; there is no bridge to read.
    case simulated
    /// A round is running right now.
    case checking
    /// Nothing tried yet since the settings arrived.
    case notChecked
    /// The latest round confirmed the state this way.
    case confirmed(WatchPogoPath, at: Date)
    /// The latest round found no way to the bridge.
    case unreachable(direct: WatchPathResult, phone: WatchPathResult, at: Date)
}

/// The Watch's WatchConnectivity link to the iPhone app, as far as the Watch can tell.
nonisolated enum WatchPhoneLinkStatus: String, Equatable, Sendable {
    /// The session isn't activated yet: nothing is known.
    case activating
    /// WatchConnectivity doesn't see PogoHome on the paired iPhone.
    case companionNotInstalled
    /// The iPhone can't be reached right now (out of range, Bluetooth off, restarting).
    case unreachable
    case reachable
}

/// What the Watch says in place of the selected values while it can't show any.
nonisolated enum WatchSetupHint: Equatable, Sendable {
    /// No settings yet, and the link to the iPhone is still being set up.
    case connectingToPhone
    /// No settings yet, and WatchConnectivity doesn't see PogoHome on the iPhone.
    case phoneAppNotInstalled
    /// No settings yet, and the iPhone is out of reach for now.
    case phoneUnreachable
    /// No settings yet; the iPhone is being asked right now.
    case receivingSettings
    /// No settings yet, although the iPhone is reachable: its app hasn't sent any.
    case openPhoneApp
    /// Settings arrived, but no values were picked.
    case pickValues
}

/// One value the user picked for the Watch.
nonisolated struct WatchSelectedValue: Identifiable, Equatable, Sendable {
    let id: String
    let lookup: HomeGlanceSensorLookup
}

nonisolated enum WatchGlancePresentation {
    static func headline(_ glance: HomeGlanceSnapshot?, now: Date) -> WatchPogoHeadline {
        guard let glance else { return .noData }
        let pogo = glance.pogo
        switch pogo.state {
        case .waitingForData:
            return .waitingForData
        case .unverified:
            // Not confirmed now: said as such while the last confirmation is recent, then old.
            guard let verifiedAt = pogo.verifiedAt else { return .notConfirmed(lastConfirmedAt: nil) }
            return HomeGlanceFreshness.of(verifiedAt, now: now) == .recent
                ? .notConfirmed(lastConfirmedAt: verifiedAt)
                : .stale(lastConfirmedAt: verifiedAt)
        case .healthy, .attentionNeeded:
            let status = glance.pogoStatus(at: now)
            guard let verifiedAt = status.verifiedAt else { return .notConfirmed(lastConfirmedAt: nil) }
            switch status.verdict {
            case .healthy:
                return .healthy(online: status.onlineCount, total: status.moduleCount, confirmedAt: verifiedAt)
            case .attentionNeeded:
                return .attentionNeeded(count: status.attention.count, online: status.onlineCount, total: status.moduleCount, confirmedAt: verifiedAt)
            case .stale:
                return .stale(lastConfirmedAt: verifiedAt)
            case .unverified, .waitingForData:
                return .notConfirmed(lastConfirmedAt: verifiedAt)
            }
        }
    }

    /// `HomeGlanceSnapshot.condition(of:at:)`, except that a value whose source isn't confirmed
    /// turns "old" once its last confirmation is older than `staleAfter` — the Watch never keeps
    /// calling an hours-old value merely "not confirmed".
    static func condition(of sensor: HomeGlanceSensor, in glance: HomeGlanceSnapshot, now: Date) -> HomeGlanceSensorCondition {
        let base = glance.condition(of: sensor, at: now)
        if base == .sourceUnverified, HomeGlanceFreshness.of(sensor.checkedAt, now: now) != .recent {
            return .stale
        }
        return base
    }

    static func lookup(_ id: HomeGlanceValueID?, in glance: HomeGlanceSnapshot, now: Date) -> HomeGlanceSensorLookup {
        switch glance.sensorLookup(id, at: now) {
        case let .found(sensor, _):
            return .found(sensor, condition(of: sensor, in: glance, now: now))
        case let other:
            return other
        }
    }

    /// The values the user picked on the iPhone, in their order; empty when none were picked.
    static func selectedValues(_ glance: HomeGlanceSnapshot?, settings: WatchSettings?, now: Date) -> [WatchSelectedValue] {
        guard let settings else { return [] }
        return settings.selectedValueIDs.map { id in
            guard let glance else { return WatchSelectedValue(id: id, lookup: .missing) }
            let valueID = HomeGlanceValueID(stringValue: id)
            let lookup: HomeGlanceSensorLookup = valueID == nil ? .missing : lookup(valueID, in: glance, now: now)
            return WatchSelectedValue(id: id, lookup: lookup)
        }
    }

    /// Why no values are listed, or `nil` when there are some. Without settings, "not installed",
    /// "not reachable now" and "still connecting" are told apart from "the iPhone sent nothing".
    static func setupHint(settings: WatchSettings?, selectedCount: Int, phoneLink: WatchPhoneLinkStatus, isRefreshing: Bool) -> WatchSetupHint? {
        guard settings == nil else { return selectedCount == 0 ? .pickValues : nil }
        switch phoneLink {
        case .activating: return .connectingToPhone
        case .companionNotInstalled: return .phoneAppNotInstalled
        case .unreachable: return .phoneUnreachable
        case .reachable: return isRefreshing ? .receivingSettings : .openPhoneApp
        }
    }

    static func connection(settings: WatchSettings?, record: WatchSyncRecord, isChecking: Bool) -> WatchConnectionStatus {
        if isChecking { return .checking }
        guard let settings else { return .notConfigured }
        if settings.dataSourceMode == .mock { return .simulated }
        guard let round = record.lastRound else { return .notChecked }
        if let path = round.confirmedBy { return .confirmed(path, at: round.at) }
        if round.direct == .notTried, round.phone == .notTried { return .notChecked }
        return .unreachable(direct: round.direct, phone: round.phone, at: round.at)
    }

    /// When the headline or a selected value changes by itself, for widget timeline entries.
    static func changeDates(_ glance: HomeGlanceSnapshot?, selection: HomeGlanceValueID?, after now: Date) -> [Date] {
        glance?.presentationChangeDates(after: now, sensorID: selection) ?? []
    }
}

// MARK: - Privacy

/// What the Watch hides whenever someone other than the wearer might see the screen: in Always On
/// (the wrist is down) and whenever the system redacts for privacy (locked). Names of the home,
/// rooms and devices, Apple Home devices' on/off states and security-sensitive values (doors,
/// locks, presence) are hidden; verdicts, times and plain climate values stay.
nonisolated enum WatchPrivacy {
    static func isSensitive(_ sensor: HomeGlanceSensor) -> Bool {
        HomeGlanceValueText.isSecuritySensitive(sensor)
    }
}
