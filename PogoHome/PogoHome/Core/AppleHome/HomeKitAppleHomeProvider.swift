#if os(iOS)
import Foundation
import HomeKit

/// Reads and controls Apple Home through HomeKit (`com.apple.developer.homekit` +
/// `NSHomeKitUsageDescription`), and adds accessories through Apple's own setup flow
/// (`HMAccessorySetupManager`, which needs no home-data permission of its own).
///
/// `HMHomeManager` is created only in `start(onChange:)` — creating it is what makes iOS ask
/// for Apple Home access — and released again in `stop()`.
///
/// Values: a characteristic's value is reported only after this provider has read it (or
/// received a notification for it) in this session, together with the time that happened;
/// HomeKit's own cached `value` is never shown on its own because its age is unknown.
///
/// Automatic reads (every accessory once per session, and again after it responds again) go
/// through `AppleHomeAutoReader`: a few accessories at a time, transient failures retried a
/// limited number of times.
@MainActor
final class HomeKitAppleHomeProvider: NSObject, AppleHomeProvider {
    private var manager: HMHomeManager?
    private var onChange: (@MainActor (AppleHomeSnapshot) -> Void)?
    private var hasReceivedHomes = false
    private var confirmedValues: [UUID: (value: AppleHomeRawValue, at: Date)] = [:]
    private var readErrors: [UUID: String] = [:]
    private var notificationCharacteristicIDs: Set<UUID> = []
    private lazy var autoReader: AppleHomeAutoReader = {
        let reader = AppleHomeAutoReader { [weak self] id in
            guard let self else { return AppleHomeReadFailure(error: .cancelled, diagnosticCode: "stopped") }
            return await self.read(accessoryID: id)
        }
        reader.onChange = { [weak self] in self?.publish() }
        return reader
    }()
    /// Bumped by `stop()`, so reads started before it never publish afterwards.
    private var generation = 0

    /// Per characteristic. Where this device isn't the home hub (a Mac), HomeKit relays reads
    /// to the hub, which answers reads that arrive together in one response — as late as the
    /// slowest of them; `AppleHomeAutoReader` keeps that batch small.
    private static let readTimeout: Double = 10
    private static let writeTimeout: Double = 15

    var isAccessorySetupAvailable: Bool { accessorySetupSupport.isAvailable }

