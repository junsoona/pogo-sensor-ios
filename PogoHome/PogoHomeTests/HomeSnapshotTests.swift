import XCTest
@testable import PogoHome

final class HomeSnapshotTests: XCTestCase {
    func testAllOnlineIsFalseForAnEmptyRegistryNotVacuouslyTrue() {
        // `allSatisfy` on an empty collection is vacuously `true` — this is exactly the
        // trap that let a mid-restart, zero-module registry read as "home stable".
        let snapshot = HomeSnapshot(timestamp: Date(), rooms: [], modules: [])
        XCTAssertFalse(snapshot.allOnline)
    }

    func testAllOnlineIsTrueWhenEveryModuleIsOnline() {
        let module = SensorModule(id: UUID(), name: "m", roomID: UUID(), readings: [], isOnline: true, lastSeen: Date())
        let snapshot = HomeSnapshot(timestamp: Date(), rooms: [], modules: [module])
        XCTAssertTrue(snapshot.allOnline)
    }

    func testAllOnlineIsFalseWhenAnyModuleIsOffline() {
        let online = SensorModule(id: UUID(), name: "a", roomID: UUID(), readings: [], isOnline: true, lastSeen: Date())
        let offline = SensorModule(id: UUID(), name: "b", roomID: UUID(), readings: [], isOnline: false, lastSeen: Date())
        let snapshot = HomeSnapshot(timestamp: Date(), rooms: [], modules: [online, offline])
        XCTAssertFalse(snapshot.allOnline)
    }

    func testOnlineModuleWithoutReadingsIsNotDataReady() {
        let module = SensorModule(id: UUID(), name: "m", roomID: UUID(), readings: [], isOnline: true, lastSeen: Date())
        let snapshot = HomeSnapshot(timestamp: Date(), rooms: [], modules: [module])
        XCTAssertFalse(snapshot.onlineModulesHaveReadings)
    }

    func testOfflineModuleMayBeCompleteWithoutReadings() {
        let module = SensorModule(id: UUID(), name: "m", roomID: UUID(), readings: [], isOnline: false, lastSeen: Date())
        let snapshot = HomeSnapshot(timestamp: Date(), rooms: [], modules: [module])
        XCTAssertTrue(snapshot.onlineModulesHaveReadings)
    }
}
