import XCTest
import HomeKit
@testable import PogoHome

/// The HomeKit side that can be checked without a real home: the usage description ships
/// (HomeKit crashes the app on first use without it), HomeKit's type constants map to what
/// PogoHome understands, and HomeKit errors map to the right user-facing outcome.
@MainActor
final class HomeKitIntegrationConfigurationTests: XCTestCase {
    func testHomeKitUsageDescriptionShipsInEveryLanguage() throws {
        let description = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSHomeKitUsageDescription") as? String)
        XCTAssertFalse(description.isEmpty)
        for language in ["en", "es"] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: "InfoPlist", withExtension: "strings", subdirectory: nil, localization: language), language)
            let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], language)
            XCTAssertFalse((table["NSHomeKitUsageDescription"] ?? "").isEmpty, language)
        }
    }

    func testCharacteristicAndServiceTypesMapToWhatPogoHomeUnderstands() {
        let characteristics = HomeKitAppleHomeProvider.characteristicKinds
        XCTAssertEqual(characteristics[HMCharacteristicTypePowerState.uppercased()], .powerState)
        XCTAssertEqual(characteristics[HMCharacteristicTypeActive.uppercased()], .active)
        XCTAssertEqual(characteristics[HMCharacteristicTypeBrightness.uppercased()], .brightness)
        XCTAssertEqual(characteristics[HMCharacteristicTypeCurrentTemperature.uppercased()], .currentTemperature)
        XCTAssertEqual(characteristics[HMCharacteristicTypePM2_5Density.uppercased()], .pm2_5Density)
        XCTAssertNil(characteristics[HMCharacteristicTypeTargetLockMechanismState.uppercased()], "lock control is never mapped")
        XCTAssertNil(characteristics[HMCharacteristicTypeTargetTemperature.uppercased()], "thermostat control is never mapped")

        let services = HomeKitAppleHomeProvider.serviceKinds
        XCTAssertEqual(services[HMServiceTypeLightbulb.uppercased()], .lightbulb)
        XCTAssertEqual(services[HMServiceTypeOutlet.uppercased()], .outlet)
        XCTAssertEqual(services[HMServiceTypeAccessoryInformation.uppercased()], .accessoryInformation)
        XCTAssertEqual(services["000000B7-0000-1000-8000-0026BB765291"], .fan)
        XCTAssertNil(services[HMServiceTypeThermostat.uppercased()])
    }

    func testHomeKitErrorsMapToCancelledDeniedTimedOutAndUnreachable() {
        func mapped(_ code: HMError.Code) -> AppleHomeProviderError {
            HomeKitAppleHomeProvider.mapped(NSError(domain: HMErrorDomain, code: code.rawValue))
        }
        XCTAssertEqual(mapped(.operationCancelled), .cancelled)
        XCTAssertEqual(mapped(.homeAccessNotAuthorized), .notAuthorized)
        XCTAssertEqual(mapped(.operationTimedOut), .timedOut)
        XCTAssertEqual(mapped(.accessoryNotReachable), .notReachable)
        XCTAssertEqual(mapped(.communicationFailure), .notReachable)
        guard case .underlying = mapped(.invalidParameter) else { return XCTFail("other errors keep HomeKit's own message") }
        XCTAssertEqual(HomeKitAppleHomeProvider.mapped(AppleHomeProviderError.timedOut), .timedOut)
    }

    func testAReadRejectedWhileTheManagerIsAuthorizedCanRetryWithoutClaimingPermissionWasRevoked() {
        let denied = NSError(domain: HMErrorDomain, code: HMError.Code.homeAccessNotAuthorized.rawValue)
        XCTAssertEqual(HomeKitAppleHomeProvider.readError(denied, managerAuthorized: true), .accessNotReady)
        XCTAssertEqual(HomeKitAppleHomeProvider.readError(denied, managerAuthorized: false), .notAuthorized)
        XCTAssertTrue(AppleHomeAutoReader.isTransient(.accessNotReady))
        XCTAssertFalse(AppleHomeAutoReader.isTransient(.notAuthorized))

        for code in [HMError.Code.insufficientPrivileges, .missingEntitlement] {
            let permanent = NSError(domain: HMErrorDomain, code: code.rawValue)
            XCTAssertEqual(HomeKitAppleHomeProvider.readError(permanent, managerAuthorized: true), .notAuthorized)
        }
        XCTAssertNotEqual(
            AppleHomeModel.readMessage(for: AppleHomeProviderError.accessNotReady),
            AppleHomeModel.readMessage(for: AppleHomeProviderError.notAuthorized)
        )
    }

    func testTheProviderTouchesNothingBeforeStart() {
        // Creating the provider must not create HMHomeManager (which would prompt for access).
        let provider = HomeKitAppleHomeProvider()
        let model = AppleHomeModel(provider: provider, defaults: makeIsolatedDefaults())
        model.startIfEnabled()
        XCTAssertEqual(model.snapshot.accessState, .off)
    }
}
