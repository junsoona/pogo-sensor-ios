import Foundation

/// The only thing that talks to HomeKit. `HomeKitAppleHomeProvider` is the real one; tests and
/// previews substitute their own.
///
/// Contract:
/// - Nothing touches HomeKit (and no permission prompt appears) before `start(onChange:)`.
/// - `start` delivers the current snapshot, then every change, on the main actor, until
///   `stop()`; after `stop()` no further `onChange` call is made.
/// - `refresh` reads the accessory's supported readable characteristics; the new values (or
///   the read error) arrive through `onChange` before it returns.
/// - `write` returns only once HomeKit reports the write finished, and throws on any failure.
@MainActor
protocol AppleHomeProvider: AnyObject {
    /// Whether the system accessory-setup flow (`HMAccessorySetupManager`) can run here.
    var isAccessorySetupAvailable: Bool { get }
    /// Why the setup flow is or isn't available, for the Add Device screen's explanation.
    var accessorySetupSupport: AppleHomeAccessorySetupSupport { get }

    func start(onChange: @escaping @MainActor (AppleHomeSnapshot) -> Void)
    func stop()
    func refresh(accessoryID: UUID) async throws
    func write(_ value: AppleHomeRawValue, characteristicID: UUID, accessoryID: UUID) async throws
    /// Presents Apple's own "Add Accessory" flow and returns what it added. Throws
    /// `AppleHomeProviderError.cancelled` if the user backed out.
    func performAccessorySetup() async throws -> AppleHomeSetupResult
    /// Publishes a fresh snapshot of what HomeKit holds now (names, rooms, reachability) without
    /// reading any device. Does nothing when not started.
    func resynchronize()
}

extension AppleHomeProvider {
    func resynchronize() {}

    var accessorySetupSupport: AppleHomeAccessorySetupSupport {
        isAccessorySetupAvailable ? .available : .unsupportedOnThisDevice
    }
}

/// For platforms/builds without HomeKit: reports `.unsupported` and refuses everything.
@MainActor
final class UnsupportedAppleHomeProvider: AppleHomeProvider {
    var isAccessorySetupAvailable: Bool { false }

    func start(onChange: @escaping @MainActor (AppleHomeSnapshot) -> Void) {
        onChange(AppleHomeSnapshot(accessState: .unsupported))
    }

    func stop() {}

    func refresh(accessoryID: UUID) async throws {
        throw AppleHomeProviderError.notAuthorized
    }

    func write(_ value: AppleHomeRawValue, characteristicID: UUID, accessoryID: UUID) async throws {
        throw AppleHomeProviderError.notAuthorized
    }

    func performAccessorySetup() async throws -> AppleHomeSetupResult {
        throw AppleHomeProviderError.setupUnavailable
    }
}

enum AppleHomeProviderFactory {
    static func makeDefault() -> AppleHomeProvider {
        #if os(iOS)
        return HomeKitAppleHomeProvider()
        #else
        return UnsupportedAppleHomeProvider()
        #endif
    }
}
