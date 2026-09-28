import Foundation
import Observation
import os

/// Settings sharing with the Linux sensor hub the app follows (a hub picked in "허브 찾기", by its
/// `hub_id`): whether this device uses the hub's home name, rooms and sensor names/rooms, keeping
/// that copy current, and saving changes through the hub.
///
/// Rules this type enforces:
/// - **The hub decides.** A change is done only when the hub has stored it; the app then shows the
///   hub's confirmed copy. Every change names the revision it was based on, so an edit made against
///   an old copy is refused (`.conflict`) instead of overwriting a newer change or deletion.
/// - **An editor saves only what it showed.** An editor records the revision it opened with
///   (`ConfigurationEditBase`); when a newer copy arrived meanwhile — even by an automatic check
///   that finishes right before the save — nothing is sent, the newer copy is on screen and the
///   editor shows it again with the conflict notice.
/// - **Nothing is uploaded by itself.** A device's own settings reach the hub only when the user
///   uploads them from this device, after seeing what will be shared, and only to a hub that has no
///   settings yet. A hub that already has settings is downloaded from.
/// - **The device's own settings are never changed.** While sharing, the app shows the hub's copy;
///   `SwiftDataHomeConfigurationStore` is left exactly as it was and comes back when sharing is off.
/// - **Offline shows, never edits.** With the hub unreachable (or this device's access revoked) the
///   last confirmed copy stays on screen and editing is refused with the reason. There is no queue
///   of offline changes.
/// - **No extra connections.** New revisions are noticed through the snapshots the app already
///   receives (SSE and its periodic refresh carry `settings_revision`); a fetch happens only when the
///   revision differs, when the app returns to the foreground, or when the user asks, one at a time,
///   and never more often than `retryInterval` after a failure.
@MainActor
@Observable
final class SharedSettingsController {
    enum Status: Equatable {
        /// Not sharing with the current source: the device's own settings are in use.
        case localOnly
        /// Sharing; confirming the copy on screen with the hub.
        case checking
        /// Sharing; the hub confirmed the copy on screen.
        case shared
        /// Sharing; another device saved first. The latest settings are on screen now.
        case conflict
        /// Sharing; the last confirmed copy is on screen and can't be changed right now.
        case failed(Failure)
    }

    enum Failure: Equatable {
        case hubUnreachable
        /// This device's token was refused (access revoked on the hub).
        case unauthorized
        /// The hub presented a different TLS certificate than at pairing. Nothing was sent.
        case certificateChanged
        /// The hub can't read its settings file (`corrupt`/`io`), or its device list.
        case hubSettingsUnavailable
        /// The hub has no shared settings any more (removed on the hub).
        case hubHasNoSettings
        /// The hub no longer offers settings sharing.
        case notSupported
        case other
    }

    private(set) var status: Status = .localOnly
    /// The hub the app follows, when it follows one by `hub_id`.
    private(set) var hubID: String?
    private(set) var baseURL: URL?
    /// Whether this device holds a credential for `hubID`.
    private(set) var isPaired = false
    private(set) var pairedDeviceID: String?
    private(set) var pinnedCertificate: String?
    /// The hub's settings this device uses, or `nil` when it uses its own.
    private(set) var entry: SharedSettingsCacheEntry?
    /// `entry` as the app's configuration.
    private(set) var activeConfiguration: HomeConfigurationSnapshot?
    /// A change is being saved through the hub.
    private(set) var isSaving = false
    /// What the latest snapshot said about the hub's settings (`nil`: the hub doesn't offer sharing).
    private(set) var hubSignal: HubSettingsSignal?
    private(set) var lastConfirmedAt: Date?

    var isActive: Bool { entry != nil }

    var canEdit: Bool {
        guard isActive else { return true }
        return status == .shared || status == .conflict
    }

