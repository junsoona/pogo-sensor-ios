import Foundation
import Observation
import os

// Apple Home lights, outlets and switches on the Watch. The Watch talks to HomeKit itself (its own
// Apple Home permission, its own connection to the home hub) — nothing goes through the iPhone.
// Every action goes through `AppleHomePowerPerformer`, the same read → write → read-back sequence
// as the iPhone's Control Center toggle, so "on"/"off" is only ever shown as a result once the
// device reported it. Compiled into the iPhone app too, so it's tested with a scripted gateway.

/// The Watch's HomeKit connection: the power-control gateway plus the list of eligible devices.
@MainActor
protocol WatchPowerGateway: AppleHomePowerGateway {
    /// Whether HomeKit lists at least one home. Valid after `prepare()`.
    var hasHome: Bool { get }
    /// Devices with exactly one on/off control on a light, outlet or switch
    /// (`AppleHomePowerEligibility`), across all homes. Valid after `prepare()`.
    func powerTargets() -> [AppleHomePowerTarget]
}

/// What the Watch knows about one device's power state.
nonisolated enum WatchPowerState: Equatable, Sendable {
    /// Never read in this session, or an action ended without a readable state.
    case unknown
    case known(isOn: Bool, checkedAt: Date)
}

/// How the last action on a device ended, in the groups the Watch tells apart.
nonisolated enum WatchPowerResult: Equatable, Sendable {
    /// The device reported the requested state after the action.
    case confirmed
    /// The state was only read; nothing was sent.
    case checked
    /// No Apple Home access: declined, restricted, or turned off.
    case noPermission(AppleHomePowerFailure)
    /// The device — or Apple Home itself — didn't answer.
    case noResponse(AppleHomePowerFailure)
    /// The state after the attempt isn't the one requested, or couldn't be read: whether the device
    /// switched is not known.
    case unconfirmed(AppleHomePowerFailure)
    /// Nothing was done for another reason (device removed or changed, busy, Watch locked).
    case unavailable(AppleHomePowerFailure)

    static func from(_ outcome: AppleHomePowerOutcome) -> WatchPowerResult {
        switch outcome {
        case .confirmed: return .confirmed
        case .checked: return .checked
        case let .failed(failure, _):
            switch failure {
            case .notAuthorized, .restricted, .appleHomeOff:
                return .noPermission(failure)
            case .notReachable, .timedOut, .homeKitUnavailable:
                return .noResponse(failure)
            case .unconfirmed, .mismatch, .writeFailed, .readFailed:
                return .unconfirmed(failure)
            case .targetMissing, .targetChanged, .deviceLocked, .busy, .requiresApp:
                return .unavailable(failure)
            }
        }
    }

    var failure: AppleHomePowerFailure? {
        switch self {
        case .confirmed, .checked: return nil
        case let .noPermission(failure), let .noResponse(failure), let .unconfirmed(failure), let .unavailable(failure): return failure
        }
    }

    var isFailure: Bool { failure != nil }
}

/// What a device row is doing right now.
nonisolated enum WatchPowerActivity: Equatable, Sendable {
    case idle
    /// Reading the state; nothing is sent.
    case checking
    /// Sent (or about to send) a request for this state; not confirmed yet.
    case switching(toOn: Bool)
}

/// The state line of a row, decided with the same age rule as every glance.
nonisolated enum WatchPowerStateDisplay: Equatable, Sendable {
    case on(checkedAt: Date)
    case off(checkedAt: Date)
    /// Read longer ago than `HomeGlanceFreshness.staleAfter`: the last state seen, not the current.
    case lastSeen(isOn: Bool, checkedAt: Date)
    case unknown
}

nonisolated struct WatchPowerRow: Identifiable, Equatable, Sendable {
    enum TapAction: Equatable, Sendable {
        /// Switch to this state (the performer re-reads the device first).
        case switchTo(on: Bool)
        /// The state isn't known: read it, send nothing.
        case check
        /// Busy with an earlier tap.
        case none
    }

    let target: AppleHomePowerTarget
    var state: WatchPowerState = .unknown
    var activity: WatchPowerActivity = .idle
    var lastResult: WatchPowerResult?
    var resultAt: Date?

    var id: AppleHomePowerTargetID { target.id }

    var tapAction: TapAction {
        guard activity == .idle else { return .none }
        switch state {
        case .unknown: return .check
        case let .known(isOn, _): return .switchTo(on: !isOn)
        }
    }

    func stateDisplay(now: Date) -> WatchPowerStateDisplay {
        guard case let .known(isOn, checkedAt) = state else { return .unknown }
        guard HomeGlanceFreshness.of(checkedAt, now: now) == .recent else { return .lastSeen(isOn: isOn, checkedAt: checkedAt) }
        return isOn ? .on(checkedAt: checkedAt) : .off(checkedAt: checkedAt)
    }

    /// The result worth showing under the row: failures until the next action, a confirmation
    /// for `AppleHomePowerControlDisplay.statusWindow` after it.
    func visibleResult(now: Date) -> WatchPowerResult? {
        guard let lastResult, let resultAt else { return nil }
        switch lastResult {
        case .checked:
            return nil
        case .confirmed:
            let age = now.timeIntervalSince(resultAt)
            return age >= -60 && age <= AppleHomePowerControlDisplay.statusWindow ? lastResult : nil
        case .noPermission, .noResponse, .unconfirmed, .unavailable:
            return lastResult
        }
    }
}

