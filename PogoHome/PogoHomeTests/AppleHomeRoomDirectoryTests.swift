import XCTest
@testable import PogoHome

/// Apple Home rooms in PogoHome: grouped by HomeKit home and room id (never by name), following
/// moves and renames HomeKit reports, keeping the duplicate policy, never touching POGO rooms,
/// and showing nothing once access is gone. Also the Dashboard's separate Apple Home status.
@MainActor
final class AppleHomeRoomDirectoryTests: XCTestCase {
    private typealias F = AppleHomeFixtures

    private static let secondHomeID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    private static let secondHomeLivingRoomID = UUID(uuidString: "20000000-0000-0000-0000-0000000000A1")!
    private static let otherLivingRoomID = UUID(uuidString: "10000000-0000-0000-0000-0000000000A3")!

    private static func accessory(
        _ id: String,
        home: UUID = F.homeID,
        room: UUID?,
        roomName: String?,
        name: String,
        reachable: Bool = true
    ) -> AppleHomeAccessory {
        AppleHomeAccessory(
            id: UUID(uuidString: id)!,
            homeID: home,
            name: name,
            roomID: room,
            roomName: roomName,
            isReachable: reachable,
            services: [
                AppleHomeService(id: UUID(), kind: .temperatureSensor, name: "온도", characteristics: [
                    AppleHomeCharacteristic(id: UUID(), kind: .currentTemperature, value: .double(21), confirmedAt: F.readAt),
                ]),
            ]
        )
    }

    private static let homes = [
        AppleHomeInfo(id: F.homeID, name: "우리 집", isPrimary: true, hubState: .connected),
        AppleHomeInfo(id: secondHomeID, name: "우리 집", isPrimary: false, hubState: .connected),
    ]

    private func layout(_ snapshot: AppleHomeSnapshot, pogo: HomeSnapshot = HomeSnapshot(timestamp: .now, rooms: [], modules: []), links: [UUID: UUID] = [:]) -> AppleHomeLayout {
        AppleHomeRoomDirectory.layout(
            snapshot: snapshot,
            listing: DeviceDirectory.listing(pogo: pogo, isPogoStateVerified: true, appleHome: snapshot, links: links)
        )
    }

    private func makeModel(_ snapshot: AppleHomeSnapshot) -> (AppleHomeModel, ScriptedAppleHomeProvider) {
        let provider = ScriptedAppleHomeProvider(snapshot: snapshot)
        let model = AppleHomeModel(provider: provider, defaults: makeIsolatedDefaults())
        model.enable()
        return (model, provider)
    }

    // MARK: - Grouping

    func testHomesWithTheSameNameAndRoomsWithTheSameNameStaySeparate() {
        let a = Self.accessory("30000000-0000-0000-0000-000000000001", room: F.livingRoomID, roomName: "거실", name: "A")
        let b = Self.accessory("30000000-0000-0000-0000-000000000002", home: Self.secondHomeID, room: Self.secondHomeLivingRoomID, roomName: "거실", name: "B")
        let c = Self.accessory("30000000-0000-0000-0000-000000000003", room: Self.otherLivingRoomID, roomName: "거실", name: "C")
        let result = layout(AppleHomeSnapshot(accessState: .ready, homes: Self.homes, accessories: [a, b, c]))

        XCTAssertEqual(result.homes.map(\.id), [F.homeID, Self.secondHomeID], "same-named homes are two homes, in HomeKit's order")
        XCTAssertEqual(result.homes[0].rooms.map(\.id.roomID), [F.livingRoomID, Self.otherLivingRoomID].sorted { $0.uuidString < $1.uuidString })
        XCTAssertEqual(result.homes[0].rooms.map(\.name), ["거실", "거실"], "two rooms named 거실 in one home are not merged")
        XCTAssertEqual(result.homes[1].rooms.map(\.id), [AppleHomeRoomKey(homeID: Self.secondHomeID, roomID: Self.secondHomeLivingRoomID)])
        XCTAssertEqual(result.room(AppleHomeRoomKey(homeID: Self.secondHomeID, roomID: Self.secondHomeLivingRoomID))?.accessories.map(\.name), ["B"])
        XCTAssertNil(result.room(AppleHomeRoomKey(homeID: Self.secondHomeID, roomID: F.livingRoomID)), "a room id is only looked up inside its own home")
    }

    func testAccessoriesWithoutARoomFormTheLastGroupOfTheirHomeAndEmptyGroupsAreHidden() {
        let named = Self.accessory("30000000-0000-0000-0000-000000000001", room: F.livingRoomID, roomName: "거실", name: "A")
        let loose = Self.accessory("30000000-0000-0000-0000-000000000002", room: nil, roomName: nil, name: "B")
        let result = layout(AppleHomeSnapshot(accessState: .ready, homes: Self.homes, accessories: [loose, named]))

        XCTAssertEqual(result.homes.count, 1, "a home with no visible accessory is left out")
        XCTAssertEqual(result.homes[0].rooms.map(\.isUnassigned), [false, true])
        XCTAssertNil(result.homes[0].rooms.last?.name)
        XCTAssertEqual(result.room(AppleHomeRoomKey(homeID: F.homeID, roomID: nil))?.accessories.map(\.name), ["B"])
        XCTAssertNil(result.room(AppleHomeRoomKey(homeID: Self.secondHomeID, roomID: nil)), "no empty 'no room' group")
    }