    /// Why editing is off, for showing next to disabled controls. `nil` while editing works.
    var editBlockedReason: String? {
        guard isActive, !canEdit else { return nil }
        switch status {
        case .checking:
            return String(localized: "허브와 공유 설정을 확인하는 중입니다. 잠시 후 다시 시도하세요.", comment: "Shared settings: editing waits for the first check with the hub")
        case let .failed(failure):
            return Self.message(for: failure)
        case .localOnly, .shared, .conflict:
            return nil
        }
    }

    private let transport: HubSettingsTransport
    private let credentials: HubCredentialStoring
    private let cache: SharedSettingsCaching
    private let language: AppLanguage
    private let retryInterval: Duration
    private let clock = ContinuousClock()
    /// The sensor snapshot from the current source — which modules this hub has, by real module UUID.
    var sourceSnapshot: () -> HomeSnapshot = { HomeSnapshot(timestamp: Date(), rooms: [], modules: []) }
    /// Called whenever `activeConfiguration` changes, so the app re-applies names and rooms.
    var onConfigurationChange: () -> Void = {}

    private var credential: HubCredential?
    private var generation = 0
    private var fetchTask: Task<Void, Never>?
    private var lastFailedFetch: ContinuousClock.Instant?
    /// A newer revision a snapshot reported while a check or a save was already under way: checked
    /// once more right after it, instead of waiting for the next snapshot.
    private var revisionSeenWhileBusy: String?
    private var saveWaiters: [CheckedContinuation<Void, Never>] = []

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.junsoona.PogoHome", category: "SharedSettings")

    init(
        transport: HubSettingsTransport = URLSessionHubSettingsTransport(),
        credentials: HubCredentialStoring = KeychainHubCredentialStore(),
        cache: SharedSettingsCaching = FileSharedSettingsCache(),
        language: AppLanguage = .current,
        retryInterval: Duration = .seconds(10)
    ) {
        self.transport = transport
        self.credentials = credentials
        self.cache = cache
        self.language = language
        self.retryInterval = retryInterval
    }

    // MARK: - Following the source

    /// The app now reads `hubID` (a hub picked in "허브 찾기") at `baseURL`, or simulated data / a typed
    /// address (`hubID == nil`, never shared). Another hub's settings never carry over.
    func sourceDidChange(hubID newHubID: String?, baseURL newBaseURL: URL?) {
        let normalized = newHubID?.lowercased()
        guard normalized != hubID else {
            let moved = newBaseURL != baseURL
            baseURL = newBaseURL
            if moved && isActive { scheduleFetch(force: true) }
            return
        }
        generation += 1
        fetchTask?.cancel()
        fetchTask = nil
        lastFailedFetch = nil
        revisionSeenWhileBusy = nil
        hubID = normalized
        baseURL = newBaseURL
        hubSignal = nil
        reloadStoredState()
        if isActive { scheduleFetch(force: true) }
    }

    /// Reads this hub's credential and cached copy (after launch, a source change, or unpairing).
    private func reloadStoredState() {
        credential = nil
        isPaired = false
        pairedDeviceID = nil
        pinnedCertificate = nil
        var newEntry: SharedSettingsCacheEntry?
        if let hubID {
            do {
                credential = try credentials.credential(forHubID: hubID)
            } catch {
                Self.logger.error("hub credential unreadable: \(String(describing: error), privacy: .public)")
            }
            isPaired = credential != nil
            pairedDeviceID = credential?.deviceID
            pinnedCertificate = credential?.certificateSHA256
            newEntry = cache.entry(forHubID: hubID)
        }
        setEntry(newEntry)
        if isActive {
            status = credential == nil ? .failed(.unauthorized) : .checking
        } else {
            status = .localOnly
        }
    }

    private func setEntry(_ newEntry: SharedSettingsCacheEntry?) {
        let changed = newEntry != entry
        entry = newEntry
        activeConfiguration = newEntry.map { HubSettingsMapping.configuration(from: $0.settings, language: language) }
        if changed { onConfigurationChange() }
    }