/// The Watch's Apple Home page. Stays off until the wearer turns it on on the Watch — creating the
/// HomeKit connection is what shows the permission prompt — and remembers that choice.
@MainActor
@Observable
final class WatchPowerController {
    enum Access: Equatable, Sendable {
        /// Not turned on on this Watch; HomeKit hasn't been touched.
        case off
        case loading
        case ready
        case noHome
        case denied
        case restricted
        /// HomeKit didn't list its homes in time.
        case unavailable
    }

    static let enabledKey = "pogohome.watch.appleHome.enabled"

    private(set) var access: Access
    private(set) var rows: [WatchPowerRow] = []
    private(set) var isEnabled: Bool

    @ObservationIgnored private let gateway: WatchPowerGateway
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let configurePerformer: @MainActor (inout AppleHomePowerPerformer) -> Void
    @ObservationIgnored private var isLoading = false

    private static let logger = Logger(subsystem: "com.junsoona.PogoHome", category: "WatchAppleHome")

    /// How many devices are read at once when the page opens.
    static let concurrentReads = 3

    init(
        gateway: WatchPowerGateway,
        defaults: UserDefaults = .standard,
        now: @escaping @MainActor () -> Date = { Date() },
        configurePerformer: @escaping @MainActor (inout AppleHomePowerPerformer) -> Void = { _ in }
    ) {
        self.gateway = gateway
        self.defaults = defaults
        self.now = now
        self.configurePerformer = configurePerformer
        let isEnabled = defaults.bool(forKey: Self.enabledKey)
        self.isEnabled = isEnabled
        self.access = isEnabled ? .loading : .off
    }

    /// The wearer asked to see Apple Home devices: may show HomeKit's permission prompt.
    func enable() async {
        isEnabled = true
        defaults.set(true, forKey: Self.enabledKey)
        await load()
    }

    /// Stops showing Apple Home on the Watch. Nothing changes in Apple Home.
    func disable() {
        isEnabled = false
        defaults.set(false, forKey: Self.enabledKey)
        access = .off
        rows = []
    }

    /// Lists the devices and reads each one's state. Does nothing while off.
    func load() async {
        guard isEnabled, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if rows.isEmpty { access = .loading }
        do {
            try await gateway.prepare()
        } catch {
            access = Self.access(for: error)
            rows = []
            return
        }
        guard gateway.hasHome else {
            access = .noHome
            rows = []
            return
        }
        let previous = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Names and rooms as HomeKit lists them now; what was read in this session stays.
        rows = gateway.powerTargets().map { target in
            guard let old = previous[target.id] else { return WatchPowerRow(target: target) }
            return WatchPowerRow(target: target, state: old.state, activity: old.activity, lastResult: old.lastResult, resultAt: old.resultAt)
        }
        access = .ready
        await readStates()
    }

    /// Reads every idle device's state, a few at a time.
    func readStates() async {
        let ids = rows.filter { $0.activity == .idle }.map(\.id)
        var index = 0
        while index < ids.count {
            let batch = Array(ids[index..<min(index + Self.concurrentReads, ids.count)])
            index += Self.concurrentReads
            let reads = batch.map { id in
                Task { @MainActor in await self.run(id, requestedOn: false, isShownStateKnown: false, isAutomatic: true) }
            }
            for read in reads { await read.value }
        }
    }

    /// A tap on a device's button.
    func tap(_ id: AppleHomePowerTargetID) async {
        guard let row = rows.first(where: { $0.id == id }) else { return }
        switch row.tapAction {
        case .none:
            return
        case .check:
            await run(id, requestedOn: false, isShownStateKnown: false, isAutomatic: false)
        case let .switchTo(on):
            await run(id, requestedOn: on, isShownStateKnown: true, isAutomatic: false)
        }
    }

    private func run(_ id: AppleHomePowerTargetID, requestedOn: Bool, isShownStateKnown: Bool, isAutomatic: Bool) async {
        guard let index = rows.firstIndex(where: { $0.id == id }), rows[index].activity == .idle else { return }
        rows[index].activity = isShownStateKnown ? .switching(toOn: requestedOn) : .checking

        var performer = AppleHomePowerPerformer(gateway: gateway)
        configurePerformer(&performer)
        let outcome = await performer.perform(target: id, requestedOn: requestedOn, isShownStateKnown: isShownStateKnown)
        Self.logger.notice("watch power outcome: \(String(describing: outcome), privacy: .public)")

        // The list may have been rebuilt meanwhile.
        guard let current = rows.firstIndex(where: { $0.id == id }) else { return }
        let date = now()
        var row = rows[current]
        row.activity = .idle
        switch outcome {
        case let .confirmed(isOn, _), let .checked(isOn):
            row.state = .known(isOn: isOn, checkedAt: date)
        case let .failed(_, observed):
            // A state from before a failed action is no longer known to be current.
            row.state = observed.map { .known(isOn: $0, checkedAt: date) } ?? .unknown
        }
        let result = WatchPowerResult.from(outcome)
        // An automatic read that worked says nothing new; one that failed is worth showing.
        if !isAutomatic || result.isFailure || row.lastResult?.isFailure == true {
            row.lastResult = result
            row.resultAt = date
        }
        rows[current] = row

        if case let .noPermission(failure) = result, failure != .appleHomeOff {
            // Access was revoked: nothing about the devices may stay on screen.
            access = failure == .restricted ? .restricted : .denied
            rows = []
        }
    }

    static func access(for error: Error) -> Access {
        switch error as? AppleHomePowerFailure {
        case .notAuthorized?: return .denied
        case .restricted?: return .restricted
        default: return .unavailable
        }
    }
}
