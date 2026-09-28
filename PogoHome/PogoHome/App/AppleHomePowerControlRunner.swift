import Foundation
import os
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Where the control catalog is kept. `AppleHomePowerStore` in the app; a fake in tests.
protocol AppleHomePowerStoring: Sendable {
    func load() -> AppleHomePowerStore.LoadResult
    func save(_ catalog: AppleHomePowerCatalog) throws
}

extension AppleHomePowerStore: AppleHomePowerStoring {}

/// Asks Control Center to redraw the power controls from the stored catalog.
@MainActor
protocol AppleHomePowerControlReloading: AnyObject {
    func reloadControls()
}

@MainActor
final class ControlCenterPowerReloader: AppleHomePowerControlReloading {
    func reloadControls() {
        #if canImport(WidgetKit)
        ControlCenter.shared.reloadControls(ofKind: AppleHomePowerControlKind.power)
        #endif
    }
}

/// Carries out `SetAppleHomePowerIntent` in the app process: one action at a time per target,
/// each against a fresh HomeKit connection (`AppleHomePowerPerformer`), never against the app's
/// `AppleHomeModel`. Records the outcome for the control and reloads it; throws for anything
/// but a read-back of the requested state, so Control Center doesn't keep a flipped toggle.
@MainActor
final class AppleHomePowerControlRunner {
    static let shared = AppleHomePowerControlRunner()

    private let store: AppleHomePowerStoring?
    private let reloader: AppleHomePowerControlReloading
    private let makeGateway: @MainActor () -> AppleHomePowerGateway
    private let isAppleHomeEnabled: @MainActor () -> Bool
    private let now: @MainActor () -> Date
    private let configurePerformer: @MainActor (inout AppleHomePowerPerformer) -> Void
    private var running: Set<AppleHomePowerTargetID> = []

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.junsoona.PogoHome",
        category: "AppleHomePowerControl"
    )

    init(
        store: AppleHomePowerStoring? = AppleHomePowerStore.shared(),
        reloader: AppleHomePowerControlReloading = ControlCenterPowerReloader(),
        makeGateway: @escaping @MainActor () -> AppleHomePowerGateway = AppleHomePowerControlRunner.makeDefaultGateway,
        isAppleHomeEnabled: @escaping @MainActor () -> Bool = { UserDefaults.standard.bool(forKey: AppleHomeSettingsKeys.enabled) },
        now: @escaping @MainActor () -> Date = { Date() },
        configurePerformer: @escaping @MainActor (inout AppleHomePowerPerformer) -> Void = { _ in }
    ) {
        self.store = store
        self.reloader = reloader
        self.makeGateway = makeGateway
        self.isAppleHomeEnabled = isAppleHomeEnabled
        self.now = now
        self.configurePerformer = configurePerformer
    }

    static func makeDefaultGateway() -> AppleHomePowerGateway {
        #if os(iOS)
        return HomeKitPowerControlGateway()
        #else
        return UnavailablePowerGateway()
        #endif
    }

    /// The intent's entry point. Returns only when the device reported the requested state, or
    /// when the tap was a state check (`isShownStateKnown == false`).
    func perform(target: AppleHomePowerTargetID?, requestedOn: Bool, isShownStateKnown: Bool) async throws {
        let outcome = await run(target: target, requestedOn: requestedOn, isShownStateKnown: isShownStateKnown)
        Self.logger.notice("control outcome: \(String(describing: outcome), privacy: .public)")
        if case let .failed(failure, _) = outcome { throw failure }
    }

    func run(target: AppleHomePowerTargetID?, requestedOn: Bool, isShownStateKnown: Bool) async -> AppleHomePowerOutcome {
        guard let target else { return .failed(.targetMissing, observedIsOn: nil) }
        guard !running.contains(target) else { return .failed(.busy, observedIsOn: nil) }
        running.insert(target)
        defer { running.remove(target) }

        let outcome: AppleHomePowerOutcome
        if isAppleHomeEnabled() {
            var performer = AppleHomePowerPerformer(gateway: makeGateway())
            configurePerformer(&performer)
            outcome = await performer.perform(target: target, requestedOn: requestedOn, isShownStateKnown: isShownStateKnown)
        } else {
            // The user turned Apple Home off in PogoHome: HomeKit isn't touched.
            outcome = .failed(.appleHomeOff, observedIsOn: nil)
        }
        record(outcome, for: target)
        reloader.reloadControls()
        return outcome
    }

    /// What the control shows next: the state read during the action (or "unknown" when none
    /// was read — a state from before a failed action is no longer known to be current).
    private func record(_ outcome: AppleHomePowerOutcome, for target: AppleHomePowerTargetID) {
        guard let store, let catalog = store.load().catalog else { return }
        let date = now()
        let state: AppleHomePowerState
        switch outcome {
        case let .confirmed(isOn, _):
            state = AppleHomePowerState(isOn: isOn, checkedAt: date, lastResult: .confirmed, resultAt: date)
        case let .checked(isOn):
            state = AppleHomePowerState(isOn: isOn, checkedAt: date, lastResult: .checked, resultAt: date)
        case let .failed(failure, observed):
            state = AppleHomePowerState(isOn: observed, checkedAt: date, lastResult: .failed(failure), resultAt: date)
        }
        do {
            try store.save(catalog.replacingState(state, for: target, at: date))
        } catch {
            Self.logger.error("control state write failed: \(String(describing: error), privacy: .public)")
        }
    }
}

#if !os(iOS)
@MainActor
final class UnavailablePowerGateway: AppleHomePowerGateway {
    func prepare() async throws { throw AppleHomePowerFailure.homeKitUnavailable }
    func accessory(id: UUID, inHome homeID: UUID) -> AppleHomeAccessory? { nil }
    func readPower(characteristicID: UUID, accessoryID: UUID) async throws -> Bool { throw AppleHomePowerFailure.homeKitUnavailable }
    func writePower(_ isOn: Bool, characteristicID: UUID, accessoryID: UUID) async throws { throw AppleHomePowerFailure.homeKitUnavailable }
}
#endif
