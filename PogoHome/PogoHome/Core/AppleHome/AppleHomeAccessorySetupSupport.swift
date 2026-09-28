import Foundation

/// Whether Apple's "Add Accessory" flow (`HMAccessorySetupManager`) can run on this device, and
/// if not, why — so the Add Device screen can say exactly what the user can do instead.
///
/// Only *adding* depends on this. Reading and controlling accessories already in Apple Home go
/// through `HMHomeManager`, which Mac Catalyst has had since macOS 11, so an unavailable setup
/// flow never hides or disables existing devices.
nonisolated enum AppleHomeAccessorySetupSupport: Hashable, Sendable {
    case available
    /// Mac Catalyst before macOS 27, where `HMAccessorySetupManager` doesn't exist.
    case requiresNewerMacOS
    /// The API exists but the system reports it can't run here (`HMAccessorySetupManager.isSupported`).
    case unsupportedOnThisDevice

    var isAvailable: Bool { self == .available }

    /// Pure, so the policy can be unit tested on any platform.
    /// - Parameters:
    ///   - hasSetupAPI: `HMAccessorySetupManager` exists on this OS version.
    ///   - systemReportsSupported: `HMAccessorySetupManager.isSupported` where the OS has it
    ///     (iOS/macOS 27+), `nil` on earlier systems — which never had a way to say no.
    static func resolve(hasSetupAPI: Bool, systemReportsSupported: Bool?) -> AppleHomeAccessorySetupSupport {
        guard hasSetupAPI else { return .requiresNewerMacOS }
        if systemReportsSupported == false { return .unsupportedOnThisDevice }
        return .available
    }
}