    func testAnAccessoryOfAHomeHomeKitDoesNotListIsNotAttachedToAnotherHome() {
        let stray = Self.accessory("30000000-0000-0000-0000-000000000001", home: UUID(), room: F.livingRoomID, roomName: "거실", name: "A")
        let result = layout(AppleHomeSnapshot(accessState: .ready, homes: Self.homes, accessories: [stray]))
        XCTAssertTrue(result.homes.isEmpty)
    }

    func testPOGORoomsWithTheSameNameAreNeitherMergedNorChanged() {
        let pogo = MockSensorFixtures.previewSnapshot
        guard let pogoRoom = pogo.visibleRooms.first else { return XCTFail("fixture needs a POGO room") }
        let sameName = Self.accessory("30000000-0000-0000-0000-000000000001", room: F.livingRoomID, roomName: pogoRoom.name, name: "A")
        let before = pogo
        let result = layout(AppleHomeSnapshot(accessState: .ready, homes: Self.homes, accessories: [sameName]), pogo: pogo)

        XCTAssertEqual(result.homes.flatMap(\.rooms).map(\.id.roomID), [F.livingRoomID])
        XCTAssertNotEqual(result.homes.flatMap(\.rooms).first?.id.roomID, pogoRoom.id)
        XCTAssertEqual(result.visibleAccessories.map(\.id), [sameName.id], "POGO modules never appear in the Apple Home layout")
        XCTAssertEqual(pogo, before, "the POGO snapshot is only read")
    }

    // MARK: - Following HomeKit

    func testMovingAndRenamingARoomInAppleHomeIsReflected() {
        let (model, provider) = makeModel(F.ready([F.light(), F.sensor()]))
        let pogo = HomeSnapshot(timestamp: .now, rooms: [], modules: [])
        let living = AppleHomeRoomKey(homeID: F.homeID, roomID: F.livingRoomID)
        let bedroom = AppleHomeRoomKey(homeID: F.homeID, roomID: F.bedroomID)
        XCTAssertEqual(model.layout(pogo: pogo).room(living)?.accessories.map(\.id), [F.lightID])

        // Moved to the bedroom in the Home app.
        provider.publish(F.ready([F.light(roomID: F.bedroomID, roomName: "침실"), F.sensor()]))
        XCTAssertNil(model.layout(pogo: pogo).room(living), "the emptied room disappears")
        XCTAssertEqual(Set(model.layout(pogo: pogo).room(bedroom)?.accessories.map(\.id) ?? []), [F.lightID, F.sensorID])

        // The bedroom renamed: same room (same id), new name.
        provider.publish(F.ready([F.light(roomID: F.bedroomID, roomName: "안방"), F.sensor().renamingRoom("안방")]))
        XCTAssertEqual(model.layout(pogo: pogo).room(bedroom)?.name, "안방")
        XCTAssertEqual(model.layout(pogo: pogo).homes[0].rooms.count, 1)

        // Taken out of every room.
        provider.publish(F.ready([F.light(roomID: nil, roomName: nil), F.sensor().renamingRoom("안방")]))
        XCTAssertEqual(model.layout(pogo: pogo).room(AppleHomeRoomKey(homeID: F.homeID, roomID: nil))?.accessories.map(\.id), [F.lightID])
    }

    func testResynchronizeAsksTheProviderOnlyWhileRunning() {
        let provider = CountingResyncProvider(snapshot: F.ready([F.light()]))
        let model = AppleHomeModel(provider: provider, defaults: makeIsolatedDefaults())
        model.resynchronize()
        XCTAssertEqual(provider.resyncCount, 0, "never touches HomeKit before the user turns Apple Home on")
        model.enable()
        model.resynchronize()
        XCTAssertEqual(provider.resyncCount, 1)
        model.disable()
        model.resynchronize()
        XCTAssertEqual(provider.resyncCount, 1)
    }

    // MARK: - Duplicates

    func testAnAccessoryMarkedAsAPOGOSensorStaysHiddenFromRoomsButIsStillReachable() {
        let pogo = MockSensorFixtures.previewSnapshot
        let module = pogo.modules[0]
        let snapshot = F.ready([F.light(), F.sensor()])
        let bedroom = AppleHomeRoomKey(homeID: F.homeID, roomID: F.bedroomID)

        let linked = layout(snapshot, pogo: pogo, links: [F.sensorID: module.id])
        XCTAssertNil(linked.room(bedroom), "a room holding only a hidden duplicate is an empty group")
        XCTAssertEqual(linked.hiddenDuplicates(in: bedroom).map(\.id), [F.sensorID])
        XCTAssertFalse(linked.visibleAccessories.contains { $0.id == F.sensorID })

        let moduleGone = layout(snapshot, pogo: HomeSnapshot(timestamp: .now, rooms: [], modules: []), links: [F.sensorID: module.id])
        XCTAssertEqual(moduleGone.room(bedroom)?.accessories.map(\.id), [F.sensorID], "without the POGO module the link has no effect")
    }

