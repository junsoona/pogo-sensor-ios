#if os(iOS) || os(watchOS)
import Foundation
import HomeKit

/// A HomeKit connection of its own for one Control Center action, independent of the app's
/// `AppleHomeModel` (which may not be running: the action can launch the app in the
/// background). Creates its own `HMHomeManager`, so what it sees is HomeKit's current state,
/// not anything the app remembered.
///
/// Must run in the app process: HomeKit rejects widget extensions ("Handler does not support
/// background access").
///
/// On the Watch one gateway serves the whole Apple Home page (`reusesHomeManager`): the first
/// `prepare()` waits for HomeKit's homes, later ones only re-check access, and every read still
/// goes to the device.
@MainActor
final class HomeKitPowerControlGateway: NSObject, AppleHomePowerGateway {
    private var manager: HMHomeManager?
    private var homesContinuation: CheckedContinuation<Void, Never>?
    private var hasReceivedHomes = false

    private let homesTimeout: Duration
    private let readTimeout: Double
    private let writeTimeout: Double
    private let reusesHomeManager: Bool

    /// Short on purpose: a whole action (homes, read, write, read-back) must finish well within
    /// the time the system gives an intent — about 6 + 5 + 8 + 5 s at worst.
    init(homesTimeout: Duration = .seconds(6), readTimeout: Double = 5, writeTimeout: Double = 8, reusesHomeManager: Bool = false) {
        self.homesTimeout = homesTimeout
        self.readTimeout = readTimeout
        self.writeTimeout = writeTimeout
        self.reusesHomeManager = reusesHomeManager
    }

    // MARK: - AppleHomePowerGateway

    func prepare() async throws {
        if reusesHomeManager, let manager, hasReceivedHomes {
            try checkAccess(manager)
            return
        }
        let manager = HMHomeManager()
        manager.delegate = self
        self.manager = manager
        if !isSettled(manager) {
            let timeout = Task { [weak self, homesTimeout] in
                try? await Task.sleep(for: homesTimeout)
                self?.resumeHomesWaiter()
            }
            await withCheckedContinuation { homesContinuation = $0 }
            timeout.cancel()
        }
        try checkAccess(manager)
    }

    private func checkAccess(_ manager: HMHomeManager) throws {
        let status = manager.authorizationStatus
        if status.contains(.restricted) { throw AppleHomePowerFailure.restricted }
        guard status.contains(.determined) else { throw AppleHomePowerFailure.homeKitUnavailable }
        guard status.contains(.authorized) else { throw AppleHomePowerFailure.notAuthorized }
        guard hasReceivedHomes else { throw AppleHomePowerFailure.homeKitUnavailable }
    }

    func accessory(id: UUID, inHome homeID: UUID) -> AppleHomeAccessory? {
        guard let home = manager?.homes.first(where: { $0.uniqueIdentifier == homeID }),
              let accessory = home.accessories.first(where: { $0.uniqueIdentifier == id })
        else { return nil }
        return Self.describe(accessory, in: home)
    }

    func readPower(characteristicID: UUID, accessoryID: UUID) async throws -> Bool {
        let characteristic = try characteristic(characteristicID, accessoryID: accessoryID)
        try await run(timeout: readTimeout, otherwise: .readFailed) { done in
            characteristic.readValue { error in done(error) }
        }
        guard let value = HomeKitMapping.rawValue(of: characteristic) else {
            throw AppleHomePowerFailure.readFailed
        }
        return value.boolValue
    }

    func writePower(_ isOn: Bool, characteristicID: UUID, accessoryID: UUID) async throws {
        let characteristic = try characteristic(characteristicID, accessoryID: accessoryID)
        guard characteristic.properties.contains(HMCharacteristicPropertyWritable) else {
            throw AppleHomePowerFailure.targetChanged
        }
        try await run(timeout: writeTimeout, otherwise: .writeFailed) { done in
            characteristic.writeValue(NSNumber(value: isOn)) { error in done(error) }
        }
    }

    // MARK: - Homes

    private func isSettled(_ manager: HMHomeManager) -> Bool {
        let status = manager.authorizationStatus
        if status.contains(.restricted) { return true }
        if status.contains(.determined) && !status.contains(.authorized) { return true }
        return hasReceivedHomes
    }

    private func resumeHomesWaiter() {
        homesContinuation?.resume()
        homesContinuation = nil
    }

    fileprivate func homesDidUpdate(managerID: ObjectIdentifier) {
        guard let manager, ObjectIdentifier(manager) == managerID else { return }
        hasReceivedHomes = true
        resumeHomesWaiter()
    }

    fileprivate func authorizationDidUpdate(managerID: ObjectIdentifier) {
        guard let manager, ObjectIdentifier(manager) == managerID, isSettled(manager) else { return }
        resumeHomesWaiter()
    }

    // MARK: - Characteristics

