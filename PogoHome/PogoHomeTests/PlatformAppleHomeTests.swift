import UIKit
import XCTest
@testable import PogoHome

/// iPad and Mac Catalyst: Apple Home goes through HomeKit on every platform the app ships on,
/// "add accessory" says exactly why it can't run where it can't, and that never affects reading
/// or controlling devices already in Apple Home. Runs on the iPhone/iPad simulator and on
/// "My Mac (Mac Catalyst)".
@MainActor
final class PlatformAppleHomeTests: XCTestCase {
    private typealias F = AppleHomeFixtures

    func testEveryShippingPlatformUsesHomeKitRatherThanTheUnsupportedProvider() {
        // A native macOS build (or a `#if os(...)` that leaves Catalyst out) would fall back to
        // `UnsupportedAppleHomeProvider` and silently drop every Apple Home device.
        XCTAssertTrue(AppleHomeProviderFactory.makeDefault() is HomeKitAppleHomeProvider)
    }

    func testSetupSupportPolicy() {
        XCTAssertEqual(AppleHomeAccessorySetupSupport.resolve(hasSetupAPI: false, systemReportsSupported: nil), .requiresNewerMacOS)
        XCTAssertEqual(AppleHomeAccessorySetupSupport.resolve(hasSetupAPI: true, systemReportsSupported: nil), .available)
        XCTAssertEqual(AppleHomeAccessorySetupSupport.resolve(hasSetupAPI: true, systemReportsSupported: true), .available)
        XCTAssertEqual(AppleHomeAccessorySetupSupport.resolve(hasSetupAPI: true, systemReportsSupported: false), .unsupportedOnThisDevice)
    }

    func testThisPlatformReportsItsOwnSetupSupport() {
        let provider = HomeKitAppleHomeProvider()
        XCTAssertEqual(provider.isAccessorySetupAvailable, provider.accessorySetupSupport.isAvailable)
        #if targetEnvironment(macCatalyst)
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27 {
            XCTAssertEqual(provider.accessorySetupSupport, .requiresNewerMacOS)
        }
        #else
        XCTAssertNotEqual(provider.accessorySetupSupport, .requiresNewerMacOS, "iOS has had the setup flow since 15")
        #endif
    }

    func testUnavailableSetupLeavesExistingDevicesListedAndControllable() async {
        let provider = ScriptedAppleHomeProvider(snapshot: F.ready([F.light()]))
        provider.isAccessorySetupAvailable = false
        provider.snapshotAfterWrite = { _ in F.ready([F.light(power: .bool(true))]) }
        let model = AppleHomeModel(provider: provider, defaults: makeIsolatedDefaults())
        model.enable()

        XCTAssertEqual(model.accessorySetupSupport, .unsupportedOnThisDevice)
        await model.startAccessorySetup()
        guard case .failed = model.setupState else { return XCTFail("\(model.setupState)") }
        XCTAssertEqual(provider.setupCount, 0)

        XCTAssertEqual(model.snapshot.accessState, .ready)
        XCTAssertEqual(model.snapshot.accessories.map(\.id), [F.lightID])
        let outcome = await model.perform(
            DeviceCommand(device: .appleHomeAccessory(F.lightID), controlID: F.lightPowerID, kind: .power, value: .bool(true))
        )
        XCTAssertEqual(outcome, .confirmed)
    }

    func testDeniedAccessLinksToWherePermissionIsGrantedOnThisPlatform() {
        let url = PlatformSupport.appleHomePermissionSettingsURL?.absoluteString
        #if targetEnvironment(macCatalyst)
        // The iOS settings URL doesn't reach System Settings › Privacy & Security › Home.
        XCTAssertEqual(url, "x-apple.systempreferences:com.apple.preference.security?Privacy_HomeKit")
        #else
        XCTAssertEqual(url, UIApplication.openSettingsURLString)
        #endif
    }

    /// The generated Info.plist keys used to apply to `iphoneos*`/`iphonesimulator*` SDKs only,
    /// which a Mac Catalyst build (`macosx` SDK) doesn't match.
    func testThisBuildDeclaresLocalNetworkAccessAndMultipleWindows() throws {
        let localNetwork = Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription") as? String
        XCTAssertFalse((localNetwork ?? "").isEmpty)
        let ats = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any])
        XCTAssertEqual(ats["NSAllowsLocalNetworking"] as? Bool, true, "the bridge is plain HTTP on the LAN")
        let manifest = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest") as? [String: Any])
        XCTAssertEqual(manifest["UIApplicationSupportsMultipleScenes"] as? Bool, true)
    }
}