    /// iOS has had `HMAccessorySetupManager` since 15; Mac Catalyst only since macOS 27. On
    /// either, reading and controlling existing accessories doesn't depend on it.
    var accessorySetupSupport: AppleHomeAccessorySetupSupport {
        if #available(iOS 27.0, *) {
            return .resolve(hasSetupAPI: true, systemReportsSupported: HMAccessorySetupManager.isSupported)
        }
        #if targetEnvironment(macCatalyst)
        return .resolve(hasSetupAPI: false, systemReportsSupported: nil)
        #else
        return .resolve(hasSetupAPI: true, systemReportsSupported: nil)
        #endif
    }

    func start(onChange: @escaping @MainActor (AppleHomeSnapshot) -> Void) {
        self.onChange = onChange
        if manager == nil {
            let manager = HMHomeManager()
            manager.delegate = self
            self.manager = manager
        }
        publish()
    }

    func resynchronize() {
        publish()
    }

    func stop() {
        generation += 1
        onChange = nil
        if let manager {
            for home in manager.homes {
                home.delegate = nil
                home.accessories.forEach { $0.delegate = nil }
            }
            manager.delegate = nil
        }
        manager = nil
        hasReceivedHomes = false
        confirmedValues = [:]
        readErrors = [:]
        autoReader.reset()
        notificationCharacteristicIDs = []
    }

    // MARK: - Reading

    func refresh(accessoryID: UUID) async throws {
        if let failure = await read(accessoryID: accessoryID) { throw failure.error }
    }

    /// Reads the accessory's supported readable characteristics one after another and publishes
    /// the result. Stops at the first time-out or communication failure: the rest would only
    /// wait for the same unresponsive path.
    private func read(accessoryID: UUID) async -> AppleHomeReadFailure? {
        guard isAuthorized else { return AppleHomeReadFailure(error: .notAuthorized, diagnosticCode: "notAuthorized") }
        guard let accessory = findAccessory(accessoryID) else {
            return AppleHomeReadFailure(error: .accessoryNotFound, diagnosticCode: "accessoryNotFound")
        }
        guard accessory.isReachable, !accessory.isBlocked else {
            return AppleHomeReadFailure(error: .notReachable, diagnosticCode: "notReachable")
        }
        let generation = self.generation
        let stopped = AppleHomeReadFailure(error: .notAuthorized, diagnosticCode: "stopped")
        let readable = Self.supportedCharacteristics(of: accessory).filter {
            $0.properties.contains(HMCharacteristicPropertyReadable)
        }
        var firstFailure: AppleHomeReadFailure?
        for characteristic in readable {
            do {
                try await Self.withTimeout(Self.readTimeout) { done in
                    characteristic.readValue { error in done(error) }
                }
                guard generation == self.generation else { return stopped }
                if let value = Self.rawValue(of: characteristic) {
                    confirmedValues[characteristic.uniqueIdentifier] = (value, Date())
                }
            } catch {
                guard generation == self.generation else { return stopped }
                let failure = AppleHomeReadFailure(
                    error: Self.readError(error, managerAuthorized: isAuthorized),
                    diagnosticCode: Self.diagnosticCode(of: error)
                )
                firstFailure = firstFailure ?? failure
                if failure.error == .timedOut || failure.error == .notReachable || failure.error == .accessNotReady { break }
            }
        }
        guard generation == self.generation else { return stopped }
        readErrors[accessoryID] = firstFailure.map { AppleHomeModel.readMessage(for: $0.error) }
        autoReader.noteRead(accessoryID, succeeded: firstFailure == nil)
        publish()
        return firstFailure
    }

    // MARK: - Writing

    func write(_ value: AppleHomeRawValue, characteristicID: UUID, accessoryID: UUID) async throws {
        guard isAuthorized else { throw AppleHomeProviderError.notAuthorized }
        guard let accessory = findAccessory(accessoryID) else { throw AppleHomeProviderError.accessoryNotFound }
        guard accessory.isReachable, !accessory.isBlocked else { throw AppleHomeProviderError.notReachable }
        guard let characteristic = Self.supportedCharacteristics(of: accessory).first(where: { $0.uniqueIdentifier == characteristicID }),
              characteristic.properties.contains(HMCharacteristicPropertyWritable)
        else { throw AppleHomeProviderError.characteristicNotFound }

        let number: NSNumber
        switch value {
        case let .bool(flag): number = NSNumber(value: flag)
        case let .int(integer): number = NSNumber(value: integer)
        case let .double(double): number = NSNumber(value: double)
        }
        do {
            try await Self.withTimeout(Self.writeTimeout) { done in
                characteristic.writeValue(number) { error in done(error) }
            }
        } catch {
            throw Self.mapped(error)
        }
    }

    // MARK: - Adding accessories

    func performAccessorySetup() async throws -> AppleHomeSetupResult {
        guard #available(macCatalyst 27.0, *) else { throw AppleHomeProviderError.setupUnavailable }
        let setupManager = HMAccessorySetupManager()
        // No payload: the user scans the Matter QR code / enters the setup code in Apple's own
        // flow and picks the home and room there.
        let request = HMAccessorySetupRequest()
        do {
            let result = try await setupManager.performAccessorySetup(using: request)
            return AppleHomeSetupResult(homeID: result.homeUniqueIdentifier, accessoryIDs: result.accessoryUniqueIdentifiers)
        } catch {
            throw Self.mapped(error)
        }
    }

    // MARK: - Snapshot

    private var isAuthorized: Bool {
        guard let manager else { return false }
        return manager.authorizationStatus.contains(.authorized)
    }

    private func publish() {
        guard let onChange else { return }
        onChange(makeSnapshot())
    }

    private func makeSnapshot() -> AppleHomeSnapshot {
        guard let manager else { return .off }
        let status = manager.authorizationStatus
        if status.contains(.restricted) { return AppleHomeSnapshot(accessState: .restricted) }
        if !status.contains(.determined) { return AppleHomeSnapshot(accessState: .loading) }
        if !status.contains(.authorized) { return AppleHomeSnapshot(accessState: .denied) }
        guard hasReceivedHomes else { return AppleHomeSnapshot(accessState: .loading) }
        let homes = manager.homes
        guard !homes.isEmpty else { return AppleHomeSnapshot(accessState: .noHome) }

        var accessories: [AppleHomeAccessory] = []
        for home in homes {
            home.delegate = self
            for accessory in home.accessories {
                accessory.delegate = self
                accessories.append(map(accessory, in: home))
            }
        }
        let homeInfos = homes.map { home in
            AppleHomeInfo(id: home.uniqueIdentifier, name: home.name, isPrimary: home.isPrimary, hubState: Self.hubState(home.homeHubState))
        }
        let homeOrder = Dictionary(uniqueKeysWithValues: homeInfos.enumerated().map { ($1.id, $0) })
        accessories.sort {
            (homeOrder[$0.homeID] ?? 0, $0.roomName ?? "", $0.name) < (homeOrder[$1.homeID] ?? 0, $1.roomName ?? "", $1.name)
        }
        return AppleHomeSnapshot(accessState: .ready, homes: homeInfos, accessories: accessories)
    }

    private func map(_ accessory: HMAccessory, in home: HMHome) -> AppleHomeAccessory {
        // HomeKit puts an accessory with no room in the home's default room
        // (`roomForEntireHome()`); PogoHome shows that as "no room" rather than as a room.
        let room = accessory.room.flatMap { $0.uniqueIdentifier == home.roomForEntireHome().uniqueIdentifier ? nil : $0 }
        return AppleHomeAccessory(
            id: accessory.uniqueIdentifier,
            homeID: home.uniqueIdentifier,
            name: accessory.name,
            roomID: room?.uniqueIdentifier,
            roomName: room?.name,
            isReachable: accessory.isReachable,
            isBlocked: accessory.isBlocked,
            isBridged: accessory.isBridged,
            isMatter: accessory.matterNodeID != nil,
            categoryDescription: accessory.category.localizedDescription,
            manufacturer: accessory.manufacturer,
            model: accessory.model,
            firmwareVersion: accessory.firmwareVersion,
            services: accessory.services.map(map),
            lastReadError: readErrors[accessory.uniqueIdentifier],
            autoRead: autoReader.states[accessory.uniqueIdentifier]
        )
    }

    private func map(_ service: HMService) -> AppleHomeService {
        let visible = service.characteristics.filter { !$0.properties.contains(HMCharacteristicPropertyHidden) }
        let characteristics = visible.compactMap { characteristic -> AppleHomeCharacteristic? in
            guard let kind = Self.characteristicKinds[characteristic.characteristicType.uppercased()] else { return nil }
            let properties = characteristic.properties
            let confirmed = confirmedValues[characteristic.uniqueIdentifier]
            return AppleHomeCharacteristic(
                id: characteristic.uniqueIdentifier,
                kind: kind,
                isReadable: properties.contains(HMCharacteristicPropertyReadable),
                isWritable: properties.contains(HMCharacteristicPropertyWritable),
                supportsNotification: properties.contains(HMCharacteristicPropertySupportsEventNotification),
                value: confirmed?.value,
                confirmedAt: confirmed?.at,
                minimumValue: characteristic.metadata?.minimumValue?.doubleValue,
                maximumValue: characteristic.metadata?.maximumValue?.doubleValue
            )
        }
        let unsupported = visible.count - characteristics.count
            - visible.filter { $0.characteristicType == HMCharacteristicTypeName }.count
        return AppleHomeService(
            id: service.uniqueIdentifier,
            kind: Self.serviceKinds[service.serviceType.uppercased()] ?? .other,
            name: service.name,
            typeDescription: service.localizedDescription,
            isPrimary: service.isPrimaryService,
            isUserInteractive: service.isUserInteractive,
            characteristics: characteristics,
            unsupportedCharacteristicCount: max(0, unsupported)
        )
    }

    private func findAccessory(_ id: UUID) -> HMAccessory? {
        guard let manager else { return nil }
        for home in manager.homes {
            if let accessory = home.accessories.first(where: { $0.uniqueIdentifier == id }) { return accessory }
        }
        return nil
    }

    /// Characteristics this provider maps, excluding HomeKit-hidden ones.
    private static func supportedCharacteristics(of accessory: HMAccessory) -> [HMCharacteristic] {
        accessory.services.flatMap(\.characteristics).filter { characteristic in
            !characteristic.properties.contains(HMCharacteristicPropertyHidden)
                && characteristicKinds[characteristic.characteristicType.uppercased()] != nil
        }
    }

    /// Value notifications for every reachable accessory, and hands the ones with something to
    /// read to `autoReader`, which reads each once (a few at a time) until it drops out.
    private func syncAutomaticReads() {
        guard isAuthorized, hasReceivedHomes, let manager else {
            autoReader.sync(readableIDs: [])
            return
        }
        var readableIDs: [UUID] = []
        for home in manager.homes {
            for accessory in home.accessories where accessory.isReachable && !accessory.isBlocked {
                enableNotifications(for: accessory)
                let hasReadable = Self.supportedCharacteristics(of: accessory).contains {
                    $0.properties.contains(HMCharacteristicPropertyReadable)
                }
                if hasReadable { readableIDs.append(accessory.uniqueIdentifier) }
            }
        }
        autoReader.sync(readableIDs: readableIDs)
    }

    private func enableNotifications(for accessory: HMAccessory) {
        for characteristic in Self.supportedCharacteristics(of: accessory)
        where characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification)
            && !notificationCharacteristicIDs.contains(characteristic.uniqueIdentifier) {
            notificationCharacteristicIDs.insert(characteristic.uniqueIdentifier)
            // Best effort: without notifications, values still update on every refresh.
            characteristic.enableNotification(true) { _ in }
        }
    }

    // MARK: - Delegate hops (HomeKit calls these on the main queue, but they're nonisolated)

    fileprivate func homesDidUpdate(from managerID: ObjectIdentifier) {
        guard let manager, ObjectIdentifier(manager) == managerID else { return }
        hasReceivedHomes = true
        syncAutomaticReads()
        publish()
    }

    fileprivate func somethingChanged() {
        guard manager != nil else { return }
        syncAutomaticReads()
        publish()
    }

    fileprivate func reachabilityChanged(accessoryID: UUID, isReachable: Bool) {
        guard manager != nil else { return }
        if isReachable {
            // Read again once it's back; values from before the outage are old.
            autoReader.markStale(accessoryID)
        }
        syncAutomaticReads()
        publish()
    }

    fileprivate func valueNotified(characteristicID: UUID, value: AppleHomeRawValue?) {
        guard manager != nil, let value else { return }
        confirmedValues[characteristicID] = (value, Date())
        publish()
    }

    // MARK: - Mapping tables

    nonisolated static func rawValue(of characteristic: HMCharacteristic) -> AppleHomeRawValue? {
        HomeKitMapping.rawValue(of: characteristic)
    }

    private static func hubState(_ state: HMHomeHubState) -> AppleHomeHubState {
        switch state {
        case .connected: return .connected
        case .disconnected: return .disconnected
        case .notAvailable: return .notAvailable
        @unknown default: return .unknown
        }
    }

    nonisolated static var serviceKinds: [String: AppleHomeServiceKind] { HomeKitMapping.serviceKinds }

    nonisolated static var characteristicKinds: [String: AppleHomeCharacteristicKind] { HomeKitMapping.characteristicKinds }

    // MARK: - Errors and timeouts

    nonisolated static func mapped(_ error: Error) -> AppleHomeProviderError {
        HomeKitMapping.providerError(error)
    }

    /// HomeKit can reject a characteristic read while its manager already reports access
    /// granted. Retry that contradictory startup result; a real denial (manager not authorized)
    /// and entitlement or privilege failures still remain terminal authorization errors.
    nonisolated static func readError(_ error: Error, managerAuthorized: Bool) -> AppleHomeProviderError {
        let nsError = error as NSError
        if managerAuthorized, nsError.domain == HMErrorDomain,
           nsError.code == HMError.Code.homeAccessNotAuthorized.rawValue {
            return .accessNotReady
        }
        return mapped(error)
    }

    /// For the diagnostic log only: "deadline" when PogoHome's own time limit ran out first,
    /// otherwise the error's domain and code.
    nonisolated static func diagnosticCode(of error: Error) -> String {
        if let error = error as? AppleHomeProviderError {
            // Only PogoHome's own deadline throws this type here; never log a message text.
            return error == .timedOut ? "deadline" : "provider"
        }
        let nsError = error as NSError
        return "\(nsError.domain):\(nsError.code)"
    }

    /// Runs a HomeKit completion-handler call, failing with `.timedOut` if it hasn't completed
    /// in `seconds`. A late completion is ignored.
    private static func withTimeout(
        _ seconds: Double,
        _ operation: (@escaping @Sendable (Error?) -> Void) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ResumeOnce(continuation)
            operation { error in gate.resume(error) }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                gate.resume(AppleHomeProviderError.timedOut)
            }
        }
    }
}

