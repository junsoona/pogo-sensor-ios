import Foundation
import os

// The Control Center power toggle for Apple Home accessories, as far as it can be shared
// between the app and the widget extension.
//
// Who does what:
// - The widget extension draws the control and reads only the file below
//   (`AppleHomePowerStore`). HomeKit refuses requests from a widget extension, so it never
//   calls HomeKit and never decides what to send.
// - The toggle's intent (`SetAppleHomePowerIntent`) is pinned to the app process
//   (`allowedExecutionTargets = .main`). There it resolves the target in HomeKit by id, reads
//   the device's current state, writes, and reads again (`AppleHomePowerPerformer`). Only a
//   read-back that reports the requested state counts as success.
// - The app writes the list of selectable targets and every state it learns into the file,
//   then asks Control Center to redraw.
//
// This file is compiled into the app and the widget extension.

/// The control kind registered with WidgetKit.
nonisolated enum AppleHomePowerControlKind {
    static let power = "com.junsoona.PogoHome.control.appleHomePower"
}

/// One toggle target, named by the identifiers HomeKit assigns — never by a device or room
/// name, which the user can change (or reuse) in the Home app.
nonisolated struct AppleHomePowerTargetID: Hashable, Codable, Sendable {
    /// `HMHome.uniqueIdentifier`.
    let homeID: UUID
    /// `HMAccessory.uniqueIdentifier`.
    let accessoryID: UUID
    /// The `PowerState` characteristic's `uniqueIdentifier`.
    let characteristicID: UUID

    static let prefix = "appleHomePower"

    /// `"appleHomePower/<home>/<accessory>/<characteristic>"` — what a control configuration stores.
    var stringValue: String {
        "\(Self.prefix)/\(homeID.uuidString)/\(accessoryID.uuidString)/\(characteristicID.uuidString)"
    }

    init(homeID: UUID, accessoryID: UUID, characteristicID: UUID) {
        self.homeID = homeID
        self.accessoryID = accessoryID
        self.characteristicID = characteristicID
    }

    init?(stringValue: String) {
        let parts = stringValue.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard
            parts.count == 4,
            parts[0] == Self.prefix,
            let home = UUID(uuidString: parts[1]),
            let accessory = UUID(uuidString: parts[2]),
            let characteristic = UUID(uuidString: parts[3])
        else { return nil }
        self.init(homeID: home, accessoryID: accessory, characteristicID: characteristic)
    }
}

/// What kind of on/off device a target is (decided from its HomeKit service type).
nonisolated enum AppleHomePowerTargetKind: String, Codable, Hashable, Sendable {
    case light
    case outlet
    case `switch`

    var symbolName: String {
        switch self {
        case .light: return "lightbulb.fill"
        case .outlet: return "poweroutlet.type.b.fill"
        case .switch: return "switch.2"
        }
    }

    var label: String {
        switch self {
        case .light: return String(localized: "조명", comment: "Control Center target kind: light")
        case .outlet: return String(localized: "콘센트", comment: "Control Center target kind: outlet")
        case .switch: return String(localized: "스위치", comment: "Control Center target kind: switch")
        }
    }
}

/// A device the user may pick for the control.
nonisolated struct AppleHomePowerTarget: Identifiable, Hashable, Codable, Sendable {
    let id: AppleHomePowerTargetID
    /// The accessory's name in Apple Home when the app last looked — for display only.
    let name: String
    let roomName: String?
    let homeName: String
    let kind: AppleHomePowerTargetKind
}

