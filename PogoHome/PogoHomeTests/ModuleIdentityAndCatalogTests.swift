import XCTest
@testable import PogoHome

final class ModuleIdentityAndCatalogTests: XCTestCase {
    func testValidHexIdentifiers() {
        XCTAssertTrue(ModuleIdentity.isValidRawIdentifier("744dbdfffe65d357"))
        XCTAssertTrue(ModuleIdentity.isValidRawIdentifier("ab"))
    }

    func testInvalidIdentifiersAreRejected() {
        XCTAssertFalse(ModuleIdentity.isValidRawIdentifier(""))
        XCTAssertFalse(ModuleIdentity.isValidRawIdentifier("zz"))
        XCTAssertFalse(ModuleIdentity.isValidRawIdentifier("abc")) // odd length
        XCTAssertFalse(ModuleIdentity.isValidRawIdentifier("not-hex!!"))
    }

    func testStableUUIDIsDeterministicAndCaseInsensitive() {
        let lower = ModuleIdentity.stableUUID(forRawIdentifier: "744dbdfffe65d357")
        let upper = ModuleIdentity.stableUUID(forRawIdentifier: "744DBDFFFE65D357")
        let again = ModuleIdentity.stableUUID(forRawIdentifier: "744dbdfffe65d357")
        XCTAssertEqual(lower, upper)
        XCTAssertEqual(lower, again)
    }

    func testDifferentIdentifiersProduceDifferentUUIDs() {
        let a = ModuleIdentity.stableUUID(forRawIdentifier: "744dbdfffe65d357")
        let b = ModuleIdentity.stableUUID(forRawIdentifier: "744dbdfffe65d07a")
        XCTAssertNotEqual(a, b)
    }

    func testBoardIdentifiersDoNotDetermineTheSensorType() {
        for raw in ["744dbdfffe65d357", "744dbdfffe65d07a", "deadbeefcafef00d"] {
            let climate = ModuleCatalog.descriptor(forRawIdentifier: raw, apiRole: "leaf", sensorBitmap: 6, language: .korean)
            XCTAssertEqual(climate.displayName, "온습도 센서")
            XCTAssertEqual(climate.room, ModuleCatalog.unspecifiedRoom(in: .korean))
            XCTAssertEqual(climate.roleDescription, "leaf")
        }
    }

    func testSupportedChannelProfilesUseCategoryNamesWithoutGuessingModels() {
        let names = [2: "온도 센서", 4: "습도 센서", 6: "온습도 센서", 1: "조도 센서",
                     0x18: "VOC 가스 센서", 0x60: "NOx 가스 센서", 0x78: "VOC/NOx 가스 센서", 0x380: "미세먼지 센서"]
        for (bitmap, expected) in names {
            let descriptor = ModuleCatalog.descriptor(forRawIdentifier: "0102030405060708", apiRole: nil, sensorBitmap: bitmap, language: .korean)
            XCTAssertEqual(descriptor.displayName, expected)
        }
    }

    func testCategoryNamesAreLocalized() {
        let english = ModuleCatalog.descriptor(forRawIdentifier: "744dbdfffe65d357", apiRole: nil, sensorBitmap: 6, language: .english)
        XCTAssertEqual(english.displayName, "Temperature & Humidity")
        XCTAssertEqual(english.room.name, "Unassigned")
        let spanish = ModuleCatalog.descriptor(forRawIdentifier: "744dbdfffe65d07a", apiRole: nil, sensorBitmap: 0x380, language: .spanish)
        XCTAssertEqual(spanish.displayName, "Sensor de partículas")
        XCTAssertEqual(spanish.room.id, ModuleCatalog.unspecifiedRoomID)
    }

    func testUnknownCapabilitiesUseGenericNameAndPreserveRole() {
        for bitmap in [nil, 0, -1, 0xffff, 0x10006, 0x387] as [Int?] {
            let descriptor = ModuleCatalog.descriptor(forRawIdentifier: "744dbdfffe65d357", apiRole: "mystery", sensorBitmap: bitmap, language: .korean)
            XCTAssertEqual(descriptor.displayName, "센서 모듈")
            XCTAssertEqual(descriptor.roleDescription, "mystery")
        }
    }

    func testMissingBitmapFallsBackToEveryRawReadingKind() {
        let gas = ModuleCatalog.descriptor(forRawIdentifier: "0102030405060708", apiRole: nil, readingKinds: ["voc_raw", "voc_index", "nox_raw", "nox_index"], language: .korean)
        XCTAssertEqual(gas.displayName, "VOC/NOx 가스 센서")
        let mixed = ModuleCatalog.descriptor(forRawIdentifier: "744dbdfffe65d357", apiRole: nil, readingKinds: ["temperature", "humidity", "future_kind"], language: .korean)
        XCTAssertEqual(mixed.displayName, "센서 모듈", "unrecognized kinds must not be silently discarded for naming")
    }

    func testPresentBitmapWinsOverMissingOrStaleReadings() {
        let descriptor = ModuleCatalog.descriptor(forRawIdentifier: "744dbdfffe65d357", apiRole: nil, sensorBitmap: 6,
                                                 readingKinds: ["voc_raw", "voc_index"], language: .korean)
        XCTAssertEqual(descriptor.displayName, "온습도 센서")
        let unknown = ModuleCatalog.descriptor(forRawIdentifier: "744dbdfffe65d357", apiRole: nil, sensorBitmap: 0x8006,
                                              readingKinds: ["temperature", "humidity"], language: .korean)
        XCTAssertEqual(unknown.displayName, "센서 모듈")
    }
}