/// Resumes a continuation with the first result only.
private nonisolated final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(_ error: Error?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        if let error {
            pending?.resume(throwing: error)
        } else {
            pending?.resume()
        }
    }
}

extension HomeKitAppleHomeProvider: HMHomeManagerDelegate {
    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        let managerID = ObjectIdentifier(manager)
        Task { @MainActor in self.homesDidUpdate(from: managerID) }
    }

    nonisolated func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        Task { @MainActor in self.somethingChanged() }
    }

    nonisolated func homeManager(_ manager: HMHomeManager, didAdd home: HMHome) {
        Task { @MainActor in self.somethingChanged() }
    }

    nonisolated func homeManager(_ manager: HMHomeManager, didRemove home: HMHome) {
        Task { @MainActor in self.somethingChanged() }
    }
}

extension HomeKitAppleHomeProvider: HMHomeDelegate {
    nonisolated func homeDidUpdateName(_ home: HMHome) {
        Task { @MainActor in self.somethingChanged() }
    }

    nonisolated func home(_ home: HMHome, didAdd accessory: HMAccessory) {
        Task { @MainActor in self.somethingChanged() }
    }

    nonisolated func home(_ home: HMHome, didRemove accessory: HMAccessory) {
        Task { @MainActor in self.somethingChanged() }
    }

