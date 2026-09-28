import Foundation

// What a glance surface may say about a stored `HomeGlanceSnapshot` at a given moment. Views
// only render these verdicts; every rule about "how old is too old", "is this still the current
// state" and "may this value be shown" lives here, where it is unit-tested.

/// How long ago something was confirmed, as far as a glance is concerned.
nonisolated enum HomeGlanceFreshness: Equatable, Sendable {
    /// Confirmed within `staleAfter`. Still shown with its time — never as "live".
    case recent
    /// Confirmed, but longer ago than `staleAfter`.
    case stale
    /// Never confirmed.
    case unknown

    /// A glance is always a copy; after this long it is labeled as old and never presented as
    /// the home's current state. Much longer than the app's own 60 s freshness window, because
    /// the app stops listening in the background and WidgetKit decides when widgets redraw.
    static let staleAfter: TimeInterval = 15 * 60

    static func of(_ confirmedAt: Date?, now: Date) -> HomeGlanceFreshness {
        guard let confirmedAt else { return .unknown }
        // A time in the future (clock change) is not trusted as recent.
        let age = now.timeIntervalSince(confirmedAt)
        return age >= -60 && age <= staleAfter ? .recent : .stale
    }
}

/// The POGO part of the home status widget.
nonisolated struct HomeGlancePogoStatus: Equatable, Sendable {
    enum Verdict: Equatable, Sendable {
        /// No POGO data was ever confirmed.
        case waitingForData
        /// The connection wasn't confirmed when the app last wrote.
        case unverified
        /// Confirmed, but longer ago than `HomeGlanceFreshness.staleAfter`.
        case stale
        case healthy
        case attentionNeeded
    }

    let verdict: Verdict
    let verifiedAt: Date?
    let moduleCount: Int
    let onlineCount: Int
    let attention: [HomeGlanceAttentionItem]
    let isSimulated: Bool

    /// Online/attention counts may be stated only for a recent, confirmed state.
    var showsCounts: Bool { verdict == .healthy || verdict == .attentionNeeded }
    /// Green is reserved for this.
    var isVerifiedFine: Bool { verdict == .healthy }
}

/// The Apple Home part of the home status widget.
nonisolated enum HomeGlanceAppleHomeStatus: Equatable, Sendable {
    /// Not readable (off, denied, restricted, unsupported): nothing stored is shown.
    case unavailable(HomeGlanceAppleHomeAccess)
    case noHome
    case noDevices
    /// Read with access, but longer ago than `staleAfter` (or never).
    case stale(verifiedAt: Date?)
    case allResponding(total: Int, verifiedAt: Date)
    case someNotResponding(notResponding: Int, total: Int, verifiedAt: Date)
}

/// Why a sensor value is (or isn't) shown the way it is.
nonisolated enum HomeGlanceSensorCondition: Equatable, Sendable {
    /// Checked recently from a confirmed source and device.
    case recent
    /// Checked, but longer ago than `staleAfter` (or never with a time).
    case stale
    /// The source (POGO bridge connection) wasn't confirmed when last written.
    case sourceUnverified
    /// The device itself reported offline / not responding.
    case deviceDisconnected
    /// Apple Home listed the value but PogoHome hasn't read it yet.
    case notYetRead
}

nonisolated enum HomeGlanceSensorLookup: Equatable, Sendable {
    /// No value selected.
    case notConfigured
    /// The selected value's source can't be read now — its stored values are never shown.
    case sourceUnavailable(HomeGlanceAppleHomeAccess)
    /// The selected device/value is no longer in the data (deleted, removed from Apple Home,
    /// detached from POGO) — or the selection can't be parsed.
    case missing
    case found(HomeGlanceSensor, HomeGlanceSensorCondition)
}

