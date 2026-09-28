import XCTest
@testable import PogoHome

/// Converting the app's POGO and Apple Home state into the widget glance: what each value keeps,
/// that the two sources never merge, and that only conclusive states replace stored data.
final class HomeGlanceBuilderTests: XCTestCase {
    private typealias F = GlanceFixtures

    // MARK: - Conversion

    func testPogoReadingsBecomeOneValueEachWithModuleRoomAndConfirmationTime() throws {
        let glance = F.build(pogo: F.pogoInput(F.home([F.climate(), F.air()])))

        XCTAssertEqual(glance.pogo.state, .healthy)
        XCTAssertEqual(glance.pogo.verifiedAt, F.t0)
        XCTAssertEqual(glance.pogo.moduleCount, 2)
        XCTAssertEqual(glance.pogo.onlineCount, 2)
        XCTAssertEqual(glance.pogoSensors.count, 3)

        let temperature = try XCTUnwrap(glance.sensor(with: F.temperatureID))
        XCTAssertEqual(temperature.deviceName, "거실 센서")
        XCTAssertEqual(temperature.roomName, "거실")
        XCTAssertEqual(temperature.pogoKind, .temperature)
        XCTAssertEqual(temperature.value, 23.4)
        XCTAssertEqual(temperature.status, .normal)
        XCTAssertTrue(temperature.isDeviceConnected)
        XCTAssertEqual(temperature.checkedAt, F.t0)
    }

    func testStatusesAndAttentionItemsFollowTheModules() {
        let glance = F.build(pogo: F.pogoInput(F.home([F.climate(status: .stale), F.air(online: false)]), health: .attentionNeeded))

        XCTAssertEqual(glance.pogo.state, .attentionNeeded)
        XCTAssertEqual(glance.pogo.onlineCount, 1)
        XCTAssertEqual(Set(glance.pogo.attention.map(\.reason)), [.stale, .offline])
        XCTAssertEqual(glance.sensor(with: F.temperatureID)?.status, .stale)
        XCTAssertEqual(glance.sensor(with: .pogo(module: F.airID, kind: .pm2_5))?.isDeviceConnected, false)
        // An offline module's value was never confirmed while it was online here.
        XCTAssertNil(glance.sensor(with: .pogo(module: F.airID, kind: .pm2_5))?.checkedAt)
    }

    func testAppleHomeListsReadableValuesButNotControls() throws {
        let glance = F.build(pogo: F.pogoInput(F.home([F.climate()])))

        XCTAssertEqual(glance.appleHome.access, .ready)
        XCTAssertEqual(glance.appleHome.accessoryCount, 2)
        let appleHomeKinds = glance.appleHomeSensors.compactMap(\.appleHomeKind)
        XCTAssertEqual(appleHomeKinds, [.currentTemperature], "power/brightness are controls, not values")

        let temperature = try XCTUnwrap(glance.sensor(with: F.appleHomeTemperatureID))
        XCTAssertEqual(temperature.value, 23.4)
        XCTAssertEqual(temperature.checkedAt, AppleHomeFixtures.readAt)
        XCTAssertEqual(temperature.roomName, "침실")
    }

    func testAnAppleHomeValueNotReadYetHasNoValue() {
        let glance = F.build(pogo: F.pogoInput(F.home([])), appleHome: F.appleHomeInput([AppleHomeFixtures.sensor(temperature: nil)]))
        XCTAssertNil(glance.sensor(with: F.appleHomeTemperatureID)?.value)
        XCTAssertEqual(glance.condition(of: glance.sensor(with: F.appleHomeTemperatureID)!, at: F.t0), .notYetRead)
    }

    // MARK: - Source separation

