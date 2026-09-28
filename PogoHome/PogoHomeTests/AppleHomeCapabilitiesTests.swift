import XCTest
@testable import PogoHome

/// Only what HomeKit exposes is shown, only supported writable characteristics become controls,
/// and nothing is displayed as a value before it has been read.
final class AppleHomeCapabilitiesTests: XCTestCase {
    private typealias F = AppleHomeFixtures

    func testALightOffersPowerAndBrightnessOnlyBecauseBothAreWritable() {
        let controls = AppleHomeCapabilities.controls(of: F.light(power: .bool(true), brightness: .int(55)))
        XCTAssertEqual(controls.map(\.kind), [.power, .brightness])
        XCTAssertEqual(controls.map(\.id), [F.lightPowerID, F.lightBrightnessID])
        XCTAssertEqual(controls[0].confirmedValue, .bool(true))
        XCTAssertEqual(controls[1].confirmedValue, .percent(55))
        XCTAssertEqual(controls[1].range, 0...100)
        XCTAssertEqual(controls[0].label, "천장등")
        XCTAssertTrue(AppleHomeCapabilities.values(of: F.light()).isEmpty, "controlled characteristics aren't listed twice")
    }

    func testReadOnlyPowerIsAValueNotAControl() {
        let accessory = F.readOnlyLight()
        XCTAssertTrue(AppleHomeCapabilities.controls(of: accessory).isEmpty)
        XCTAssertEqual(AppleHomeCapabilities.values(of: accessory).map(\.id), [F.readOnlyPowerID.uuidString])
    }

    func testLocksSensorsAndUnknownServicesAreNeverControlled() {
        XCTAssertTrue(AppleHomeCapabilities.controls(of: F.lock()).isEmpty)
        XCTAssertTrue(AppleHomeCapabilities.controls(of: F.sensor()).isEmpty)
        // A writable PowerState on a service type PogoHome doesn't know (e.g. a thermostat's).
        let service = AppleHomeService(id: UUID(), kind: .other, name: "?", characteristics: [
            AppleHomeCharacteristic(id: UUID(), kind: .powerState, isWritable: true, value: .bool(true)),
        ])
        XCTAssertNil(AppleHomeCapabilities.controlKind(for: service.characteristics[0], in: service))
        // Writable but not readable: the result could never be confirmed.
        let blind = AppleHomeService(id: UUID(), kind: .switch, name: "스위치", characteristics: [
            AppleHomeCharacteristic(id: UUID(), kind: .powerState, isReadable: false, isWritable: true),
        ])
        XCTAssertNil(AppleHomeCapabilities.controlKind(for: blind.characteristics[0], in: blind))
    }

    func testControlsOfUnreachableOrBlockedAccessoriesAreDisabled() {
        XCTAssertTrue(AppleHomeCapabilities.controls(of: F.light()).allSatisfy(\.isEnabled))
        XCTAssertTrue(AppleHomeCapabilities.controls(of: F.light(reachable: false)).allSatisfy { !$0.isEnabled })
        XCTAssertTrue(AppleHomeCapabilities.controls(of: F.light(blocked: true)).allSatisfy { !$0.isEnabled })
    }

    func testValuesHaveNoTextUntilRead() {
        let unread = AppleHomeCapabilities.values(of: F.sensor(temperature: nil))
        XCTAssertEqual(unread.count, 1)
        XCTAssertNil(unread[0].displayValue)
        XCTAssertNil(F.sensor(temperature: nil).lastCheckedAt)

        let read = AppleHomeCapabilities.values(of: F.sensor(temperature: 23.4))
        XCTAssertNotNil(read[0].displayValue)
        XCTAssertEqual(F.sensor().lastCheckedAt, F.readAt)

        let unreadControl = AppleHomeCapabilities.controls(of: F.light(power: nil, brightness: nil))
        XCTAssertEqual(unreadControl.map(\.confirmedValue), [nil, nil])
    }

