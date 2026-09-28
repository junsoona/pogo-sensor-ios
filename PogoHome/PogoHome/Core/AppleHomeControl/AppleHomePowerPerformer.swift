import Foundation

/// A fresh connection to HomeKit for one control action. `HomeKitPowerControlGateway` is the
/// real one; tests script their own.
///
/// Every failure is thrown as an `AppleHomePowerFailure`.
@MainActor
protocol AppleHomePowerGateway: AnyObject {
    /// Waits for HomeKit's current homes and checks access.
    func prepare() async throws
    /// The accessory's structure as HomeKit lists it now (no values), or `nil` if the home or
    /// the accessory isn't there.
    func accessory(id: UUID, inHome homeID: UUID) -> AppleHomeAccessory?
    /// Reads the characteristic from the device (not HomeKit's cache).
    func readPower(characteristicID: UUID, accessoryID: UUID) async throws -> Bool
    /// Returns once HomeKit reports the write finished.
    func writePower(_ isOn: Bool, characteristicID: UUID, accessoryID: UUID) async throws
}

/// How one control action ended. Only `.confirmed` is a success.
nonisolated enum AppleHomePowerOutcome: Equatable, Sendable {
    /// The device reported `isOn` — the requested state — after the action. `didWrite` is
    /// `false` when a fresh read showed it was already in that state.
    case confirmed(isOn: Bool, didWrite: Bool)
    /// The state wasn't known when tapped: it was read, nothing was written.
    case checked(isOn: Bool)
    /// `observedIsOn` is a state read during the attempt, if any.
    case failed(AppleHomePowerFailure, observedIsOn: Bool?)

    var isConfirmed: Bool {
        if case .confirmed = self { return true }
        return false
    }
}

/// One Control Center action against HomeKit, using nothing remembered from before:
///
/// 1. HomeKit's current homes and access (`prepare`).
/// 2. The target, by home, accessory and characteristic id; it must still be eligible
///    (`AppleHomePowerEligibility`) with the same characteristic, and responding.
/// 3. A read of the device's current state. If the control showed no state, stop here.
/// 4. If the device already reports the requested state, done without writing.
/// 5. The write, then read-backs until the device reports the requested state (a few tries,
///    since devices may report a moment late). Anything else is a failure.
@MainActor
struct AppleHomePowerPerformer {
    let gateway: AppleHomePowerGateway
    var readBackAttempts = 3
    var readBackInterval: Duration = .milliseconds(500)
    var sleep: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    func perform(target: AppleHomePowerTargetID, requestedOn: Bool, isShownStateKnown: Bool) async -> AppleHomePowerOutcome {
        do {
            try await gateway.prepare()
        } catch {
            return .failed(Self.failure(error, otherwise: .homeKitUnavailable), observedIsOn: nil)
        }
        guard let accessory = gateway.accessory(id: target.accessoryID, inHome: target.homeID) else {
            return .failed(.targetMissing, observedIsOn: nil)
        }
        guard AppleHomePowerEligibility.targetID(of: accessory) == target else {
            return .failed(.targetChanged, observedIsOn: nil)
        }
        guard accessory.isOperable else {
            return .failed(.notReachable, observedIsOn: nil)
        }

        let current: Bool
        do {
            current = try await read(target)
        } catch {
            return .failed(Self.failure(error, otherwise: .readFailed), observedIsOn: nil)
        }
        guard isShownStateKnown else { return .checked(isOn: current) }
        if current == requestedOn { return .confirmed(isOn: current, didWrite: false) }

        do {
            try await gateway.writePower(requestedOn, characteristicID: target.characteristicID, accessoryID: target.accessoryID)
        } catch {
            // The device may or may not have switched; report what it says now, if anything.
            let observed = try? await read(target)
            return .failed(Self.failure(error, otherwise: .writeFailed), observedIsOn: observed)
        }

        var observed: Bool?
        var readError: Error?
        for attempt in 0..<max(1, readBackAttempts) {
            if attempt > 0 { await sleep(readBackInterval) }
            do {
                let value = try await read(target)
                observed = value
                if value == requestedOn { return .confirmed(isOn: value, didWrite: true) }
            } catch {
                readError = error
                // A device that let a read time out won't answer the next one sooner; keep the
                // whole action within the time the system gives an intent.
                if Self.failure(error, otherwise: .unconfirmed) == .timedOut { break }
            }
        }
        if let observed { return .failed(.mismatch, observedIsOn: observed) }
        let failure = readError.map { Self.failure($0, otherwise: .unconfirmed) } ?? .unconfirmed
        // A read-back that merely failed or timed out is "not confirmed"; a revoked permission or
        // a lock is reported as such.
        return .failed([.notAuthorized, .deviceLocked].contains(failure) ? failure : .unconfirmed, observedIsOn: nil)
    }

    private func read(_ target: AppleHomePowerTargetID) async throws -> Bool {
        try await gateway.readPower(characteristicID: target.characteristicID, accessoryID: target.accessoryID)
    }

    /// Keeps failures that say something specific; anything else becomes `otherwise`.
    static func failure(_ error: Error, otherwise: AppleHomePowerFailure) -> AppleHomePowerFailure {
        guard let failure = error as? AppleHomePowerFailure else { return otherwise }
        switch failure {
        case .notAuthorized, .restricted, .deviceLocked, .notReachable, .timedOut, .homeKitUnavailable,
             .targetMissing, .targetChanged:
            return failure
        default:
            return otherwise
        }
    }
}