    func testSameNameAndSameUUIDOnBothSourcesStayTwoSeparateValues() throws {
        let accessory = F.sameNameAccessory()
        let glance = F.build(pogo: F.pogoInput(F.home([F.climate()])), appleHome: F.appleHomeInput([accessory]))

        let pogo = try XCTUnwrap(glance.sensor(with: F.temperatureID))
        let appleHome = try XCTUnwrap(glance.sensor(with: .appleHome(accessory: F.climateID, characteristic: F.sameNameTemperatureID)))
        XCTAssertEqual(pogo.deviceName, appleHome.deviceName, "same name on purpose")
        XCTAssertEqual(pogo.id.device.rawValue, appleHome.id.device.rawValue, "same UUID value on purpose")
        XCTAssertNotEqual(pogo.id, appleHome.id)
        XCTAssertEqual(pogo.source, .pogoLinuxAPI)
        XCTAssertEqual(appleHome.source, .appleHome)
        XCTAssertEqual(pogo.value, 23.4)
        XCTAssertEqual(appleHome.value, 22.0)
        XCTAssertEqual(Set(glance.sensors.map(\.id)).count, glance.sensors.count, "no id collides")
        XCTAssertNotEqual(pogo.id.stringValue, appleHome.id.stringValue)
    }

    func testAppleHomeEntriesTheUserMarkedAsAPogoModuleAreLeftOutLikeOnTheDashboard() {
        let accessory = F.sameNameAccessory()
        let pogo = F.home([F.climate()])
        let listing = DeviceDirectory.listing(
            pogo: pogo,
            isPogoStateVerified: true,
            appleHome: AppleHomeFixtures.ready([accessory]),
            links: [accessory.id: F.climateID]
        )
        let layout = AppleHomeRoomDirectory.layout(snapshot: AppleHomeFixtures.ready([accessory]), listing: listing)
        let glance = F.build(pogo: F.pogoInput(pogo), appleHome: F.appleHomeInput(layout.visibleAccessories))

        XCTAssertTrue(glance.appleHomeSensors.isEmpty)
        XCTAssertEqual(glance.appleHome.accessoryCount, 0)
        XCTAssertNotNil(glance.sensor(with: F.temperatureID), "the POGO module stays")
    }

    // MARK: - Conclusive states only

    func testLaunchingOrReconnectingBeforeAnyDataKeepsTheStoredPogoState() {
        let stored = F.build(pogo: F.pogoInput(F.home([F.climate()])))
        let later = F.t0.addingTimeInterval(600)

        for status in [DataSourceConnectionStatus.idle, .connecting, .connected] {
            let glance = F.build(
                pogo: F.pogoInput(F.home([]), health: .reconnecting, connection: status, lastSyncAt: F.t0, sessionStartedAt: later),
                previous: stored,
                now: later
            )
            XCTAssertEqual(glance.pogo, stored.pogo, "\(status)")
            XCTAssertEqual(glance.pogoSensors, stored.pogoSensors, "\(status)")
        }
    }

    func testAFailedConnectionInThisSessionKeepsValuesButMarksThemUnverified() {
        let stored = F.build(pogo: F.pogoInput(F.home([F.climate()])))
        let later = F.t0.addingTimeInterval(600)

        let glance = F.build(
            pogo: F.pogoInput(F.home([]), health: .reconnecting, connection: .reconnecting(attempt: 2), lastSyncAt: F.t0, sessionStartedAt: later),
            previous: stored,
            now: later
        )
        XCTAssertEqual(glance.pogo.state, .unverified)
        XCTAssertEqual(glance.pogo.verifiedAt, F.t0, "the last confirmation time is kept, not advanced")
        XCTAssertEqual(glance.pogoSensors, stored.pogoSensors)
        XCTAssertEqual(glance.condition(of: glance.sensor(with: F.temperatureID)!, at: later), .sourceUnverified)
    }

    func testLosingTheConnectionMidSessionKeepsConfirmationTimesAtTheirLastConfirmedMoment() {
        let stored = F.build(pogo: F.pogoInput(F.home([F.climate()])))
        let later = F.t0.addingTimeInterval(120)

        let glance = F.build(
            pogo: F.pogoInput(F.home([F.climate(temperature: 24.0)]), health: .reconnecting, connection: .reconnecting(attempt: 1), lastSyncAt: later),
            previous: stored,
            now: later
        )
        XCTAssertEqual(glance.pogo.state, .unverified)
        XCTAssertEqual(glance.pogo.verifiedAt, F.t0)
        XCTAssertEqual(glance.sensor(with: F.temperatureID)?.checkedAt, F.t0)
    }

