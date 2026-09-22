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
        let sgp41 = ModuleCatalog.descriptor(forRawIdentifier: "744dbdfffe65d357", apiRole: "SGP41")
        XCTAssertEqual(sgp41.displayName, "SGP41 가스 센서")
        XCTAssertEqual(sgp41.room, ModuleCatalog.unspecifiedRoom)

        let pms5003 = ModuleCatalog.descriptor(forRawIdentifier: "744dbdfffe65d07a", apiRole: "PMS5003")
        XCTAssertEqual(pms5003.displayName, "PMS5003 미세먼지 센서")
    }

    func testUnknownModuleFallsBackToNewSensorModuleInUnspecifiedRoom() {
        let descriptor = ModuleCatalog.descriptor(forRawIdentifier: "deadbeefcafef00d", apiRole: "mystery")
        XCTAssertEqual(descriptor.displayName, "새 센서 모듈")
        XCTAssertEqual(descriptor.room, ModuleCatalog.unspecifiedRoom)
        XCTAssertEqual(descriptor.roleDescription, "mystery")
    }

    func testCatalogLookupIsCaseInsensitive() {
        let descriptor = ModuleCatalog.descriptor(forRawIdentifier: "744DBDFFFE65D357", apiRole: nil)
        XCTAssertEqual(descriptor.displayName, "SGP41 가스 센서")
    }
}
