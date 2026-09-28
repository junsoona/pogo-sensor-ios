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

    func testKnownModulesResolveToCatalogEntries() {
        let sgp41 = ModuleCatalog.descriptor(forRawIdentifier: "744dbdfffe65d357", apiRole: "SGP41", language: .korean)
        XCTAssertEqual(sgp41.displayName, "SGP41 가스 센서")
        XCTAssertEqual(sgp41.room, ModuleCatalog.unspecifiedRoom(in: .korean))

        let pms5003 = ModuleCatalog.descriptor(forRawIdentifier: "744dbdfffe65d07a", apiRole: "PMS5003", language: .korean)
        XCTAssertEqual(pms5003.displayName, "PMS5003 미세먼지 센서")
    }

    /// Product names and roles are app-provided, so they follow the app language; the model
    /// number and the API's `depth` field name stay as-is.
    func testProductNamesAreLocalizedButKeepTechnicalIdentifiers() {
        let english = ModuleCatalog.descriptor(forRawIdentifier: "744dbdfffe65d357", apiRole: nil, language: .english)
        XCTAssertEqual(english.displayName, "SGP41 Gas Sensor")
        XCTAssertEqual(english.roleDescription, "VOC/NOx sensor · depth 1")
        XCTAssertEqual(english.room.name, "Unassigned")

        let spanish = ModuleCatalog.descriptor(forRawIdentifier: "744dbdfffe65d07a", apiRole: nil, language: .spanish)
        XCTAssertEqual(spanish.displayName, "Sensor de partículas PMS5003")
        XCTAssertEqual(spanish.room.name, "Sin asignar")
        XCTAssertEqual(spanish.room.id, ModuleCatalog.unspecifiedRoomID, "the fallback room id never depends on language")
    }

    func testUnknownModuleFallsBackToNewSensorModuleInUnspecifiedRoom() {
        let descriptor = ModuleCatalog.descriptor(forRawIdentifier: "deadbeefcafef00d", apiRole: "mystery", language: .korean)
        XCTAssertEqual(descriptor.displayName, "새 센서 모듈")
        XCTAssertEqual(descriptor.room, ModuleCatalog.unspecifiedRoom(in: .korean))
        XCTAssertEqual(descriptor.roleDescription, "mystery", "the hub's own role string is passed through untranslated")
    }

    func testCatalogLookupIsCaseInsensitive() {
        let descriptor = ModuleCatalog.descriptor(forRawIdentifier: "744DBDFFFE65D357", apiRole: nil, language: .korean)
        XCTAssertEqual(descriptor.displayName, "SGP41 가스 센서")
    }
}