    private func characteristic(_ id: UUID, accessoryID: UUID) throws -> HMCharacteristic {
        guard let accessory = manager?.homes.lazy.flatMap(\.accessories).first(where: { $0.uniqueIdentifier == accessoryID }) else {
            throw AppleHomePowerFailure.targetMissing
        }
        guard accessory.isReachable, !accessory.isBlocked else { throw AppleHomePowerFailure.notReachable }
        guard let characteristic = accessory.services.lazy.flatMap(\.characteristics).first(where: { $0.uniqueIdentifier == id }),
              characteristic.characteristicType.uppercased() == HMCharacteristicTypePowerState.uppercased(),
              characteristic.properties.contains(HMCharacteristicPropertyReadable)
        else { throw AppleHomePowerFailure.targetChanged }
        return characteristic
    }

    /// Runs a HomeKit completion-handler call, failing with `.timedOut` after `seconds`.
    private func run(
        timeout seconds: Double,
        otherwise: AppleHomePowerFailure,
        _ operation: (@escaping @Sendable (Error?) -> Void) -> Void
    ) async throws {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let gate = PowerControlResumeOnce(continuation)
                operation { error in gate.resume(error) }
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    gate.resume(AppleHomePowerFailure.timedOut)
                }
            }
        } catch {
            throw Self.mapped(error, otherwise: otherwise)
        }
    }

    nonisolated static func mapped(_ error: Error, otherwise: AppleHomePowerFailure) -> AppleHomePowerFailure {
        if let failure = error as? AppleHomePowerFailure { return failure }
        let nsError = error as NSError
        if nsError.domain == HMErrorDomain, nsError.code == HMError.Code.deviceLocked.rawValue {
            return .deviceLocked
        }
        switch HomeKitMapping.providerError(error) {
        case .notAuthorized: return .notAuthorized
        case .notReachable: return .notReachable
        case .timedOut: return .timedOut
        case .accessoryNotFound: return .targetMissing
        case .characteristicNotFound: return .targetChanged
        default: return otherwise
        }
    }

    // MARK: - Structure

    /// The accessory as `AppleHomeCapabilities` needs it: services, characteristic kinds and
    /// permissions, reachability, room. Values are left out — the performer reads the one it needs.
    static func describe(_ accessory: HMAccessory, in home: HMHome) -> AppleHomeAccessory {
        // HomeKit's default room (`roomForEntireHome()`) is "no room", as everywhere in PogoHome.
        let room = accessory.room.flatMap { $0.uniqueIdentifier == home.roomForEntireHome().uniqueIdentifier ? nil : $0 }
        let services = accessory.services.map { service in
            let characteristics = service.characteristics.compactMap { characteristic -> AppleHomeCharacteristic? in
                let properties = characteristic.properties
                guard !properties.contains(HMCharacteristicPropertyHidden),
                      let kind = HomeKitMapping.characteristicKinds[characteristic.characteristicType.uppercased()]
                else { return nil }
                return AppleHomeCharacteristic(
                    id: characteristic.uniqueIdentifier,
                    kind: kind,
                    isReadable: properties.contains(HMCharacteristicPropertyReadable),
                    isWritable: properties.contains(HMCharacteristicPropertyWritable),
                    supportsNotification: properties.contains(HMCharacteristicPropertySupportsEventNotification)
                )
            }
            return AppleHomeService(
                id: service.uniqueIdentifier,
                kind: HomeKitMapping.serviceKinds[service.serviceType.uppercased()] ?? .other,
                name: service.name,
                characteristics: characteristics
            )
        }
        return AppleHomeAccessory(
            id: accessory.uniqueIdentifier,
            homeID: home.uniqueIdentifier,
            name: accessory.name,
            roomID: room?.uniqueIdentifier,
            roomName: room?.name,
            isReachable: accessory.isReachable,
            isBlocked: accessory.isBlocked,
            services: services
        )
    }
}

extension HomeKitPowerControlGateway: WatchPowerGateway {
    var hasHome: Bool { !(manager?.homes.isEmpty ?? true) }

    /// Eligible devices in HomeKit's home order, then by room and name.
    func powerTargets() -> [AppleHomePowerTarget] {
        guard let manager else { return [] }
        return manager.homes.flatMap { home in
            home.accessories.compactMap { accessory -> AppleHomePowerTarget? in
                let described = Self.describe(accessory, in: home)
                guard case let .eligible(characteristicID, kind) = AppleHomePowerEligibility.evaluate(described) else { return nil }
                return AppleHomePowerTarget(
                    id: AppleHomePowerTargetID(homeID: home.uniqueIdentifier, accessoryID: accessory.uniqueIdentifier, characteristicID: characteristicID),
                    name: described.name,
                    roomName: described.roomName,
                    homeName: home.name,
                    kind: kind
                )
            }
            .sorted { ($0.roomName ?? "\u{10FFFF}", $0.name) < ($1.roomName ?? "\u{10FFFF}", $1.name) }
        }
    }
}

extension HomeKitPowerControlGateway: HMHomeManagerDelegate {
    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        let id = ObjectIdentifier(manager)
        Task { @MainActor in self.homesDidUpdate(managerID: id) }
    }

    nonisolated func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        let id = ObjectIdentifier(manager)
        Task { @MainActor in self.authorizationDidUpdate(managerID: id) }
    }
}

/// Resumes a continuation with the first result only.
private nonisolated final class PowerControlResumeOnce: @unchecked Sendable {
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
#endif