    func testValuesAreFormattedLikePOGOReadings() {
        let temperature = AppleHomeCharacteristic(id: UUID(), kind: .currentTemperature, value: .double(23.4))
        XCTAssertEqual(
            AppleHomeCapabilities.presentation(of: temperature, locale: Locale(identifier: "es_ES")).displayValue,
            SensorKind.temperature.formattedValue(23.4, locale: Locale(identifier: "es_ES"))
        )
        let pm = AppleHomeCharacteristic(id: UUID(), kind: .pm2_5Density, value: .double(7))
        XCTAssertEqual(AppleHomeCapabilities.presentation(of: pm, locale: Locale(identifier: "ko_KR")).displayValue, "7.0 µg/m³")
    }

    func testAlarmsAreFlagged() {
        XCTAssertTrue(AppleHomeCapabilities.needsAttention(.leakDetected, .int(1)))
        XCTAssertFalse(AppleHomeCapabilities.needsAttention(.leakDetected, .int(0)))
        XCTAssertTrue(AppleHomeCapabilities.needsAttention(.statusLowBattery, .int(1)))
        XCTAssertTrue(AppleHomeCapabilities.needsAttention(.airQuality, .int(5)))
        XCTAssertFalse(AppleHomeCapabilities.needsAttention(.airQuality, .int(2)))
        XCTAssertTrue(AppleHomeCapabilities.needsAttention(.currentLockMechanismState, .int(2)))
    }

    /// A device with some shown values isn't "unsupported"; only its other, user-named features
    /// are pointed to the Home app, and never by a technical type name.
    func testPartlySupportedDevicesNameOnlyTheirOtherFeatures() {
        XCTAssertEqual(AppleHomeCapabilities.featureSupport(of: F.sensor()), .supported(otherFeatureNames: []), "an unnamed service's type (“Identify”) isn't shown")
        XCTAssertEqual(AppleHomeCapabilities.featureSupport(of: F.light()), .supported(otherFeatureNames: []), "Accessory Information is metadata, not a feature")

        let television = AppleHomeService(id: UUID(), kind: .other, name: "거실 TV", typeDescription: "Television", characteristics: [])
        let identify = AppleHomeService(id: UUID(), kind: .other, name: "Identify", typeDescription: "Identify", isUserInteractive: false, characteristics: [])
        let light = F.light()
        let withOthers = AppleHomeAccessory(
            id: light.id, homeID: light.homeID, name: light.name, isReachable: true,
            services: light.services + [television, identify, television]
        )
        XCTAssertEqual(
            AppleHomeCapabilities.featureSupport(of: withOthers),
            .supported(otherFeatureNames: ["거실 TV"]),
            "named once; services HomeKit marks as not user-interactive are left out"
        )
    }

    func testADeviceWithNothingShownIsLeftToTheHomeAppAsAWhole() {
        let thermostat = AppleHomeAccessory(
            id: UUID(), homeID: F.homeID, name: "보일러", isReachable: true,
            services: [
                AppleHomeService(id: UUID(), kind: .accessoryInformation, name: "Info", characteristics: []),
                AppleHomeService(id: UUID(), kind: .other, name: "보일러", typeDescription: "Thermostat", characteristics: [], unsupportedCharacteristicCount: 4),
            ]
        )
        XCTAssertEqual(AppleHomeCapabilities.featureSupport(of: thermostat), .appleHomeOnly)
        XCTAssertTrue(AppleHomeCapabilities.values(of: thermostat).isEmpty)
        XCTAssertTrue(AppleHomeCapabilities.controls(of: thermostat).isEmpty)

        // One readable value is enough for the device not to be called unsupported.
        XCTAssertNotEqual(AppleHomeCapabilities.featureSupport(of: F.lock()), .appleHomeOnly)
        XCTAssertNotEqual(AppleHomeCapabilities.featureSupport(of: F.readOnlyLight()), .appleHomeOnly)
    }

    func testSnapshotsWithoutAccessNeverKeepHomesOrAccessories() {
        let denied = AppleHomeSnapshot(
            accessState: .denied,
            homes: [AppleHomeInfo(id: F.homeID, name: "집", isPrimary: true, hubState: .connected)],
            accessories: [F.light()]
        )
        XCTAssertTrue(denied.homes.isEmpty)
        XCTAssertTrue(denied.accessories.isEmpty)
    }
}
