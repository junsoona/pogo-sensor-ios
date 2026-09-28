import Foundation
import Observation
import os

/// App-wide Apple Home state, kept entirely separate from `AppModel`: turning Apple Home on or
/// off, being denied access, or having no home never touches the POGO sensor data, its
/// configuration store or its reconnect logic.
///
/// Apple Home stays off until the user turns it on (Devices tab or Settings), so HomeKit's
/// permission prompt appears only in response to that tap. The choice is remembered, and on
/// later launches the provider starts again by itself.
@MainActor
@Observable
final class AppleHomeModel: DeviceCommandPerforming {
    enum SetupState: Equatable {
        case idle
        /// Apple's setup sheet is on screen.
        case running
        /// Apple Home reported the accessories it added. PogoHome creates nothing itself; the
        /// devices appear only once HomeKit lists them.
        case succeeded(AppleHomeSetupResult)
        case cancelled
        case failed(String)
    }

    private(set) var snapshot: AppleHomeSnapshot = .off
    private(set) var isEnabled: Bool
    /// Requested values still waiting for the device, keyed by control (characteristic) id.
    private(set) var pendingValues: [UUID: DeviceControlValue] = [:]
    /// The last failure/unconfirmed message per control, cleared by the next attempt.
    private(set) var controlMessages: [UUID: String] = [:]
    private(set) var refreshingAccessoryIDs: Set<UUID> = []
    /// Controls whose write went through but whose result couldn't be read back, with the
    /// characteristic's `confirmedAt` at that moment. Until a newer value arrives, the old one
    /// is not presented as the current state (see `confirmedValue(of:accessoryID:)`).
    private(set) var unverifiedWrites: [UUID: Date?] = [:]
    private(set) var setupState: SetupState = .idle
    /// Apple Home accessory id → POGO module id the user marked as the same device.
    private(set) var links: [UUID: UUID]