    func testAnIncompleteRegistryNeverMakesStoredValuesLookDeleted() {
        let stored = F.build(pogo: F.pogoInput(F.home([F.climate(), F.air()])))
        let later = F.t0.addingTimeInterval(60)

        // Bridge restarted: topology back, samples not yet — or nothing at all yet.
        for incomplete in [F.home([F.air(readings: false)]), F.home([])] {
            let glance = F.build(
                pogo: F.pogoInput(incomplete, health: .waitingForData, lastSyncAt: later),
                previous: stored,
                now: later
            )
            XCTAssertEqual(glance.pogoSensors, stored.pogoSensors)
            XCTAssertEqual(glance.pogo.state, .unverified)
            XCTAssertNotEqual(glance.sensorLookup(F.temperatureID, at: later), .missing)
        }
    }

    func testAnOfflineModuleKeepsTheTimeItWasLastConfirmedOnline() {
        let stored = F.build(pogo: F.pogoInput(F.home([F.climate()])))
        let later = F.t0.addingTimeInterval(300)

        let glance = F.build(
            pogo: F.pogoInput(F.home([F.climate(online: false)]), health: .attentionNeeded, lastSyncAt: later),
            previous: stored,
            now: later
        )
        let temperature = glance.sensor(with: F.temperatureID)
        XCTAssertEqual(temperature?.checkedAt, F.t0)
        XCTAssertEqual(temperature?.isDeviceConnected, false)
        XCTAssertEqual(glance.pogo.verifiedAt, later, "the connection itself was confirmed")
        XCTAssertEqual(glance.condition(of: temperature!, at: later), .deviceDisconnected)
    }

    // MARK: - Deleted items

    func testAModuleRemovedFromACompleteSnapshotDisappearsAndItsSelectionIsReportedMissing() {
        let stored = F.build(pogo: F.pogoInput(F.home([F.climate(), F.air()])))
        let later = F.t0.addingTimeInterval(60)

        let glance = F.build(pogo: F.pogoInput(F.home([F.air()]), lastSyncAt: later), previous: stored, now: later)
        XCTAssertNil(glance.sensor(with: F.temperatureID))
        XCTAssertEqual(glance.sensorLookup(F.temperatureID, at: later), .missing)
        XCTAssertEqual(glance.pogo.moduleCount, 1)
    }

    func testAnAccessoryRemovedFromAppleHomeDisappears() {
        let stored = F.build(pogo: F.pogoInput(F.home([])))
        let glance = F.build(pogo: F.pogoInput(F.home([])), appleHome: F.appleHomeInput([AppleHomeFixtures.light()]), previous: stored)
        XCTAssertEqual(glance.sensorLookup(F.appleHomeTemperatureID, at: F.t0), .missing)
    }

    // MARK: - Apple Home access

    func testDeniedRestrictedNoHomeOrTurnedOffClearAppleHomeButKeepPogo() {
        let stored = F.build(pogo: F.pogoInput(F.home([F.climate()])))
        XCTAssertFalse(stored.appleHomeSensors.isEmpty)
        let cases: [(HomeGlanceBuilder.AppleHomeInput, HomeGlanceAppleHomeAccess)] = [
            (F.appleHomeInput(state: .denied), .denied),
            (F.appleHomeInput(state: .restricted), .restricted),
            (F.appleHomeInput(state: .noHome), .noHome),
            (F.appleHomeInput(state: .unsupported), .unsupported),
            (F.appleHomeInput(isEnabled: false), .off),
        ]
        for (input, access) in cases {
            let glance = F.build(pogo: F.pogoInput(F.home([F.climate()])), appleHome: input, previous: stored)
            XCTAssertEqual(glance.appleHome.access, access)
            XCTAssertNil(glance.appleHome.verifiedAt)
            XCTAssertEqual(glance.appleHome.accessoryCount, 0)
            XCTAssertTrue(glance.appleHomeSensors.isEmpty, "\(access): stored Apple Home values must go")
            XCTAssertEqual(glance.pogo, stored.pogo, "\(access): POGO untouched")
            XCTAssertEqual(glance.pogoSensors, stored.pogoSensors, "\(access): POGO untouched")
            XCTAssertEqual(glance.sensorLookup(F.appleHomeTemperatureID, at: F.t0), .sourceUnavailable(access))
        }
    }