/// Why a control action didn't end with the requested state read back from the device.
nonisolated enum AppleHomePowerFailure: String, Codable, Hashable, Sendable, Error, CaseIterable {
    /// Apple Home is turned off in PogoHome.
    case appleHomeOff
    /// Apple Home access was declined or revoked.
    case notAuthorized
    case restricted
    /// HomeKit didn't report its homes in time.
    case homeKitUnavailable
    /// The home or accessory no longer exists.
    case targetMissing
    /// The accessory exists but no longer has exactly one readable, writable on/off control
    /// with this id.
    case targetChanged
    case notReachable
    /// HomeKit refused because the iPhone is locked.
    case deviceLocked
    case timedOut
    /// The current state couldn't be read, so nothing was sent.
    case readFailed
    case writeFailed
    /// The write reported success, but the state couldn't be read back.
    case unconfirmed
    /// The state read back isn't the requested one.
    case mismatch
    /// The same control is already running.
    case busy
    /// The intent ran somewhere other than the app process.
    case requiresApp

    var messageResource: LocalizedStringResource {
        switch self {
        case .appleHomeOff:
            return LocalizedStringResource("조각보 홈에서 Apple 홈이 꺼져 있습니다. 앱에서 켜 주세요.", comment: "Control Center error: Apple Home is off in PogoHome")
        case .notAuthorized:
            return LocalizedStringResource("Apple 홈 접근 권한이 없습니다.", comment: "Apple Home error")
        case .restricted:
            return LocalizedStringResource("이 iPhone에서는 Apple 홈 접근이 제한되어 있습니다.", comment: "Control Center error: Apple Home access restricted by the system")
        case .homeKitUnavailable:
            return LocalizedStringResource("Apple 홈이 제시간에 응답하지 않았습니다.", comment: "Control Center error: HomeKit didn't load its homes in time")
        case .targetMissing:
            return LocalizedStringResource("Apple 홈에서 기기를 찾을 수 없습니다.", comment: "Apple Home error")
        case .targetChanged:
            return LocalizedStringResource("기기 구성이 바뀌어 이 제어를 사용할 수 없습니다. 기기를 다시 선택하세요.", comment: "Control Center error: the accessory no longer has exactly one on/off control")
        case .notReachable:
            return LocalizedStringResource("기기가 응답하지 않습니다. 전원과 네트워크 연결을 확인하세요.", comment: "Apple Home error")
        case .deviceLocked:
            return LocalizedStringResource("iPhone 잠금을 해제한 후 다시 시도하세요.", comment: "Control Center error: HomeKit refused because the iPhone is locked")
        case .timedOut:
            return LocalizedStringResource("기기가 제시간에 응답하지 않았습니다.", comment: "Apple Home error")
        case .readFailed:
            return LocalizedStringResource("기기의 현재 상태를 읽지 못해 명령을 보내지 않았습니다.", comment: "Control Center error: the state read before writing failed")
        case .writeFailed:
            return LocalizedStringResource("기기에 명령을 보내지 못했습니다.", comment: "Control Center error: the write failed")
        case .unconfirmed:
            return LocalizedStringResource("명령은 전달됐지만 기기의 현재 상태를 확인하지 못했습니다.", comment: "Control: write succeeded, read-back failed")
        case .mismatch:
            return LocalizedStringResource("기기가 요청한 상태를 보고하지 않았습니다.", comment: "Control: device reports a different value after the write")
        case .busy:
            return LocalizedStringResource("이전 요청을 처리하는 중입니다.", comment: "Control rejected: a previous request is still running")
        case .requiresApp:
            return LocalizedStringResource("이 동작은 조각보 홈 앱에서만 실행할 수 있습니다.", comment: "Control Center error: the intent ran outside the app process")
        }
    }

    var message: String { String(localized: messageResource) }
}

/// How the most recent control action ended.
nonisolated enum AppleHomePowerResult: Hashable, Codable, Sendable {
    /// The device reported the requested state after the action.
    case confirmed
    /// The control only read the state (it wasn't known when tapped); nothing was sent.
    case checked
    case failed(AppleHomePowerFailure)
}

/// What is known about one target's power state.
nonisolated struct AppleHomePowerState: Hashable, Codable, Sendable {
    /// The last state read from the device; `nil` when it isn't known (never read, or an
    /// action ended without a readable state).
    let isOn: Bool?
    /// When `isOn` was read from the device.
    let checkedAt: Date?
    let lastResult: AppleHomePowerResult?
    let resultAt: Date?

    init(isOn: Bool?, checkedAt: Date?, lastResult: AppleHomePowerResult? = nil, resultAt: Date? = nil) {
        self.isOn = isOn
        self.checkedAt = isOn == nil ? nil : checkedAt
        self.lastResult = lastResult
        self.resultAt = resultAt
    }
}

/// Whether Apple Home could be read when the app last wrote the catalog.
nonisolated enum AppleHomePowerAvailability: String, Codable, Hashable, Sendable {
    case ready
    /// Apple Home is off in PogoHome.
    case off
    case denied
    case restricted
    case noHome
}