    /// Every snapshot from the current source reports the hub's settings revision.
    func observe(_ signal: HubSettingsSignal?) {
        hubSignal = signal
        guard isActive, let entry else { return }
        guard let signal else {
            status = .failed(.notSupported)
            return
        }
        switch signal.state {
        case .unavailable:
            status = .failed(.hubSettingsUnavailable)
        case .uninitialized, .ready:
            if signal.revision != entry.revision {
                if fetchTask != nil || isSaving { revisionSeenWhileBusy = signal.revision }
                scheduleFetch(force: false)
            } else if status == .checking || status.retriesAutomatically {
                // Reachable again with nothing new: confirm this device still has access. A refused
                // token or certificate is not retried by itself (only on a new revision, a return to
                // the foreground, or "다시 시도"), so a revoked device never polls the hub.
                scheduleFetch(force: false)
            }
        }
    }

    /// The live connection's state: a hub that stopped answering can't take changes.
    func connectionStatusDidChange(_ connection: DataSourceConnectionStatus) {
        guard isActive else { return }
        switch connection {
        case .failed, .reconnecting:
            if status == .shared || status == .conflict || status == .checking {
                status = .failed(.hubUnreachable)
            }
        case .connected, .connecting, .idle:
            break
        }
    }

    /// The app came back to the foreground: check once for changes made meanwhile.
    func resume() {
        guard isActive else { return }
        scheduleFetch(force: true)
    }

    /// "다시 시도".
    func retry() {
        guard isActive else { return }
        scheduleFetch(force: true)
    }

    /// The conflict notice was read.
    func acknowledgeConflict() {
        if status == .conflict { status = .shared }
    }

    private func scheduleFetch(force: Bool) {
        guard fetchTask == nil, !isSaving, let hubID, let baseURL, let credential else {
            if isActive && credential == nil { status = .failed(.unauthorized) }
            return
        }
        if !force, let lastFailedFetch, clock.now - lastFailedFetch < retryInterval { return }
        if status == .localOnly { status = .checking }
        let session = generation
        let transport = transport
        fetchTask = Task { [weak self] in
            let result: Result<HubSettingsState, Error>
            do {
                result = .success(try await transport.fetchSettings(baseURL: baseURL, credential: credential))
            } catch {
                result = .failure(error)
            }
            guard let self, self.generation == session, self.hubID == hubID else { return }
            self.fetchTask = nil
            self.handleFetch(result)
            self.followUpIfNeeded()
        }
    }

    /// One more check when a snapshot announced a revision this device didn't get from the check or
    /// save that was running then. At most once per announced revision, so it can never loop.
    private func followUpIfNeeded() {
        guard let pending = revisionSeenWhileBusy else { return }
        revisionSeenWhileBusy = nil
        guard pending != entry?.revision, fetchTask == nil, !isSaving, isActive else { return }
        if case .failed = status { return }
        scheduleFetch(force: true)
    }

