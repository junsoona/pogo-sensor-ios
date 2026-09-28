import XCTest
@testable import PogoHome

/// The source-neutral device list and the POGO / Apple Home duplicate policy: POGO modules are
/// passed through unchanged, nothing is merged automatically, and a user link hides the Apple
/// Home copy only while the linked POGO module actually exists.
@MainActor
final class DeviceDirectoryTests: XCTestCase {
    private typealias F = AppleHomeFixtures
    private let pogo = MockSensorFixtures.previewSnapshot

    func testPOGOModulesKeepTheirIdentityNameRoomAndAreReadOnly() {
        let listing = DeviceDirectory.listing(pogo: pogo, isPogoStateVerified: true, appleHome: .off, links: [:])
        XCTAssertEqual(listing.visible.map(\.id), pogo.modules.map { .pogoModule($0.id) })
        XCTAssertEqual(listing.visible.map(\.name), pogo.modules.map(\.name))
        XCTAssertEqual(listing.visible.map(\.roomName), pogo.modules.map { pogo.room(for: $0)?.name })
        XCTAssertTrue(listing.visible.allSatisfy { $0.source == .pogoLinuxAPI && $0.controls.isEmpty && !$0.isMatter })
        XCTAssertEqual(listing.visible.first?.lastCheckedAt, pogo.modules.first?.lastSeen)
    }

    func testPOGOConnectionIsUnverifiedWhileTheBridgeStateIsUnverified() {
        let listing = DeviceDirectory.listing(pogo: pogo, isPogoStateVerified: false, appleHome: .off, links: [:])
        XCTAssertTrue(listing.visible.allSatisfy { $0.connection == .unverified })
    }

    func testAppleHomeAccessoriesAreAddedWithTheirOwnSourceAndIdentity() {
        let listing = DeviceDirectory.listing(pogo: pogo, isPogoStateVerified: true, appleHome: F.ready([F.light(), F.sensor()]), links: [:])
        let apple = listing.visible.filter { $0.source == .appleHome }
        XCTAssertEqual(apple.map(\.id), [.appleHomeAccessory(F.lightID), .appleHomeAccessory(F.sensorID)])
        XCTAssertEqual(apple.first?.roomName, "거실")
        XCTAssertEqual(apple.first?.connection, .connected)
        XCTAssertEqual(apple.first?.lastCheckedAt, F.readAt)
        XCTAssertEqual(apple.first?.controls.map(\.kind), [.power, .brightness])
        XCTAssertTrue(apple.allSatisfy(\.isMatter))
        XCTAssertNotEqual(DeviceIdentifier.pogoModule(F.lightID), .appleHomeAccessory(F.lightID))
    }

    func testNothingIsMergedAutomaticallyEvenWithAnIdenticalName() {
        let pogoModule = pogo.modules[0]
        let sameName = F.sensor(name: pogoModule.name)
        let listing = DeviceDirectory.listing(pogo: pogo, isPogoStateVerified: true, appleHome: F.ready([sameName]), links: [:])
        XCTAssertEqual(listing.visible.count, pogo.modules.count + 1)
        XCTAssertTrue(listing.hiddenDuplicates.isEmpty)
    }

    func testALinkedAppleHomeCopyIsHiddenOnlyWhileThePOGOModuleExists() {
        let pogoModule = pogo.modules[0]
        let links = [F.sensorID: pogoModule.id]

        let listing = DeviceDirectory.listing(pogo: pogo, isPogoStateVerified: true, appleHome: F.ready([F.light(), F.sensor()]), links: links)
        XCTAssertEqual(listing.hiddenDuplicates.map(\.id), [.appleHomeAccessory(F.sensorID)])
        XCTAssertEqual(listing.hiddenDuplicates.first?.duplicateOf, .pogoModule(pogoModule.id))
        XCTAssertFalse(listing.visible.contains { $0.id == .appleHomeAccessory(F.sensorID) })
        XCTAssertTrue(listing.visible.contains { $0.id == .pogoModule(pogoModule.id) }, "the POGO entry is the one shown")

        let withoutModule = HomeSnapshot(timestamp: pogo.timestamp, rooms: pogo.rooms, modules: Array(pogo.modules.dropFirst()))
        let fallback = DeviceDirectory.listing(pogo: withoutModule, isPogoStateVerified: true, appleHome: F.ready([F.sensor()]), links: links)
        XCTAssertTrue(fallback.hiddenDuplicates.isEmpty)
        XCTAssertTrue(fallback.visible.contains { $0.id == .appleHomeAccessory(F.sensorID) }, "never hidden from both lists")
    }

    func testAppleHomeStateNeverChangesPOGOData() {
        let appModel = AppModel(
            dataSource: MockSensorDataSource(),
            initialSnapshot: MockSensorFixtures.previewSnapshot,
            configurationStore: InMemoryHomeConfigurationStore()
        )
        let before = appModel.snapshot
        let provider = ScriptedAppleHomeProvider(snapshot: AppleHomeSnapshot(accessState: .denied))
        let appleHome = AppleHomeModel(provider: provider, defaults: makeIsolatedDefaults())
        appleHome.enable()
        provider.publish(AppleHomeSnapshot(accessState: .noHome))
        provider.publish(F.ready([F.sensor(name: before.modules[0].name)]))
        appleHome.link(accessoryID: F.sensorID, toPogoModule: before.modules[0].id)
        appleHome.disable()

        XCTAssertEqual(appModel.snapshot, before)
        let listing = appleHome.listing(pogo: appModel.snapshot, isPogoStateVerified: true)
        XCTAssertEqual(listing.visible.map(\.id), before.modules.map { .pogoModule($0.id) })
    }
}
