import XCTest
@testable import PogoHome

@MainActor
final class MockSensorFixturesTests: XCTestCase {
    private let modules = MockSensorFixtures.modules(referenceDate: MockSensorFixtures.previewReferenceDate)

    func testModuleUUIDsAreUnique() {
        let ids = modules.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testRoomUUIDsAreUnique() {
        let ids = MockSensorFixtures.rooms.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testEveryModuleRoomIDMatchesAKnownRoom() {
        let roomIDs = Set(MockSensorFixtures.rooms.map(\.id))
        for module in modules {
            XCTAssertTrue(roomIDs.contains(module.roomID), "\(module.name) references unknown room \(module.roomID)")
        }
    }

    func testHomeSnapshotContainsAllTenSensorKinds() {
        let snapshot = MockSensorFixtures.previewSnapshot
        let kinds = Set(snapshot.allReadings.map(\.kind))
        XCTAssertEqual(kinds, Set(SensorKind.allCases))
    }

    func testStaleStatusIsPresentInFixtures() {
        let hasStale = modules.flatMap(\.readings).contains { $0.status == .stale }
        XCTAssertTrue(hasStale, "expected at least one .stale reading fixture")
    }

    func testConditioningStatusIsPresentInFixtures() {
        let hasConditioning = modules.flatMap(\.readings).contains { $0.status == .conditioning }
        XCTAssertTrue(hasConditioning, "expected at least one .conditioning reading fixture")
    }

    func testOfflineModuleIsPresentInFixtures() {
        XCTAssertTrue(modules.contains { !$0.isOnline }, "expected at least one offline module fixture")
    }
}
