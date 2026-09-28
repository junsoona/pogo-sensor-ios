import Foundation

/// How much two glance snapshots differ, from a widget's point of view.
nonisolated enum HomeGlanceChange: Int, Comparable, Sendable {
    case none
    /// Only confirmation times moved, or a value drifted less than it's worth redrawing for.
    case minor
    /// A value moved by a visible amount (`HomeGlanceRefreshPolicy.significantDelta`).
    case values
    /// Something a glance states changed: a verdict, a count, a connection, the list of values,
    /// a status or a discrete value (open/closed, detected…).
    case state
    /// Values that must leave every widget now: Apple Home stopped being readable, or the POGO
    /// values came from a source the app no longer uses (simulated ↔ live data, another hub).
    case privacy

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// When the app writes the glance file and when it asks WidgetKit to reload timelines.
///
/// The app never streams to widgets: the POGO bridge updates every few seconds while the app is
/// open, but a widget is redrawn only when that changes what it says. WidgetKit budgets
/// reloads, and may still delay them — widgets cope with that on their own (timeline entries
/// that downgrade to "old" at the right time), so a delayed reload makes a widget more
/// cautious, never wrongly confident.
nonisolated enum HomeGlanceRefreshPolicy {
    /// State changes (connection lost, a module offline…) redraw at most this often; one that
    /// arrives sooner is redrawn when the interval ends, with whatever is current then.
    static let stateReloadInterval: TimeInterval = 60
    /// Visible value changes alone redraw at most this often.
    static let valueReloadInterval: TimeInterval = 15 * 60
    /// With nothing else changing, a redraw this long after the last one keeps the widget's
    /// "confirmed at" time from aging into "old" while the app is still confirming it.
    static let confirmationReloadInterval: TimeInterval = 10 * 60
    /// Minor changes are written at most this often, so a killed app leaves a recent file.
    static let minorPersistInterval: TimeInterval = 5 * 60

    enum Reload: Equatable, Sendable {
        case none
        case now
        case at(Date)
    }

    struct Decision: Equatable, Sendable {
        let persist: Bool
        let reload: Reload
    }

    /// - Parameters:
    ///   - persisted: what the glance file holds now (as far as this process knows).
    ///   - reloaded: what the widgets were last asked to show.
    static func decide(
        next: HomeGlanceSnapshot,
        persisted: HomeGlanceSnapshot?,
        reloaded: HomeGlanceSnapshot?,
        lastPersistAt: Date?,
        lastReloadAt: Date?,
        now: Date
    ) -> Decision {
        let sinceReload = lastReloadAt.map { now.timeIntervalSince($0) } ?? .infinity
        let sincePersist = lastPersistAt.map { now.timeIntervalSince($0) } ?? .infinity

        let reload: Reload
        switch classify(from: reloaded, to: next) {
        case .privacy:
            reload = .now
        case .state:
            reload = sinceReload >= stateReloadInterval ? .now : .at(lastReloadAt!.addingTimeInterval(stateReloadInterval))
        case .values:
            reload = sinceReload >= valueReloadInterval ? .now : .none
        case .minor:
            reload = sinceReload >= confirmationReloadInterval ? .now : .none
        case .none:
            reload = .none
        }

        let persistChange = classify(from: persisted, to: next)
        let persist = reload != .none
            || persistChange >= .values
            || (persistChange == .minor && sincePersist >= minorPersistInterval)
        return Decision(persist: persist, reload: reload)
    }

    /// The decision when the app leaves the foreground: the widgets are about to be visible
    /// again, and nothing will update them until the app returns.
    static func decideOnLeavingForeground(
        next: HomeGlanceSnapshot,
        persisted: HomeGlanceSnapshot?,
        reloaded: HomeGlanceSnapshot?
    ) -> Decision {
        Decision(
            persist: classify(from: persisted, to: next) != .none,
            reload: classify(from: reloaded, to: next) != .none ? .now : .none
        )
    }

    static func classify(from old: HomeGlanceSnapshot?, to new: HomeGlanceSnapshot) -> HomeGlanceChange {
        guard let old else { return .state }

        if old.appleHome.access == .ready && new.appleHome.access != .ready {
            return .privacy
        }
        if old.pogo.sourceID != new.pogo.sourceID || old.pogo.isSimulated != new.pogo.isSimulated {
            return .privacy
        }
        if old.homeName != new.homeName
            || old.pogo.state != new.pogo.state
            || old.pogo.moduleCount != new.pogo.moduleCount
            || old.pogo.onlineCount != new.pogo.onlineCount
            || old.pogo.attention != new.pogo.attention
            || old.pogo.verifiedAt == nil && new.pogo.verifiedAt != nil
            || old.appleHome.access != new.appleHome.access
            || old.appleHome.accessoryCount != new.appleHome.accessoryCount
            || old.appleHome.notRespondingCount != new.appleHome.notRespondingCount
            || old.sensors.map(\.id) != new.sensors.map(\.id) {
            return .state
        }

        var change = HomeGlanceChange.none
        for (before, after) in zip(old.sensors, new.sensors) {
            if before.deviceName != after.deviceName
                || before.roomName != after.roomName
                || before.status != after.status
                || before.isDeviceConnected != after.isDeviceConnected
                || (before.value == nil) != (after.value == nil) {
                return .state
            }
            guard let a = before.value, let b = after.value, a != b else { continue }
            switch significantDelta(for: after) {
            case nil:
                // Discrete values (open/closed, detected, lock state): every change counts.
                return .state
            case let delta?:
                change = max(change, abs(a - b) >= delta ? .values : .minor)
            }
        }
        if change == .none, differsInConfirmationTimes(old, new) {
            change = .minor
        }
        return change
    }

    /// The smallest change of a continuous value worth redrawing a widget for; `nil` for
    /// discrete values, where any change matters.
    static func significantDelta(for sensor: HomeGlanceSensor) -> Double? {
        if let kind = sensor.pogoKind {
            switch kind {
            case .temperature: return 0.5
            case .humidity: return 3
            case .illuminance: return max(20, abs(sensor.value ?? 0) * 0.2)
            case .pm1, .pm2_5, .pm10: return 5
            case .vocIndex, .noxIndex: return 20
            case .vocRaw, .noxRaw: return max(50, abs(sensor.value ?? 0) * 0.05)
            }
        }
        switch sensor.appleHomeKind {
        case .currentTemperature?: return 0.5
        case .currentRelativeHumidity?: return 3
        case .currentLightLevel?: return max(20, abs(sensor.value ?? 0) * 0.2)
        case .pm2_5Density?, .pm10Density?: return 5
        case .carbonDioxideLevel?: return 100
        case .batteryLevel?, .currentPosition?, .brightness?: return 10
        default: return nil
        }
    }

    private static func differsInConfirmationTimes(_ old: HomeGlanceSnapshot, _ new: HomeGlanceSnapshot) -> Bool {
        old.pogo.verifiedAt != new.pogo.verifiedAt
            || old.appleHome.verifiedAt != new.appleHome.verifiedAt
            || zip(old.sensors, new.sensors).contains { $0.checkedAt != $1.checkedAt }
    }
}