    private func handleFetch(_ result: Result<HubSettingsState, Error>) {
        switch result {
        case let .success(state):
            lastFailedFetch = nil
            guard state.initialized, let revision = state.revision, let settings = state.settings else {
                status = .failed(.hubHasNoSettings)
                return
            }
            confirm(revision: revision, updatedAt: state.updatedAtUnixMs ?? 0, settings: settings)
            if status != .conflict { status = .shared }
        case let .failure(error):
            lastFailedFetch = clock.now
            status = .failed(Self.failure(for: error))
            Self.logger.notice("shared settings check failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Makes `settings` at `revision` the copy on screen and on disk.
    private func confirm(revision: String, updatedAt: Int64, settings: HubSettingsDocument) {
        guard let hubID else { return }
        let newEntry = SharedSettingsCacheEntry(hubID: hubID, revision: revision, updatedAtUnixMs: updatedAt, settings: settings, confirmedAt: Date())
        do {
            try cache.save(newEntry)
        } catch {
            // Still correct on screen; only the copy shown while offline may be older.
            Self.logger.error("could not store the shared settings copy: \(String(describing: error), privacy: .public)")
        }
        lastConfirmedAt = newEntry.confirmedAt
        if entry?.revision != revision || entry?.settings != settings {
            setEntry(newEntry)
        } else {
            entry = newEntry
        }
    }

    // MARK: - Editing

    /// Applies `edit` to a copy of the shared settings with exactly the checks the device's own
    /// store makes, then saves the result through the hub. Returns once the hub has stored it; the
    /// app then shows the hub's confirmed copy.
    ///
    /// With `base` naming the revision an editor opened with, a newer copy on this device refuses
    /// the edit (`.conflict`) before anything is sent: the editor's values are older than what is
    /// on screen, and saving them would undo another device's change.
    func performEdit<T>(basedOn base: ConfigurationEditBase = .current, _ edit: (HomeConfigurationStore) throws -> T) async throws -> T {
        guard isActive else { throw SharedSettingsEditError.notSharing }
        guard canEdit else { throw SharedSettingsEditError.unavailable(editBlockedReason ?? "") }
        await acquireSaveSlot()
        defer { releaseSaveSlot() }
        // A check that was already under way finishes first, so the edit starts from the newest copy.
        if let fetchTask { await fetchTask.value }
        guard let entry, let credential, let baseURL, let activeConfiguration else {
            throw SharedSettingsEditError.notSharing
        }
        guard canEdit else { throw SharedSettingsEditError.unavailable(editBlockedReason ?? "") }
        if case let .revision(expected) = base, expected != entry.revision {
            Self.logger.notice("edit based on \(expected ?? "-", privacy: .public) not sent: \(entry.revision, privacy: .public) is on screen")
            status = .conflict
            throw SharedSettingsEditError.conflict
        }

        let scratch = InMemoryHomeConfigurationStore(
            rooms: activeConfiguration.rooms,
            modules: activeConfiguration.modules,
            customHomeName: activeConfiguration.customHomeName,
            language: language
        )
        let result = try edit(scratch)
        let rawIdentifiers = HubSettingsMapping.rawIdentifiers(document: entry.settings, snapshot: sourceSnapshot())
        let document = HubSettingsMapping.document(from: try scratch.load(), rawIdentifiers: rawIdentifiers)
        guard document != entry.settings else { return result }

        do {
            let state = try await transport.putSettings(baseURL: baseURL, credential: credential, baseRevision: entry.revision, settings: document)
            guard let revision = state.revision, let settings = state.settings else {
                throw HubSettingsError.unreachable("settings reply")
            }
            confirm(revision: revision, updatedAt: state.updatedAtUnixMs ?? 0, settings: settings)
            status = .shared
            return result
        } catch let HubSettingsError.conflict(current) {
            if current.initialized, let revision = current.revision, let settings = current.settings {
                confirm(revision: revision, updatedAt: current.updatedAtUnixMs ?? 0, settings: settings)
                status = .conflict
            } else {
                status = .failed(.hubHasNoSettings)
            }
            throw SharedSettingsEditError.conflict
        } catch HubSettingsError.saveFailed {
            throw SharedSettingsEditError.hubCouldNotSave
        } catch let HubSettingsError.invalid(detail) {
            throw SharedSettingsEditError.rejected(detail)
        } catch {
            let failure = Self.failure(for: error)
            status = .failed(failure)
            throw SharedSettingsEditError.unavailable(Self.message(for: failure))
        }
    }

    private func acquireSaveSlot() async {
        if isSaving {
            await withCheckedContinuation { saveWaiters.append($0) }
        }
        isSaving = true
    }

    private func releaseSaveSlot() {
        if saveWaiters.isEmpty {
            isSaving = false
            followUpIfNeeded()
        } else {
            // Handed straight to the next edit, which sets `isSaving` again itself.
            saveWaiters.removeFirst().resume()
        }
    }

    // MARK: - Turning sharing on and off

    /// Registers this device with the hub using the operator's one-time code, then reads the hub's
    /// settings. Sharing is not on yet: the caller shows what will happen and then calls
    /// `useHubSettings(_:)` or `uploadAsFirstSettings(_:)`.
    func pair(code input: String, deviceName: String) async throws -> HubSettingsState {
        guard let hubID, let baseURL else { throw SharedSettingsEditError.needsDiscoveredHub }
        guard let code = HubPairingCode.normalized(input) else { throw SharedSettingsPairingError.malformedCode }
        let name = Self.deviceName(deviceName)
        let session = generation
        let newCredential: HubCredential
        do {
            newCredential = try await transport.pair(baseURL: baseURL, hubID: hubID, code: code, deviceName: name)
        } catch let error as HubSettingsError {
            throw SharedSettingsPairingError(error)
        }
        guard generation == session, self.hubID == hubID else { throw SharedSettingsPairingError.hubChanged }
        try credentials.save(newCredential)
        credential = newCredential
        isPaired = true
        pairedDeviceID = newCredential.deviceID
        pinnedCertificate = newCredential.certificateSHA256
        Self.logger.notice("paired with hub \(hubID, privacy: .public) as device \(newCredential.deviceID, privacy: .public)")
        return try await fetchForSetup()
    }

    /// The hub's settings as they are now, for the setup screen of a paired device.
    func fetchForSetup() async throws -> HubSettingsState {
        guard let baseURL, let credential else { throw SharedSettingsEditError.notSharing }
        do {
            return try await transport.fetchSettings(baseURL: baseURL, credential: credential)
        } catch let error as HubSettingsError {
            throw SharedSettingsPairingError(error)
        }
    }

    /// Uses the hub's settings on this device (download). The device's own settings stay as they are.
    func useHubSettings(_ state: HubSettingsState) throws {
        guard state.initialized, let revision = state.revision, let settings = state.settings else {
            throw SharedSettingsPairingError.hubHasNoSettings
        }
        guard state.hubID.lowercased() == hubID else { throw SharedSettingsPairingError.hubChanged }
        confirm(revision: revision, updatedAt: state.updatedAtUnixMs ?? 0, settings: settings)
        status = .shared
    }

    enum UploadOutcome: Equatable {
        case uploaded
        /// Another device uploaded first; its settings are used instead (nothing was overwritten).
        case hubAlreadyHadSettings
    }

    /// Makes `document` — this device's settings, as the user just reviewed them — the hub's first
    /// settings. Only ever succeeds on a hub without settings: the hub refuses a first upload once
    /// any device has uploaded, and this then uses that device's settings.
    func uploadAsFirstSettings(_ document: HubSettingsDocument) async throws -> UploadOutcome {
        guard let baseURL, let credential else { throw SharedSettingsEditError.notSharing }
        do {
            let state = try await transport.putSettings(baseURL: baseURL, credential: credential, baseRevision: nil, settings: document)
            try useHubSettings(state)
            return .uploaded
        } catch let HubSettingsError.conflict(current) {
            try useHubSettings(current)
            return .hubAlreadyHadSettings
        } catch let error as HubSettingsError {
            throw SharedSettingsPairingError(error)
        }
    }

    /// "이 기기에서 공유 끄기": back to this device's own settings, and this device's access removed from
    /// the hub (best effort — without the hub, the operator can still revoke it there).
    func stopSharing() async {
        guard let hubID else { return }
        if let credential, let baseURL {
            do {
                try await transport.unpair(baseURL: baseURL, credential: credential)
            } catch {
                Self.logger.notice("could not remove this device on the hub: \(String(describing: error), privacy: .public)")
            }
        }
        guard self.hubID == hubID else { return }
        try? cache.removeEntry(forHubID: hubID)
        try? credentials.deleteCredential(forHubID: hubID)
        generation += 1
        fetchTask?.cancel()
        fetchTask = nil
        reloadStoredState()
    }

    // MARK: - Messages

    /// The name the hub lists this device under (`pogohome-hubctl devices`): what the user typed, or
    /// the app's name when the field was left empty.
    static func deviceName(_ proposed: String) -> String {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? Brand.appName : trimmed
        return String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(60).map(Character.init))
    }

    static func failure(for error: Error) -> Failure {
        switch error as? HubSettingsError {
        case .unauthorized: return .unauthorized
        case .certificateMismatch: return .certificateChanged
        case .unavailable: return .hubSettingsUnavailable
        case .notSupported: return .notSupported
        case .unreachable: return .hubUnreachable
        default: return .other
        }
    }

    static func message(for failure: Failure) -> String {
        switch failure {
        case .hubUnreachable:
            return String(localized: "허브에 연결할 수 없어 공유 설정을 바꿀 수 없습니다. 마지막으로 받은 설정을 보여 주고 있습니다.", comment: "Shared settings: hub offline, editing disabled")
        case .unauthorized:
            return String(localized: "이 기기의 허브 접근 권한이 없습니다. 설정에서 허브에 다시 연결하세요.", comment: "Shared settings: token refused (revoked)")
        case .certificateChanged:
            return String(localized: "허브의 인증서가 연결할 때와 다릅니다. 안전을 위해 아무것도 보내지 않았습니다. 설정에서 허브에 다시 연결하세요.", comment: "Shared settings: pinned certificate mismatch")
        case .hubSettingsUnavailable:
            return String(localized: "허브가 공유 설정 파일을 읽지 못하고 있습니다. 허브 관리자가 확인해야 합니다.", comment: "Shared settings: hub reports its settings file unavailable")
        case .hubHasNoSettings:
            return String(localized: "허브에 공유 설정이 없습니다. 설정에서 공유를 끄거나 다시 설정하세요.", comment: "Shared settings: the hub's settings were removed")
        case .notSupported:
            return String(localized: "이 허브는 설정 공유를 지원하지 않습니다.", comment: "Shared settings: hub without the settings API")
        case .other:
            return String(localized: "허브와 설정을 동기화하지 못했습니다.", comment: "Shared settings: generic sync failure")
        }
    }
}

extension SharedSettingsController.Status {
    /// Failures that can clear up by themselves (the hub coming back), so a snapshot from the hub is
    /// a reason to check again.
    var retriesAutomatically: Bool {
        switch self {
        case .failed(.hubUnreachable), .failed(.hubSettingsUnavailable), .failed(.other): return true
        default: return false
        }
    }
}

/// Which copy of the settings an edit was made from (see `SharedSettingsController.performEdit`).
nonisolated enum ConfigurationEditBase: Equatable, Sendable {
    /// Applies to whatever copy is current once the save starts (adding a room, deleting one).
    case current
    /// The hub revision that was on screen when the editor opened (`nil`: this device's own
    /// settings were). While sharing, a different revision at save time refuses the edit.
    case revision(String?)
}

/// Why a change to shared settings was not saved.
nonisolated enum SharedSettingsEditError: LocalizedError, Equatable {
    case notSharing
    case needsDiscoveredHub
    /// Editing is off right now; the argument says why.
    case unavailable(String)
    /// Another device saved first; the latest settings are shown now.
    case conflict
    case hubCouldNotSave
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .notSharing:
            return String(localized: "허브와 설정을 공유하고 있지 않습니다.", comment: "Shared settings error")
        case .needsDiscoveredHub:
            return String(localized: "‘허브 찾기’로 선택한 허브만 설정을 공유할 수 있습니다.", comment: "Shared settings error: sharing needs a hub picked in Find hubs")
        case let .unavailable(reason):
            return reason
        case .conflict:
            return String(localized: "다른 기기에서 먼저 설정을 바꿨습니다. 최신 설정을 불러왔으니 확인한 뒤 다시 수정하세요.", comment: "Shared settings: edit conflict")
        case .hubCouldNotSave:
            return String(localized: "허브가 설정을 저장하지 못했습니다. 바뀐 것은 없습니다. 잠시 후 다시 시도하세요.", comment: "Shared settings: hub reported a save failure")
        case let .rejected(detail):
            return String(localized: "허브가 이 설정을 받아들이지 않았습니다. (\(detail))", comment: "Shared settings: hub rejected the change; argument is a technical code")
        }
    }
}

