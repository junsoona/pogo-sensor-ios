import Foundation

// The read-only "glance" copy of the home that PogoHome hands to its widgets — and, later, to
// any other surface that can't talk to the POGO bridge or HomeKit itself (Control Center, a
// Watch complication, an iPad or Mac widget). The app writes it (`HomeGlanceBuilder`,
// `HomeGlancePublisher`); everything else only reads it (`HomeGlanceStore`,
// `HomeGlancePresentation`).
//
// Rules this format keeps:
// - Every device and value keeps its source-qualified identity (`DeviceIdentifier`). A POGO
//   module and an Apple Home accessory with the same name stay two separate entries.
// - Nothing here is a live reading. Each part carries when the app last confirmed it
//   (`verifiedAt`, `checkedAt`); readers decide from those how old the data is.
// - Apple Home values exist only while Apple Home access was `.ready` when written.
//
// This file is compiled into the app and the widget extension, together with the value types it
// names (`DeviceModels.swift`, `SensorKind.swift`, `AppleHomeSnapshot.swift`).

/// One value of one device, unique across sources.
nonisolated struct HomeGlanceValueID: Hashable, Codable, Sendable {
    let device: DeviceIdentifier
    /// Within the device: a `SensorKind` raw value (POGO) or a HomeKit characteristic's
    /// `uniqueIdentifier` string (Apple Home).
    let valueKey: String

    static func pogo(module: UUID, kind: SensorKind) -> HomeGlanceValueID {
        HomeGlanceValueID(device: .pogoModule(module), valueKey: kind.rawValue)
    }

    static func appleHome(accessory: UUID, characteristic: UUID) -> HomeGlanceValueID {
        HomeGlanceValueID(device: .appleHomeAccessory(accessory), valueKey: characteristic.uuidString)
    }

    /// `"<source>/<device UUID>/<value key>"` — the identifier a widget configuration stores.
    var stringValue: String {
        "\(device.source.rawValue)/\(device.rawValue.uuidString)/\(valueKey)"
    }

    init(device: DeviceIdentifier, valueKey: String) {
        self.device = device
        self.valueKey = valueKey
    }

    init?(stringValue: String) {
        let parts = stringValue.split(separator: "/", omittingEmptySubsequences: false)
        guard
            parts.count == 3,
            let source = DeviceSource(rawValue: String(parts[0])),
            let raw = UUID(uuidString: String(parts[1])),
            !parts[2].isEmpty
        else { return nil }
        self.init(device: DeviceIdentifier(source: source, rawValue: raw), valueKey: String(parts[2]))
    }
}

/// The POGO sensors' verdict as the app last saw it — `HomeHealthState` reduced to what a
/// glance may say.
nonisolated enum HomeGlancePogoState: String, Codable, Hashable, Sendable {
    /// Nothing has been received yet.
    case waitingForData
    /// The bridge connection (or the bridge's registry) wasn't confirmed when this was written.
    case unverified
    case healthy
    case attentionNeeded
}

nonisolated enum HomeGlanceAttentionReason: String, Codable, Hashable, Sendable {
    case offline
    case stale
    case error
    case unavailable
}

nonisolated struct HomeGlanceAttentionItem: Codable, Hashable, Sendable {
    let device: DeviceIdentifier
    let name: String
    let reason: HomeGlanceAttentionReason
}

nonisolated struct HomeGlancePogoSection: Codable, Hashable, Sendable {
    var state: HomeGlancePogoState
    /// The last moment the app confirmed the POGO state over a live, fresh connection. Kept
    /// (not advanced) while the connection is unverified; `nil` if it never was confirmed.
    var verifiedAt: Date?
    var moduleCount: Int
    var onlineCount: Int
    var attention: [HomeGlanceAttentionItem]
    /// Written from the app's mock data source, not the POGO bridge.
    var isSimulated: Bool
    /// Which data source (simulated data, or which hub) this part was written from — a
    /// `SensorSourceIdentity.rawValue`. `nil` in glances written before it was recorded.
    var sourceID: String? = nil

    static let empty = HomeGlancePogoSection(
        state: .waitingForData,
        verifiedAt: nil,
        moduleCount: 0,
        onlineCount: 0,
        attention: [],
        isSimulated: false
    )
}