nonisolated extension HomeGlanceSnapshot {
    func pogoStatus(at now: Date) -> HomeGlancePogoStatus {
        let verdict: HomeGlancePogoStatus.Verdict
        switch pogo.state {
        case .waitingForData:
            verdict = .waitingForData
        case .unverified:
            verdict = pogo.verifiedAt == nil && pogo.moduleCount == 0 ? .waitingForData : .unverified
        case .healthy, .attentionNeeded:
            switch HomeGlanceFreshness.of(pogo.verifiedAt, now: now) {
            case .recent: verdict = pogo.state == .healthy ? .healthy : .attentionNeeded
            case .stale: verdict = .stale
            case .unknown: verdict = .unverified
            }
        }
        return HomeGlancePogoStatus(
            verdict: verdict,
            verifiedAt: pogo.verifiedAt,
            moduleCount: pogo.moduleCount,
            onlineCount: pogo.onlineCount,
            attention: pogo.attention,
            isSimulated: pogo.isSimulated
        )
    }

    func appleHomeStatus(at now: Date) -> HomeGlanceAppleHomeStatus {
        switch appleHome.access {
        case .off, .unsupported, .denied, .restricted:
            return .unavailable(appleHome.access)
        case .noHome:
            return .noHome
        case .ready:
            guard let verifiedAt = appleHome.verifiedAt, HomeGlanceFreshness.of(verifiedAt, now: now) == .recent else {
                return .stale(verifiedAt: appleHome.verifiedAt)
            }
            guard appleHome.accessoryCount > 0 else { return .noDevices }
            return appleHome.notRespondingCount == 0
                ? .allResponding(total: appleHome.accessoryCount, verifiedAt: verifiedAt)
                : .someNotResponding(notResponding: appleHome.notRespondingCount, total: appleHome.accessoryCount, verifiedAt: verifiedAt)
        }
    }

    func sensorLookup(_ id: HomeGlanceValueID?, at now: Date) -> HomeGlanceSensorLookup {
        guard let id else { return .notConfigured }
        if id.device.source == .appleHome, appleHome.access != .ready {
            // Even if an older writer had left values behind, they are not the current state.
            return .sourceUnavailable(appleHome.access)
        }
        guard let sensor = sensor(with: id) else { return .missing }
        return .found(sensor, condition(of: sensor, at: now))
    }

    func condition(of sensor: HomeGlanceSensor, at now: Date) -> HomeGlanceSensorCondition {
        guard sensor.value != nil else { return .notYetRead }
        switch sensor.source {
        case .pogoLinuxAPI:
            if pogo.state == .unverified || pogo.state == .waitingForData { return .sourceUnverified }
        case .appleHome:
            if HomeGlanceFreshness.of(appleHome.verifiedAt, now: now) != .recent { return .stale }
        }
        guard sensor.isDeviceConnected else { return .deviceDisconnected }
        return HomeGlanceFreshness.of(sensor.checkedAt, now: now) == .recent ? .recent : .stale
    }

    /// The moments after `now` at which what a glance shows changes without any new data: when a
    /// confirmation turns stale, and at midnight (a bare time like "14:02" would then mean
    /// yesterday). A widget timeline gets an entry at each, so a widget WidgetKit doesn't reload
    /// still downgrades itself on time.
    func presentationChangeDates(after now: Date, sensorID: HomeGlanceValueID? = nil, calendar: Calendar = .current) -> [Date] {
        var confirmations: [Date?] = [pogo.verifiedAt, appleHome.verifiedAt]
        if let sensorID, let sensor = sensor(with: sensorID) {
            confirmations.append(sensor.checkedAt)
        }
        var dates = confirmations.compactMap { $0?.addingTimeInterval(HomeGlanceFreshness.staleAfter + 1) }
        if let midnight = calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime) {
            dates.append(midnight)
        }
        return Array(Set(dates.filter { $0 > now })).sorted()
    }
}

// MARK: - Value text

nonisolated enum HomeGlanceValueText {
    /// Label for the value's kind ("온도", "열림 감지"…), in the current language.
    static func kindLabel(of sensor: HomeGlanceSensor) -> String {
        if let kind = sensor.pogoKind { return kind.displayName }
        if let kind = sensor.appleHomeKind { return AppleHomeCapabilities.label(for: kind) }
        return String(localized: "알 수 없음", comment: "Apple Home: the device reports an unknown value")
    }

    static func symbolName(of sensor: HomeGlanceSensor) -> String {
        if let kind = sensor.pogoKind { return kind.symbolName }
        if let kind = sensor.appleHomeKind { return AppleHomeCapabilities.symbolName(for: kind) }
        return "questionmark"
    }

    /// Full value text with unit ("23.4 °C", "열림"), or `nil` if not read yet.
    static func valueText(of sensor: HomeGlanceSensor, locale: Locale = .current) -> String? {
        guard let value = sensor.value else { return nil }
        if let kind = sensor.pogoKind { return kind.formattedValue(value, locale: locale) }
        if let kind = sensor.appleHomeKind {
            return AppleHomeCapabilities.displayText(for: kind, value: .double(value), locale: locale)
        }
        return nil
    }

    /// The shortest honest form for a Lock Screen circle: "23.4°", "48%", "12".
    static func compactValueText(of sensor: HomeGlanceSensor, locale: Locale = .current) -> String? {
        guard let value = sensor.value else { return nil }
        if let kind = sensor.pogoKind {
            switch kind {
            case .temperature:
                return value.formatted(.number.precision(.fractionLength(1)).locale(locale)) + "°"
            case .humidity:
                return value.formatted(.number.precision(.fractionLength(0)).locale(locale)) + "%"
            case .pm1, .pm2_5, .pm10, .illuminance, .vocRaw, .vocIndex, .noxRaw, .noxIndex:
                return value.formatted(.number.precision(.fractionLength(0)).locale(locale))
            }
        }
        if let kind = sensor.appleHomeKind {
            switch kind {
            case .currentTemperature:
                return value.formatted(.number.precision(.fractionLength(1)).locale(locale)) + "°"
            case .currentRelativeHumidity, .batteryLevel, .brightness, .currentPosition:
                return value.formatted(.number.precision(.fractionLength(0)).locale(locale)) + "%"
            case .currentLightLevel, .pm2_5Density, .pm10Density, .carbonDioxideLevel:
                return value.formatted(.number.precision(.fractionLength(0)).locale(locale))
            default:
                return AppleHomeCapabilities.displayText(for: kind, value: .double(value), locale: locale)
            }
        }
        return nil
    }

    /// Values that tell someone looking at a locked phone whether a door is open, a lock is
    /// unlocked or someone is home. Glance views mark them privacy-sensitive so they are
    /// redacted while the device is locked.
    static func isSecuritySensitive(_ sensor: HomeGlanceSensor) -> Bool {
        switch sensor.appleHomeKind {
        case .contactState?, .currentLockMechanismState?, .motionDetected?, .occupancyDetected?:
            return true
        default:
            return false
        }
    }
}