    // MARK: - Access and the Dashboard status

    func testRevokingAccessRemovesEveryRoomAndDevice() {
        let (model, provider) = makeModel(F.ready([F.light(), F.sensor()]))
        let pogo = HomeSnapshot(timestamp: .now, rooms: [], modules: [])
        XCTAssertFalse(model.layout(pogo: pogo).homes.isEmpty)

        for state in [AppleHomeAccessState.denied, .loading, .restricted] {
            provider.publish(AppleHomeSnapshot(accessState: state, homes: Self.homes, accessories: [F.light(), F.sensor()]))
            XCTAssertEqual(model.layout(pogo: pogo), .empty, "\(state): nothing read earlier is shown as current")
            XCTAssertEqual(AppleHomeStatusSummary.evaluate(state: model.snapshot.accessState, layout: model.layout(pogo: pogo)), .unavailable(state))
        }
        model.disable()
        XCTAssertEqual(model.layout(pogo: pogo), .empty)
        XCTAssertEqual(AppleHomeStatusSummary.evaluate(state: model.snapshot.accessState, layout: model.layout(pogo: pogo)), .unavailable(.off))
    }

    func testDashboardAppleHomeStatusIsSeparateAndOnlyFineWhenEveryListedDeviceResponds() {
        func summary(_ snapshot: AppleHomeSnapshot) -> AppleHomeStatusSummary {
            AppleHomeStatusSummary.evaluate(state: snapshot.accessState, layout: layout(snapshot))
        }
        XCTAssertEqual(summary(F.ready([F.light(), F.sensor()])), .allResponding(total: 2))
        XCTAssertTrue(summary(F.ready([F.light(), F.sensor()])).isVerifiedFine)
        XCTAssertEqual(summary(F.ready([F.light(reachable: false), F.sensor()])), .someNotResponding(notResponding: 1, total: 2))
        XCTAssertEqual(summary(F.ready([F.light(blocked: true)])), .someNotResponding(notResponding: 1, total: 1))
        XCTAssertEqual(summary(F.ready([])), .noDevices)
        XCTAssertEqual(summary(AppleHomeSnapshot(accessState: .noHome)), .noHome)
        for state in [AppleHomeAccessState.off, .loading, .denied, .restricted, .unsupported] {
            XCTAssertFalse(summary(AppleHomeSnapshot(accessState: state)).isVerifiedFine, "\(state)")
        }
        XCTAssertFalse(summary(F.ready([F.light(reachable: false)])).isVerifiedFine)
    }

    func testPOGOHealthIgnoresAppleHomeAndAppleHomeStatusIgnoresPOGO() {
        let pogo = MockSensorFixtures.previewSnapshot
        let pogoHealth = HomeHealthEvaluator.evaluate(snapshot: pogo, connectionStatus: .connected, lastSyncAt: Date())
        // Apple Home turned off, denied, or with a device down: the POGO verdict is computed
        // from POGO data alone and does not change.
        for apple in [AppleHomeSnapshot.off, AppleHomeSnapshot(accessState: .denied), F.ready([F.light(reachable: false)])] {
            _ = layout(apple, pogo: pogo)
            XCTAssertEqual(HomeHealthEvaluator.evaluate(snapshot: pogo, connectionStatus: .connected, lastSyncAt: Date()), pogoHealth)
        }
        let offlinePogo = HomeSnapshot(timestamp: .now, rooms: [], modules: [])
        XCTAssertEqual(
            AppleHomeStatusSummary.evaluate(state: .ready, layout: layout(F.ready([F.light()]), pogo: offlinePogo)),
            .allResponding(total: 1),
            "POGO sensors are never counted as Apple Home devices"
        )
    }
}

private extension AppleHomeAccessory {
    func renamingRoom(_ name: String) -> AppleHomeAccessory {
        AppleHomeAccessory(
            id: id, homeID: homeID, name: self.name, roomID: roomID, roomName: name,
            isReachable: isReachable, isBlocked: isBlocked, isBridged: isBridged, isMatter: isMatter,
            services: services, lastReadError: lastReadError
        )
    }
}

@MainActor
private final class CountingResyncProvider: AppleHomeProvider {
    let snapshot: AppleHomeSnapshot
    private(set) var resyncCount = 0
    private var onChange: (@MainActor (AppleHomeSnapshot) -> Void)?

    init(snapshot: AppleHomeSnapshot) { self.snapshot = snapshot }

    var isAccessorySetupAvailable: Bool { false }
    func start(onChange: @escaping @MainActor (AppleHomeSnapshot) -> Void) {
        self.onChange = onChange
        onChange(snapshot)
    }
    func stop() { onChange = nil }
    func resynchronize() {
        resyncCount += 1
        onChange?(snapshot)
    }
    func refresh(accessoryID: UUID) async throws {}
    func write(_ value: AppleHomeRawValue, characteristicID: UUID, accessoryID: UUID) async throws {}
    func performAccessorySetup() async throws -> AppleHomeSetupResult { throw AppleHomeProviderError.cancelled }
}