/// Everything the control shares between processes: the selectable targets and their states.
nonisolated struct AppleHomePowerCatalog: Hashable, Codable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let writtenAt: Date
    let availability: AppleHomePowerAvailability
    /// Targets eligible for the control (see `AppleHomePowerEligibility`); empty unless `.ready`.
    let targets: [AppleHomePowerTarget]
    /// Keyed by `AppleHomePowerTargetID.stringValue`.
    let states: [String: AppleHomePowerState]
    /// Names of targets seen before, so a configured control keeps its label after its device
    /// stops being eligible or Apple Home becomes unreadable.
    let knownNames: [String: String]

    init(
        writtenAt: Date,
        availability: AppleHomePowerAvailability,
        targets: [AppleHomePowerTarget],
        states: [String: AppleHomePowerState],
        knownNames: [String: String],
        schemaVersion: Int = AppleHomePowerCatalog.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.writtenAt = writtenAt
        self.availability = availability
        self.targets = availability == .ready ? targets : []
        self.states = availability == .ready ? states : [:]
        self.knownNames = knownNames
    }

    func target(_ id: AppleHomePowerTargetID) -> AppleHomePowerTarget? {
        targets.first { $0.id == id }
    }

    func state(_ id: AppleHomePowerTargetID) -> AppleHomePowerState? {
        states[id.stringValue]
    }

    func replacingState(_ state: AppleHomePowerState, for id: AppleHomePowerTargetID, at date: Date) -> AppleHomePowerCatalog {
        var states = states
        states[id.stringValue] = state
        return AppleHomePowerCatalog(writtenAt: date, availability: availability, targets: targets, states: states, knownNames: knownNames)
    }

    /// Equal apart from when it was written.
    func hasSameContent(as other: AppleHomePowerCatalog?) -> Bool {
        guard let other else { return false }
        return availability == other.availability && targets == other.targets
            && states == other.states && knownNames == other.knownNames
    }
}

/// Reads and writes the catalog in the App Group container, next to the widgets' glance file.
/// Only the app writes; the widget extension only reads.
nonisolated struct AppleHomePowerStore: Sendable {
    static let fileName = "apple-home-power.json"

    enum LoadResult: Equatable, Sendable {
        case missing
        case unreadable
        case catalog(AppleHomePowerCatalog)

        var catalog: AppleHomePowerCatalog? {
            if case let .catalog(catalog) = self { return catalog }
            return nil
        }
    }

    let fileURL: URL

    private static let logger = Logger(subsystem: "com.junsoona.PogoHome", category: "AppleHomePowerStore")

    init(directory: URL) {
        self.fileURL = directory.appending(path: Self.fileName, directoryHint: .notDirectory)
    }

    static func shared(fileManager: FileManager = .default) -> AppleHomePowerStore? {
        guard let glance = HomeGlanceStore.shared(fileManager: fileManager) else { return nil }
        return AppleHomePowerStore(directory: glance.fileURL.deletingLastPathComponent())
    }

    func load() -> LoadResult {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            Self.logger.error("control catalog read failed: \(String(describing: error), privacy: .public)")
            return .unreadable
        }
        guard
            let catalog = try? Self.decoder.decode(AppleHomePowerCatalog.self, from: data),
            catalog.schemaVersion == AppleHomePowerCatalog.currentSchemaVersion
        else { return .unreadable }
        return .catalog(catalog)
    }

    func save(_ catalog: AppleHomePowerCatalog) throws {
        let data = try Self.encoder.encode(catalog)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        // Control Center is usable on the Lock Screen, so the file must stay readable while the
        // iPhone is locked (after the first unlock since restart), like the glance file.
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: fileURL, options: .atomic)
        #endif
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}