    func testWaitingForHomeKitKeepsWhatWasThereWithoutAdvancingIt() {
        let stored = F.build(pogo: F.pogoInput(F.home([])))
        let later = F.t0.addingTimeInterval(30)
        for state in [AppleHomeAccessState.loading, .off] {
            let glance = F.build(pogo: F.pogoInput(F.home([])), appleHome: F.appleHomeInput(state: state), previous: stored, now: later)
            XCTAssertEqual(glance.appleHome, stored.appleHome, "\(state)")
            XCTAssertEqual(glance.appleHomeSensors, stored.appleHomeSensors, "\(state)")
        }
    }

    // MARK: - Source switches

    /// Mock → Live (hub off), and Live → another hub: nothing of the previous source is carried
    /// into the glance — not even as "unverified" — while the same hub reconnecting keeps its values.
    func testAPreviousGlanceFromAnotherSourceIsNeverCarriedOver() {
        let mock = F.build(pogo: F.pogoInput(F.home([F.climate(), F.air()]), isSimulated: true))
        XCTAssertFalse(mock.pogoSensors.isEmpty)
        XCTAssertEqual(mock.pogo.sourceID, SensorSourceIdentity.simulated.rawValue)

        for status: DataSourceConnectionStatus in [.idle, .connecting, .failed("unreachable"), .reconnecting(attempt: 1)] {
            let live = F.build(
                pogo: F.pogoInput(F.home([]), health: .waitingForData, connection: status, lastSyncAt: nil, source: F.hubSource),
                previous: mock,
                now: F.t0.addingTimeInterval(60)
            )
            XCTAssertEqual(live.pogoSensors, [], "\(status)")
            XCTAssertEqual(live.pogo.state, .waitingForData, "\(status)")
            XCTAssertEqual(live.pogo.moduleCount, 0)
            XCTAssertEqual(live.pogo.attention, [])
            XCTAssertNil(live.pogo.verifiedAt)
            XCTAssertFalse(live.pogo.isSimulated)
            XCTAssertEqual(live.pogo.sourceID, F.hubSource.rawValue)
            XCTAssertEqual(live.appleHome.access, .ready, "Apple Home is another source, untouched")
            XCTAssertEqual(live.appleHomeSensors, mock.appleHomeSensors)
            XCTAssertEqual(HomeGlanceRefreshPolicy.classify(from: mock, to: live), .privacy, "widgets drop the Mock values at once")
        }

        // The same hub reconnecting: its last values stay, unverified.
        let confirmed = F.build(pogo: F.pogoInput(F.home([F.climate()])))
        let reconnecting = F.build(
            pogo: F.pogoInput(F.home([F.climate()]), health: .reconnecting, connection: .failed("x"), lastSyncAt: nil),
            previous: confirmed
        )
        XCTAssertEqual(reconnecting.pogoSensors, confirmed.pogoSensors)
        XCTAssertEqual(reconnecting.pogo.state, .unverified)

        // Another hub: hub A's values are never hub B's.
        let otherHub = SensorSourceIdentity.hub(URL(string: "http://192.168.50.130:8787")!)
        let fromOtherHub = F.build(
            pogo: F.pogoInput(F.home([]), health: .waitingForData, connection: .failed("x"), lastSyncAt: nil, source: otherHub),
            previous: confirmed
        )
        XCTAssertEqual(fromOtherHub.pogoSensors, [])
        XCTAssertEqual(fromOtherHub.pogo.sourceID, otherHub.rawValue)
    }

    /// A glance stored before sources were recorded still tells simulated from live data.
    func testAGlanceWithoutARecordedSourceIsMatchedBySimulatedOrNot() {
        var legacyMock = F.build(pogo: F.pogoInput(F.home([F.climate()]), isSimulated: true))
        legacyMock.pogo.sourceID = nil
        var legacyLive = F.build(pogo: F.pogoInput(F.home([F.climate()])))
        legacyLive.pogo.sourceID = nil
        let waiting = F.pogoInput(F.home([]), health: .waitingForData, connection: .failed("x"), lastSyncAt: nil)

        XCTAssertEqual(F.build(pogo: waiting, previous: legacyMock).pogoSensors, [])
        XCTAssertEqual(F.build(pogo: waiting, previous: legacyLive).pogoSensors, legacyLive.pogoSensors)
    }

}