    private let provider: AppleHomeProvider
    private let defaults: UserDefaults
    private var isProviderRunning = false

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.junsoona.PogoHome",
        category: "AppleHome"
    )

    init(provider: AppleHomeProvider, defaults: UserDefaults = .standard) {
        self.provider = provider
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: AppleHomeSettingsKeys.enabled)
        let stored = defaults.dictionary(forKey: AppleHomeSettingsKeys.pogoLinks) as? [String: String] ?? [:]
        self.links = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            guard let accessory = UUID(uuidString: key), let module = UUID(uuidString: value) else { return nil }
            return (accessory, module)
        })
    }

    var isAccessorySetupAvailable: Bool { provider.isAccessorySetupAvailable }
    var accessorySetupSupport: AppleHomeAccessorySetupSupport { provider.accessorySetupSupport }

    /// Resumes Apple Home on launch if the user turned it on earlier. Never prompts by itself.
    func startIfEnabled() {
        guard isEnabled else { return }
        startProvider()
    }

    /// The user asked to see Apple Home devices: may show HomeKit's permission prompt.
    func enable() {
        isEnabled = true
        defaults.set(true, forKey: AppleHomeSettingsKeys.enabled)
        startProvider()
    }

    /// Stops reading Apple Home in PogoHome. Nothing is removed from Apple Home.
    func disable() {
        isEnabled = false
        defaults.set(false, forKey: AppleHomeSettingsKeys.enabled)
        if isProviderRunning {
            provider.stop()
            isProviderRunning = false
        }
        snapshot = .off
        controlMessages = [:]
        refreshingAccessoryIDs = []
        unverifiedWrites = [:]
    }

    /// Picks up anything HomeKit changed while PogoHome wasn't looking (e.g. rooms edited in the
    /// Home app while PogoHome was in the background).
    func resynchronize() {
        guard isProviderRunning else { return }
        provider.resynchronize()
    }

    private func startProvider() {
        guard !isProviderRunning else { return }
        isProviderRunning = true
        provider.start { [weak self] next in
            guard let self, self.isProviderRunning else { return }
            self.snapshot = next
        }
    }

    // MARK: - Reading

    func refresh(accessoryID: UUID) async {
        guard snapshot.accessState == .ready, !refreshingAccessoryIDs.contains(accessoryID) else { return }
        refreshingAccessoryIDs.insert(accessoryID)
        defer { refreshingAccessoryIDs.remove(accessoryID) }
        do {
            try await provider.refresh(accessoryID: accessoryID)
        } catch {
            // The provider records the failure on the accessory (`lastReadError`).
            Self.logger.notice("refresh failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Controls

    /// Sets one control and reports `.confirmed` only after reading the requested value back
    /// from the device. Every other ending leaves the confirmed value untouched and records a
    /// message for the control.
    func perform(_ command: DeviceCommand) async -> DeviceCommandOutcome {
        let controlID = command.controlID
        guard command.device.source == .appleHome else {
            return .rejected(String(localized: "이 기기는 앱에서 제어할 수 없습니다.", comment: "Control rejected: device is read-only"))
        }
        guard snapshot.accessState == .ready, let accessory = snapshot.accessory(with: command.device.rawValue) else {
            return reject(controlID, Self.message(for: AppleHomeProviderError.accessoryNotFound))
        }
        guard accessory.isOperable else {
            return reject(controlID, Self.message(for: AppleHomeProviderError.notReachable))
        }
        guard
            let control = AppleHomeCapabilities.controls(of: accessory).first(where: { $0.id == controlID }),
            control.kind == command.kind,
            let raw = AppleHomeCapabilities.rawValue(for: command.value, kind: command.kind)
        else {
            return reject(controlID, Self.message(for: AppleHomeProviderError.characteristicNotFound))
        }
        if case let .percent(percent) = command.value, let range = control.range, !range.contains(percent) {
            return reject(controlID, String(localized: "기기가 지원하는 범위를 벗어난 값입니다.", comment: "Control rejected: value out of range"))
        }
        guard pendingValues[controlID] == nil else {
            return .rejected(String(localized: "이전 요청을 처리하는 중입니다.", comment: "Control rejected: a previous request is still running"))
        }

        pendingValues[controlID] = command.value
        controlMessages[controlID] = nil
        defer { pendingValues[controlID] = nil }

        do {
            try await provider.write(raw, characteristicID: controlID, accessoryID: accessory.id)
        } catch {
            let message = Self.message(for: error)
            controlMessages[controlID] = message
            Self.logger.notice("write failed: \(String(describing: error), privacy: .public)")
            return .failed(message)
        }

        do {
            try await provider.refresh(accessoryID: accessory.id)
        } catch {
            let message = String(localized: "명령은 전달됐지만 기기의 현재 상태를 확인하지 못했습니다.", comment: "Control: write succeeded, read-back failed")
            controlMessages[controlID] = message
            // The device may or may not have switched: the value from before the write is no
            // longer known to be current.
            unverifiedWrites[controlID] = snapshot.accessory(with: accessory.id)?.characteristic(with: controlID)?.confirmedAt
            return .unconfirmed(message)
        }

        let reported = snapshot.accessory(with: accessory.id)?
            .characteristic(with: controlID)?
            .value
            .map { AppleHomeCapabilities.controlValue(from: $0, kind: command.kind) }
        guard let reported, Self.matches(reported, command.value) else {
            let message = String(localized: "기기가 요청한 상태를 보고하지 않았습니다.", comment: "Control: device reports a different value after the write")
            controlMessages[controlID] = message
            return .unconfirmed(message)
        }
        unverifiedWrites[controlID] = nil
        return .confirmed
    }

    /// The control's value as far as PogoHome knows it right now: the last value read back from
    /// the device, or `nil` if none was read, or if a write since then couldn't be confirmed and
    /// nothing newer has been read.
    func confirmedValue(of control: DeviceAvailableControl, accessoryID: UUID) -> DeviceControlValue? {
        if let marked = unverifiedWrites[control.id] {
            let current = snapshot.accessory(with: accessoryID)?.characteristic(with: control.id)?.confirmedAt
            guard let current, current != marked else { return nil }
        }
        return control.confirmedValue
    }

    // MARK: - Tiles

    func quickControl(for accessory: AppleHomeAccessory) -> AppleHomeQuickControl {
        AppleHomeQuickControl.resolve(accessory, isAccessReady: snapshot.accessState == .ready) {
            confirmedValue(of: $0, accessoryID: accessory.id)
        }
    }

    /// Whether the tile's icon is busy (a command or a read for it is running).
    func isQuickControlBusy(_ accessory: AppleHomeAccessory) -> Bool {
        if refreshingAccessoryIDs.contains(accessory.id) { return true }
        return AppleHomeQuickControl.onOffControls(of: accessory).contains { pendingValues[$0.id] != nil }
    }

    /// The tile icon's tap. Sends a command only for `.toggle`, through `perform(_:)`, so it is
    /// confirmed exactly like the detail screen's controls; returns `nil` when nothing was sent
    /// (busy, a state read, or no quick control).
    @discardableResult
    func performQuickAction(for accessoryID: UUID) async -> DeviceCommandOutcome? {
        guard let accessory = snapshot.accessory(with: accessoryID), !isQuickControlBusy(accessory) else { return nil }
        switch AppleHomeTileAction.iconAction(for: accessory, quickControl: quickControl(for: accessory)) {
        case let .send(command):
            return await perform(command)
        case let .readState(id):
            await refresh(accessoryID: id)
            return nil
        case .openDetail, .none:
            return nil
        }
    }

    // MARK: - Layout

    func layout(pogo: HomeSnapshot) -> AppleHomeLayout {
        // The POGO online flag doesn't affect which Apple Home entries are hidden.
        AppleHomeRoomDirectory.layout(snapshot: snapshot, listing: listing(pogo: pogo, isPogoStateVerified: false))
    }

    private func reject(_ controlID: UUID, _ message: String) -> DeviceCommandOutcome {
        controlMessages[controlID] = message
        return .rejected(message)
    }

    /// Devices may round a percentage by one step.
    private static func matches(_ reported: DeviceControlValue, _ requested: DeviceControlValue) -> Bool {
        switch (reported, requested) {
        case let (.percent(a), .percent(b)): return abs(a - b) <= 1
        default: return reported == requested
        }
    }

    // MARK: - Adding accessories

    /// Runs Apple's system "Add Accessory" flow (camera / setup code, home, room, name).
    func startAccessorySetup() async {
        guard setupState != .running else { return }
        guard provider.isAccessorySetupAvailable else {
            setupState = .failed(Self.message(for: AppleHomeProviderError.setupUnavailable))
            return
        }
        setupState = .running
        do {
            let result = try await provider.performAccessorySetup()
            setupState = .succeeded(result)
        } catch AppleHomeProviderError.cancelled {
            setupState = .cancelled
        } catch {
            setupState = .failed(Self.message(for: error))
        }
    }

    func clearSetupState() {
        guard setupState != .running else { return }
        setupState = .idle
    }

    // MARK: - Duplicate links

    func linkedModuleID(forAccessory id: UUID) -> UUID? {
        links[id]
    }

    func link(accessoryID: UUID, toPogoModule moduleID: UUID?) {
        links[accessoryID] = moduleID
        let stored = Dictionary(uniqueKeysWithValues: links.map { ($0.key.uuidString, $0.value.uuidString) })
        defaults.set(stored, forKey: AppleHomeSettingsKeys.pogoLinks)
    }

    func listing(pogo: HomeSnapshot, isPogoStateVerified: Bool) -> DeviceDirectory.Listing {
        DeviceDirectory.listing(pogo: pogo, isPogoStateVerified: isPogoStateVerified, appleHome: snapshot, links: links)
    }

    // MARK: - Messages

    /// A failed read's message. A read time-out says the *value* couldn't be read in time, so it
    /// isn't taken as the accessory not responding — HomeKit may still list it as responding.
    static func readMessage(for error: Error) -> String {
        if case .timedOut? = error as? AppleHomeProviderError {
            return String(localized: "값을 제시간에 읽지 못했습니다.", comment: "Apple Home: reading a value timed out (the accessory may still be listed as responding)")
        }
        return message(for: error)
    }

    static func message(for error: Error) -> String {
        switch error as? AppleHomeProviderError {
        case .notAuthorized?:
            return String(localized: "Apple 홈 접근 권한이 없습니다.", comment: "Apple Home error")
        case .accessNotReady?:
            return String(localized: "Apple 홈 값을 읽지 못했습니다. 다시 시도해 주세요.", comment: "Apple Home: authorized, but HomeKit rejected a characteristic read")
        case .accessoryNotFound?:
            return String(localized: "Apple 홈에서 기기를 찾을 수 없습니다.", comment: "Apple Home error")
        case .characteristicNotFound?:
            return String(localized: "기기가 이 기능을 제공하지 않습니다.", comment: "Apple Home error")
        case .notReachable?:
            return String(localized: "기기가 응답하지 않습니다. 전원과 네트워크 연결을 확인하세요.", comment: "Apple Home error")
        case .timedOut?:
            return String(localized: "기기가 제시간에 응답하지 않았습니다.", comment: "Apple Home error")
        case .cancelled?:
            return String(localized: "취소되었습니다.", comment: "Apple Home error")
        case .setupUnavailable?:
            return String(localized: "이 기기에서는 Apple 홈 기기 추가를 사용할 수 없습니다.", comment: "Apple Home error")
        case let .underlying(message)?:
            return message
        case nil:
            return error.localizedDescription
        }
    }
}

enum AppleHomeSettingsKeys {
    static let enabled = "pogohome.appleHome.enabled"
    static let pogoLinks = "pogohome.appleHome.pogoLinks"
}