/// `AppleHomeAccessState` without the transient `.loading`: a glance is only rewritten from a
/// conclusive state.
nonisolated enum HomeGlanceAppleHomeAccess: String, Codable, Hashable, Sendable {
    /// Turned off in PogoHome (or never turned on).
    case off
    case unsupported
    case denied
    case restricted
    case noHome
    case ready
}

nonisolated struct HomeGlanceAppleHomeSection: Codable, Hashable, Sendable {
    var access: HomeGlanceAppleHomeAccess
    /// When the app last read Apple Home's device list with access `.ready`. Cleared together
    /// with the devices whenever access isn't `.ready`.
    var verifiedAt: Date?
    var accessoryCount: Int
    var notRespondingCount: Int

    static let off = HomeGlanceAppleHomeSection(access: .off, verifiedAt: nil, accessoryCount: 0, notRespondingCount: 0)
}

/// How a glance value was last reported. POGO statuses map one-to-one; Apple Home only knows
/// whether a value needs attention.
nonisolated enum HomeGlanceValueStatus: String, Codable, Hashable, Sendable {
    case normal
    case conditioning
    case stale
    case unavailable
    case error
    case attention

    var needsAttention: Bool {
        switch self {
        case .normal, .conditioning: return false
        case .stale, .unavailable, .error, .attention: return true
        }
    }
}

/// One selectable value — a POGO reading or an Apple Home readable characteristic.
nonisolated struct HomeGlanceSensor: Codable, Hashable, Sendable, Identifiable {
    let id: HomeGlanceValueID
    let deviceName: String
    let roomName: String?
    /// `SensorKind.rawValue` for POGO, `AppleHomeCharacteristicKind.rawValue` for Apple Home.
    let kindRawValue: String
    /// `nil` until the value was actually read (Apple Home before its first read).
    let value: Double?
    let status: HomeGlanceValueStatus
    /// The device itself was reachable/online as its source reported it.
    let isDeviceConnected: Bool
    /// When the app last received this value from a confirmed source. Kept (not advanced) while
    /// the device or its source can't be confirmed; `nil` if it never was.
    let checkedAt: Date?

    var source: DeviceSource { id.device.source }

    var pogoKind: SensorKind? {
        source == .pogoLinuxAPI ? SensorKind(rawValue: kindRawValue) : nil
    }

    var appleHomeKind: AppleHomeCharacteristicKind? {
        source == .appleHome ? AppleHomeCharacteristicKind(rawValue: kindRawValue) : nil
    }
}

nonisolated struct HomeGlanceSnapshot: Codable, Hashable, Sendable {
    /// Bumped on any incompatible change; readers treat another version as "no data".
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var writtenAt: Date
    /// The user's PogoHome home name, or the localized default.
    var homeName: String
    var pogo: HomeGlancePogoSection
    var appleHome: HomeGlanceAppleHomeSection
    /// POGO values first, then Apple Home values.
    var sensors: [HomeGlanceSensor]

    init(
        writtenAt: Date,
        homeName: String,
        pogo: HomeGlancePogoSection,
        appleHome: HomeGlanceAppleHomeSection,
        sensors: [HomeGlanceSensor]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.writtenAt = writtenAt
        self.homeName = homeName
        self.pogo = pogo
        self.appleHome = appleHome
        self.sensors = sensors
    }

    var pogoSensors: [HomeGlanceSensor] { sensors.filter { $0.source == .pogoLinuxAPI } }
    var appleHomeSensors: [HomeGlanceSensor] { sensors.filter { $0.source == .appleHome } }

    func sensor(with id: HomeGlanceValueID) -> HomeGlanceSensor? {
        sensors.first { $0.id == id }
    }
}

/// The widget kinds, shared so the app can ask WidgetKit to reload exactly these.
nonisolated enum HomeGlanceWidgetKind {
    static let homeStatus = "com.junsoona.PogoHome.widget.homeStatus"
    static let sensorValue = "com.junsoona.PogoHome.widget.sensorValue"
    static let all = [homeStatus, sensorValue]
}