/// What the control shows for one configured target, decided from the stored catalog only.
/// It never claims more than the file says: a state older than
/// `HomeGlanceFreshness.staleAfter` is shown as the last one seen, not as the current one.
nonisolated struct AppleHomePowerControlDisplay: Hashable, Sendable {
    enum State: Hashable, Sendable {
        case on
        case off
        /// Last read longer ago than `HomeGlanceFreshness.staleAfter`.
        case lastSeen(isOn: Bool)
        /// Never read, or the last action ended without a readable state.
        case unknown
        case unavailable(Unavailability)
        case notConfigured
    }

    enum Unavailability: Hashable, Sendable {
        case appleHomeOff
        case noAccess
        /// Apple Home is readable but the device is no longer an eligible target.
        case targetGone
    }

    let title: String
    let state: State
    let kind: AppleHomePowerTargetKind?
    /// A short note about the last action, shown only right after it.
    let status: String?

    /// How long a result stays in the control's status line.
    static let statusWindow: TimeInterval = 60

    /// The toggle's position. Unknown states show as off, and their tap only reads.
    var isOn: Bool {
        switch state {
        case .on, .lastSeen(isOn: true): return true
        default: return false
        }
    }

    /// Whether a tap may switch the device (after the intent re-reads it). Otherwise a tap only
    /// reads the current state.
    var isStateKnown: Bool {
        switch state {
        case .on, .off, .lastSeen: return true
        case .unknown, .unavailable, .notConfigured: return false
        }
    }

    var valueText: String {
        switch state {
        case .on: return String(localized: "켜짐", comment: "Apple Home: on")
        case .off: return String(localized: "꺼짐", comment: "Apple Home: off")
        case .lastSeen(isOn: true): return String(localized: "마지막 확인: 켜짐", comment: "Control Center value: last read state (old), on")
        case .lastSeen(isOn: false): return String(localized: "마지막 확인: 꺼짐", comment: "Control Center value: last read state (old), off")
        case .unknown: return String(localized: "상태 모름", comment: "Control Center value: the state isn't known")
        case .unavailable: return String(localized: "사용할 수 없음", comment: "Control Center value: the target can't be used")
        case .notConfigured: return String(localized: "기기를 선택하세요", comment: "Control Center value: no device chosen yet")
        }
    }

    /// What pressing the control does, e.g. for VoiceOver and the Action button.
    var actionHint: String {
        guard isStateKnown else { return String(localized: "상태 확인", comment: "Control Center action hint: read the state only") }
        return isOn
            ? String(localized: "끄기", comment: "Control Center action hint: turn off")
            : String(localized: "켜기", comment: "Control Center action hint: turn on")
    }

    /// The value label while the tap is being carried out (the system flips the toggle before
    /// the intent finishes) — never "on"/"off" until the device reported it.
    func pendingText(requestedOn: Bool) -> String {
        guard isStateKnown else { return String(localized: "확인 중…", comment: "Control Center value: reading the state") }
        return requestedOn
            ? String(localized: "켜는 중…", comment: "Control Center value: turning on, not confirmed yet")
            : String(localized: "끄는 중…", comment: "Control Center value: turning off, not confirmed yet")
    }

    var symbolName: String { kind?.symbolName ?? "power" }

    static func make(
        targetID: AppleHomePowerTargetID?,
        configuredName: String?,
        load: AppleHomePowerStore.LoadResult,
        now: Date
    ) -> AppleHomePowerControlDisplay {
        guard let targetID else {
            return AppleHomePowerControlDisplay(title: String(localized: "Apple 홈 전원 기기", comment: "Control Center: an Apple Home device the power control switches"), state: .notConfigured, kind: nil, status: nil)
        }
        let catalog = load.catalog
        let target = catalog?.target(targetID)
        let title = target?.name ?? catalog?.knownNames[targetID.stringValue] ?? configuredName
            ?? String(localized: "Apple 홈 전원 기기", comment: "Control Center: an Apple Home device the power control switches")
        guard let catalog else {
            // The app hasn't written anything readable: the state isn't known, but a tap can
            // still check it in the app.
            return AppleHomePowerControlDisplay(title: title, state: .unknown, kind: nil, status: nil)
        }
        switch catalog.availability {
        case .off:
            return AppleHomePowerControlDisplay(title: title, state: .unavailable(.appleHomeOff), kind: nil, status: nil)
        case .denied, .restricted, .noHome:
            return AppleHomePowerControlDisplay(title: title, state: .unavailable(.noAccess), kind: nil, status: nil)
        case .ready:
            break
        }
        guard let target else {
            return AppleHomePowerControlDisplay(title: title, state: .unavailable(.targetGone), kind: nil, status: nil)
        }
        let stored = catalog.state(targetID)
        let state: State
        if let isOn = stored?.isOn, let checkedAt = stored?.checkedAt {
            state = HomeGlanceFreshness.of(checkedAt, now: now) == .recent ? (isOn ? .on : .off) : .lastSeen(isOn: isOn)
        } else {
            state = .unknown
        }
        return AppleHomePowerControlDisplay(title: title, state: state, kind: target.kind, status: status(of: stored, now: now))
    }

    private static func status(of state: AppleHomePowerState?, now: Date) -> String? {
        guard let state, let result = state.lastResult, let at = state.resultAt else { return nil }
        let age = now.timeIntervalSince(at)
        guard age >= -60, age <= statusWindow else { return nil }
        switch result {
        case .confirmed:
            return nil
        case .checked:
            return String(localized: "현재 상태를 확인했습니다", comment: "Control Center status: the state was read, nothing was sent")
        case let .failed(failure):
            return failure.message
        }
    }
}
