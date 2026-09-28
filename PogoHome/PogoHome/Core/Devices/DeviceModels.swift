import Foundation

// The source-neutral device vocabulary: what every screen — and later a widget, a Lock Screen
// accessory or a Control Center control — may know about a device without knowing where it
// came from. Everything here is a plain `Sendable` value with no HomeKit or network types, so
// a future extension target can link this file alone and receive `DeviceSummary` values (e.g.
// through an App Group) and send back `DeviceCommand`s.
//
// Two sources exist today, and they never share an identifier:
//   - POGO Linux API: `SensorModule.id`, the module UUID the bridge assigns. Read-only.
//   - Apple Home: `HMAccessory.uniqueIdentifier`, assigned by HomeKit per device.
// See `DeviceDirectory` for how a device that shows up through both is handled.

/// Where a device's state comes from.
nonisolated enum DeviceSource: String, Codable, Hashable, Sendable, CaseIterable {
    /// A POGO sensor module reported by the Linux PogoHome API.
    case pogoLinuxAPI
    /// An accessory the user added to Apple Home (Matter or HomeKit), read through HomeKit.
    case appleHome
}

/// A device's identity, unique across sources: the same UUID value under two sources is two
/// different devices.
nonisolated struct DeviceIdentifier: Hashable, Codable, Sendable {
    let source: DeviceSource
    let rawValue: UUID

    static func pogoModule(_ id: UUID) -> DeviceIdentifier {
        DeviceIdentifier(source: .pogoLinuxAPI, rawValue: id)
    }

    static func appleHomeAccessory(_ id: UUID) -> DeviceIdentifier {
        DeviceIdentifier(source: .appleHome, rawValue: id)
    }
}

/// Whether the device can currently be reached, as its own source reports it.
nonisolated enum DeviceConnectionState: Hashable, Sendable {
    case connected
    case disconnected
    /// The source itself isn't verified right now (e.g. the POGO bridge connection is down, or
    /// Apple Home hasn't reported yet), so the device's own state is unknown.
    case unverified
}

/// One value the device reports. `displayValue` is `nil` until the value has actually been
/// read — never a placeholder that looks like a reading.
nonisolated struct DeviceReadableValue: Identifiable, Hashable, Sendable {
    /// Stable within its device (a sensor kind or a HomeKit characteristic id).
    let id: String
    let label: String
    let displayValue: String?
    let symbolName: String
    let needsAttention: Bool
}

/// A value a control can be set to.
nonisolated enum DeviceControlValue: Hashable, Codable, Sendable {
    case bool(Bool)
    /// A whole-number percentage (e.g. brightness).
    case percent(Int)
}

/// The kinds of control PogoHome can perform. Deliberately short: only what HomeKit exposes
/// as a writable characteristic on a service type whose meaning is unambiguous.
nonisolated enum DeviceControlKind: String, Codable, Hashable, Sendable {
    /// On/off (`PowerState`) of a light, switch, outlet or fan.
    case power
    /// Active/inactive (`Active`) of a fan or air purifier.
    case active
    /// Brightness 0–100% of a light.
    case brightness
}

/// A control the device currently offers.
nonisolated struct DeviceAvailableControl: Identifiable, Hashable, Sendable {
    /// Stable within its device (for Apple Home: the characteristic's unique identifier).
    let id: UUID
    let kind: DeviceControlKind
    /// What the control acts on, e.g. the service's name in Apple Home ("Ceiling Light").
    let label: String
    /// The last *confirmed* value (read back from the device), `nil` if never read.
    let confirmedValue: DeviceControlValue?
    /// Inclusive bounds for `.percent` controls.
    let range: ClosedRange<Int>?
    /// `false` while the device is unreachable or the source is not authorized — shown, but
    /// not operable.
    let isEnabled: Bool
}

/// A request to set one control. Codable so an App Intent / Control widget can carry it.
nonisolated struct DeviceCommand: Hashable, Codable, Sendable {
    let device: DeviceIdentifier
    let controlID: UUID
    let kind: DeviceControlKind
    let value: DeviceControlValue
}

/// How a command ended. Only `.confirmed` means the device now reports the requested value.
nonisolated enum DeviceCommandOutcome: Hashable, Sendable {
    /// The write succeeded and a read-back returned the requested value.
    case confirmed
    /// The write reported success but the device did not report the requested value back.
    case unconfirmed(String)
    /// The write failed (error, timeout, permission, disconnection).
    case failed(String)
    /// Never sent: the device or control is not available right now.
    case rejected(String)

    var isConfirmed: Bool {
        if case .confirmed = self { return true }
        return false
    }
}

/// Everything a list row, widget or control needs to show one device.
nonisolated struct DeviceSummary: Identifiable, Hashable, Sendable {
    let id: DeviceIdentifier
    let name: String
    let roomName: String?
    let connection: DeviceConnectionState
    /// When PogoHome last received a value from the device (not when the list was redrawn).
    let lastCheckedAt: Date?
    let values: [DeviceReadableValue]
    let controls: [DeviceAvailableControl]
    /// Whether the device is a Matter accessory (Apple Home reports a Matter node id).
    let isMatter: Bool
    /// Set when this entry is the Apple Home view of a device the user has marked as the same
    /// device as a POGO module; that POGO module is the one to show.
    let duplicateOf: DeviceIdentifier?

    var source: DeviceSource { id.source }
}

/// Anything that can carry out a `DeviceCommand` — `AppleHomeModel` today. A future
/// Control Center control or interactive widget would call through this.
@MainActor
protocol DeviceCommandPerforming: AnyObject {
    func perform(_ command: DeviceCommand) async -> DeviceCommandOutcome
}