/// Why pairing or the first shared settings did not work.
nonisolated enum SharedSettingsPairingError: LocalizedError, Equatable {
    case malformedCode
    case wrongCode
    case codeExpired
    case noActiveCode
    case tooManyDevices
    case hubIdentityMismatch
    case hubChanged
    case hubHasNoSettings
    case notSupported
    case hubUnavailable
    case unreachable(String)
    case other(String)

    init(_ error: HubSettingsError) {
        switch error {
        case let .pairingRejected(reason):
            switch reason {
            case "expired": self = .codeExpired
            case "no_active_code": self = .noActiveCode
            default: self = .wrongCode
            }
        case .tooManyDevices: self = .tooManyDevices
        case .hubIdentityMismatch, .certificateMismatch: self = .hubIdentityMismatch
        case .notSupported: self = .notSupported
        case .unavailable, .saveFailed: self = .hubUnavailable
        case let .unreachable(detail): self = .unreachable(detail)
        case .unauthorized: self = .other("401")
        case let .invalid(detail): self = .other(detail)
        case .conflict: self = .other("409")
        }
    }

    var errorDescription: String? {
        switch self {
        case .malformedCode:
            return String(localized: "연결 코드는 12자리입니다. 허브에서 받은 코드를 확인하세요.", comment: "Pairing: code has the wrong shape")
        case .wrongCode:
            return String(localized: "연결 코드가 맞지 않습니다. 5번 틀리면 코드가 폐기되니 허브에서 새 코드를 만드세요.", comment: "Pairing: wrong code (or impostor)")
        case .codeExpired:
            return String(localized: "연결 코드가 만료되었습니다. 허브에서 새 코드를 만드세요.", comment: "Pairing: code expired")
        case .noActiveCode:
            return String(localized: "허브에 사용할 수 있는 연결 코드가 없습니다. 이미 사용했거나 폐기된 코드입니다. 허브에서 새 코드를 만드세요.", comment: "Pairing: no code waiting on the hub")
        case .tooManyDevices:
            return String(localized: "허브에 연결된 기기가 너무 많습니다. 허브에서 쓰지 않는 기기를 해제하세요.", comment: "Pairing: device limit reached")
        case .hubIdentityMismatch:
            return String(localized: "허브를 확인하지 못해 연결하지 않았습니다. 같은 네트워크의 올바른 허브인지 확인하세요.", comment: "Pairing: the hub's proof or identity did not check out")
        case .hubChanged:
            return String(localized: "연결하는 동안 선택한 허브가 바뀌었습니다. 다시 시도하세요.", comment: "Pairing: the selected hub changed meanwhile")
        case .hubHasNoSettings:
            return String(localized: "허브에 공유 설정이 없습니다.", comment: "Pairing: hub has no settings")
        case .notSupported:
            return String(localized: "이 허브는 설정 공유를 지원하지 않습니다. 허브를 최신 버전으로 업데이트하세요.", comment: "Pairing: hub without the settings API")
        case .hubUnavailable:
            return String(localized: "허브가 지금 설정을 처리할 수 없습니다. 허브 관리자가 확인해야 합니다.", comment: "Pairing: hub storage unavailable")
        case let .unreachable(detail):
            return String(localized: "허브가 응답하지 않습니다. (\(detail))", comment: "Hub discovery: health check failed; argument is a technical detail")
        case let .other(detail):
            return String(localized: "허브와 연결하지 못했습니다. (\(detail))", comment: "Pairing: other failure; argument is a technical code")
        }
    }
}
