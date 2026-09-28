import Foundation
import Observation
import os

/// Keeps the Control Center catalog (selectable targets and their last read states) in step
/// with `AppleHomeModel` while the app runs. Reads the model, never changes it.
///
/// Writes only what Apple Home has settled on: nothing while it is loading or not started in
/// this process, so a background launch for a control action never wipes the list.
@MainActor
@Observable
final class AppleHomePowerCatalogPublisher {
    @ObservationIgnored private let appleHome: AppleHomeModel
    @ObservationIgnored private let store: AppleHomePowerStoring?
    @ObservationIgnored private let reloader: AppleHomePowerControlReloading
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var pending: Task<Void, Never>?

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.junsoona.PogoHome",
        category: "AppleHomePowerControl"
    )

    init(
        appleHome: AppleHomeModel,
        store: AppleHomePowerStoring?,
        reloader: AppleHomePowerControlReloading,
        now: @escaping @MainActor () -> Date = { Date() },
        debounce: Duration = .milliseconds(500)
    ) {
        self.appleHome = appleHome
        self.store = store
        self.reloader = reloader
        self.now = now
        self.debounce = debounce
    }

    /// Starts following the model. Idempotent.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        observe()
        publish()
    }

    /// Writes the catalog if its content changed, and reloads the controls. Exposed for tests.
    func publish() {
        let previous = store?.load().catalog
        guard let next = AppleHomePowerCatalogBuilder.build(
            isEnabled: appleHome.isEnabled,
            snapshot: appleHome.snapshot,
            confirmedPower: { [appleHome] accessory, characteristicID in
                Self.confirmedPower(in: appleHome, accessory: accessory, characteristicID: characteristicID)
            },
            previous: previous,
            now: now()
        ), !next.hasSameContent(as: previous) else { return }
        do {
            try store?.save(next)
        } catch {
            Self.logger.error("control catalog write failed: \(String(describing: error), privacy: .public)")
            return
        }
        reloader.reloadControls()
    }

    /// The app's own read of a target's power state, honouring `AppleHomeModel`'s rule that a
    /// write it couldn't confirm makes the older value unknown.
    private static func confirmedPower(
        in model: AppleHomeModel,
        accessory: AppleHomeAccessory,
        characteristicID: UUID
    ) -> AppleHomePowerCatalogBuilder.ConfirmedPower? {
        guard
            let control = AppleHomeCapabilities.controls(of: accessory).first(where: { $0.id == characteristicID }),
            case let .bool(isOn)? = model.confirmedValue(of: control, accessoryID: accessory.id),
            let at = accessory.characteristic(with: characteristicID)?.confirmedAt
        else { return nil }
        return .init(isOn: isOn, at: at)
    }

    private func observe() {
        withObservationTracking {
            _ = appleHome.snapshot
            _ = appleHome.isEnabled
            _ = appleHome.unverifiedWrites
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.modelChanged() }
        }
    }

    private func modelChanged() {
        guard isRunning, pending == nil else { return }
        pending = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard let self, !Task.isCancelled else { return }
            self.pending = nil
            // Re-arm first: `withObservationTracking` reports one change per registration.
            self.observe()
            self.publish()
        }
    }
}