    nonisolated func home(_ home: HMHome, didUpdate room: HMRoom, for accessory: HMAccessory) {
        Task { @MainActor in self.somethingChanged() }
    }

    nonisolated func home(_ home: HMHome, didUpdateNameFor room: HMRoom) {
        Task { @MainActor in self.somethingChanged() }
    }

    nonisolated func home(_ home: HMHome, didAdd room: HMRoom) {
        Task { @MainActor in self.somethingChanged() }
    }

    nonisolated func home(_ home: HMHome, didRemove room: HMRoom) {
        Task { @MainActor in self.somethingChanged() }
    }

    nonisolated func home(_ home: HMHome, didUpdate homeHubState: HMHomeHubState) {
        Task { @MainActor in self.somethingChanged() }
    }

    nonisolated func home(_ home: HMHome, didUnblockAccessory accessory: HMAccessory) {
        Task { @MainActor in self.somethingChanged() }
    }
}

extension HomeKitAppleHomeProvider: HMAccessoryDelegate {
    nonisolated func accessoryDidUpdateName(_ accessory: HMAccessory) {
        Task { @MainActor in self.somethingChanged() }
    }

    nonisolated func accessoryDidUpdateServices(_ accessory: HMAccessory) {
        Task { @MainActor in self.somethingChanged() }
    }

    nonisolated func accessory(_ accessory: HMAccessory, didUpdateNameFor service: HMService) {
        Task { @MainActor in self.somethingChanged() }
    }

    nonisolated func accessoryDidUpdateReachability(_ accessory: HMAccessory) {
        let id = accessory.uniqueIdentifier
        let isReachable = accessory.isReachable
        Task { @MainActor in self.reachabilityChanged(accessoryID: id, isReachable: isReachable) }
    }

    nonisolated func accessory(_ accessory: HMAccessory, service: HMService, didUpdateValueFor characteristic: HMCharacteristic) {
        let id = characteristic.uniqueIdentifier
        let value = Self.rawValue(of: characteristic)
        Task { @MainActor in self.valueNotified(characteristicID: id, value: value) }
    }
}
#endif
