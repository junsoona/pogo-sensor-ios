import XCTest
@testable import PogoHome

/// Settings and glances handed from the iPhone to the Watch: what is accepted, what is ignored,
/// and how two copies of the home are combined without ever resurrecting older or revoked data.
final class WatchSettingsTransferTests: XCTestCase {
    private typealias F = GlanceFixtures
    private typealias W = WatchFixtures

    func testOnlyAUsableHTTPAddressIsKeptAndOnlyLiveModeFetchesDirectly() {
        XCTAssertEqual(W.settings(hubURL: " http://192.168.50.129:8787 ").hubBaseURL, "http://192.168.50.129:8787")
        XCTAssertNil(W.settings(hubURL: "192.168.50.129:8787").hubBaseURL, "no scheme")
        XCTAssertNil(W.settings(hubURL: "ftp://hub.local").hubBaseURL)
        XCTAssertNil(W.settings(hubURL: "").directHubURL)
        XCTAssertEqual(W.settings().directHubURL?.absoluteString, W.hubURL)
        XCTAssertNil(W.settings(mode: .mock).directHubURL, "simulated data has no bridge to fetch")
    }

    func testTheSelectionIsParseableUniqueAndAtMostFourInOrder() {
        let ids = (0..<6).map { _ in HomeGlanceValueID.pogo(module: UUID(), kind: .temperature).stringValue }
        let normalized = WatchSettings.normalizedSelection([ids[0], "garbage", ids[1], ids[0]] + Array(ids[2...]))
        XCTAssertEqual(normalized, Array(ids[0..<4]))
    }

    func testTheNewestSettingsWinAndAnOlderDeliveryIsIgnored() {
        let old = W.settings(updatedAt: F.t0)
        let new = W.settings(updatedAt: F.t0.addingTimeInterval(60), hubURL: "http://10.0.0.2:8787")
        XCTAssertTrue(WatchSettings.shouldAccept(old, over: nil))
        XCTAssertTrue(WatchSettings.shouldAccept(new, over: old))
        XCTAssertFalse(WatchSettings.shouldAccept(old, over: new))
        var otherVersion = new
        otherVersion.schemaVersion = 99
        XCTAssertFalse(WatchSettings.shouldAccept(otherVersion, over: nil))
    }

    func testPayloadsSurviveWatchConnectivityAndDamagedOnesAreIgnored() throws {
        let payload = W.payload(glance: W.phoneGlance(at: F.t0))
        let message = try WatchSyncCoding.message(for: payload)
        XCTAssertEqual(WatchSyncCoding.payload(from: message), payload)
        XCTAssertTrue(PropertyListSerialization.propertyList(message, isValidFor: .binary), "WatchConnectivity carries property lists only")

        XCTAssertNil(WatchSyncCoding.payload(from: [:]))
        XCTAssertNil(WatchSyncCoding.payload(from: [WatchSyncCoding.payloadKey: Data("{".utf8)]))
        let reply = WatchRelayReply(outcome: .hubUnreachable, payload: payload)
        XCTAssertEqual(WatchSyncCoding.reply(from: try WatchSyncCoding.message(for: reply)), reply)
        XCTAssertTrue(WatchSyncCoding.isRefreshRequest(WatchSyncCoding.refreshRequestMessage))
        XCTAssertFalse(WatchSyncCoding.isRefreshRequest(["pogo.request": "delete everything"]))
    }

    func testAPayloadFromAnotherSchemaVersionIsIgnored() throws {
        let payload = WatchSyncPayload(sentAt: F.t0, glance: nil, settings: W.settings(), schemaVersion: 2)
        XCTAssertNil(WatchSyncCoding.payload(from: try WatchSyncCoding.message(for: payload)))
    }
}

final class WatchGlanceMergerTests: XCTestCase {
    private typealias F = GlanceFixtures
    private typealias W = WatchFixtures

    func testTheMoreRecentPogoConfirmationWinsWhicheverArrivesLast() {
        let older = W.phoneGlance(at: F.t0, temperature: 20)
        let newer = W.phoneGlance(at: F.t0.addingTimeInterval(120), temperature: 25)
        XCTAssertEqual(WatchGlanceMerger.merge(current: older, incoming: newer).sensor(with: F.temperatureID)?.value, 25)
        XCTAssertEqual(WatchGlanceMerger.merge(current: newer, incoming: older).sensor(with: F.temperatureID)?.value, 25, "a late, older copy never replaces a newer confirmation")
    }

    func testForTheSameConfirmationTheLaterWriteDecides() {
        let confirmed = W.phoneGlance(at: F.t0)
        let unverified = WatchGlanceMerger.markingUnreachable(confirmed, at: F.t0.addingTimeInterval(60))!
        XCTAssertEqual(WatchGlanceMerger.merge(current: unverified, incoming: confirmed).pogo.state, .unverified,
                       "an older copy with the same confirmation doesn't undo 'not confirmed'")
        XCTAssertEqual(WatchGlanceMerger.merge(current: confirmed, incoming: unverified).pogo.state, .unverified)
    }

    func testMarkingUnreachableKeepsValuesAndTheirConfirmationTimes() {
        let glance = W.phoneGlance(at: F.t0)
        let marked = WatchGlanceMerger.markingUnreachable(glance, at: F.t0.addingTimeInterval(300))!
        XCTAssertEqual(marked.pogo.state, .unverified)
        XCTAssertEqual(marked.pogo.verifiedAt, F.t0)
        XCTAssertEqual(marked.sensors, glance.sensors)
        XCTAssertNil(WatchGlanceMerger.markingUnreachable(nil, at: F.t0))
    }

    func testAppleHomeValuesRevokedLaterNeverComeBackFromAnOlderCopy() {
        let readable = W.phoneGlance(at: F.t0)
        let revoked = W.phoneGlance(at: F.t0.addingTimeInterval(60), appleHome: .denied)
        let merged = WatchGlanceMerger.merge(current: revoked, incoming: readable)
        XCTAssertEqual(merged.appleHome.access, .denied)
        XCTAssertTrue(merged.appleHomeSensors.isEmpty)
        XCTAssertFalse(merged.pogoSensors.isEmpty)
        XCTAssertEqual(WatchGlanceMerger.merge(current: readable, incoming: revoked).appleHomeSensors, [])
    }

    func testSwitchingToAnotherHubGoesByTheLatestWrite() {
        let hubA = W.phoneGlance(at: F.t0.addingTimeInterval(600))
        var hubB = W.phoneGlance(at: F.t0.addingTimeInterval(900))
        hubB.pogo.sourceID = SensorSourceIdentity.hub(URL(string: "http://192.168.50.130:8787")!).rawValue
        hubB.pogo.verifiedAt = F.t0
        XCTAssertEqual(WatchGlanceMerger.merge(current: hubA, incoming: hubB).pogo.sourceID, hubB.pogo.sourceID)
        XCTAssertEqual(WatchGlanceMerger.merge(current: hubB, incoming: hubA).pogo.sourceID, hubB.pogo.sourceID, "the older copy is not the current hub")
    }

    func testSwitchingBetweenSimulatedAndLiveDataGoesByTheLatestWrite() {
        let live = W.phoneGlance(at: F.t0.addingTimeInterval(600))
        var simulated = W.phoneGlance(at: F.t0.addingTimeInterval(900))
        simulated.pogo.isSimulated = true
        simulated.pogo.sourceID = SensorSourceIdentity.simulated.rawValue
        simulated.pogo.verifiedAt = F.t0
        XCTAssertTrue(WatchGlanceMerger.merge(current: live, incoming: simulated).pogo.isSimulated)
        XCTAssertTrue(WatchGlanceMerger.merge(current: simulated, incoming: live).pogo.isSimulated, "the older live copy is not the current mode")
    }
}

final class PogoGlanceRefresherTests: XCTestCase {
    private typealias F = GlanceFixtures
    private typealias W = WatchFixtures

    func testACompleteFetchIsAConfirmationAtItsOwnTimeAndKeepsAppleHome() {
        let previous = W.phoneGlance(at: F.t0)
        let at = F.t0.addingTimeInterval(300)
        let glance = PogoGlanceRefresher.refreshed(previous: previous, fetched: W.hubSnapshot(temperature: 26), from: F.hubSource, fetchedAt: at, homeName: "우리 집")
        XCTAssertEqual(glance.pogo.state, .healthy)
        XCTAssertEqual(glance.pogo.verifiedAt, at)
        XCTAssertEqual(glance.sensor(with: F.temperatureID)?.value, 26)
        XCTAssertEqual(glance.sensor(with: F.temperatureID)?.checkedAt, at)
        XCTAssertEqual(glance.appleHome, previous.appleHome)
        XCTAssertEqual(glance.appleHomeSensors, previous.appleHomeSensors)
    }

    func testAnIncompleteFetchKeepsThePreviousValuesUnconfirmed() {
        let previous = W.phoneGlance(at: F.t0)
        let glance = PogoGlanceRefresher.refreshed(previous: previous, fetched: W.hubSnapshot(airReadings: false), from: F.hubSource, fetchedAt: F.t0.addingTimeInterval(60), homeName: "우리 집")
        XCTAssertEqual(glance.pogo.state, .unverified)
        XCTAssertEqual(glance.pogo.verifiedAt, F.t0)
        XCTAssertEqual(glance.pogoSensors, previous.pogoSensors, "a rebuilding registry never makes values disappear")
    }

    func testTheIPhonesNamesAndRoomsNameDirectlyFetchedModules() {
        let labels = [WatchModuleLabel(moduleID: F.climateID, name: "거실 센서", roomName: "거실")]
        let hub = W.hubSnapshot()
        let named = PogoGlanceRefresher.applyingLabels(labels, to: hub)
        let climate = named.modules.first { $0.id == F.climateID }!
        XCTAssertEqual(climate.name, "거실 센서")
        XCTAssertEqual(named.room(for: climate)?.name, "거실")
        let air = named.modules.first { $0.id == F.airID }!
        XCTAssertEqual(air.name, F.air().name, "a module the iPhone didn't describe keeps the bridge's name")
        XCTAssertEqual(named.room(for: air)?.id, ModuleCatalog.unspecifiedRoomID)
        XCTAssertEqual(named.modules.map(\.readings), hub.modules.map(\.readings), "names only — readings untouched")
    }
}

/// What the Watch may say as time passes and connections fail.
final class WatchGlancePresentationTests: XCTestCase {
    private typealias F = GlanceFixtures
    private typealias W = WatchFixtures

    func testARecentConfirmationIsCurrentWithCounts() {
        let headline = WatchGlancePresentation.headline(W.phoneGlance(at: F.t0), now: F.t0.addingTimeInterval(60))
        XCTAssertEqual(headline, .healthy(online: 2, total: 2, confirmedAt: F.t0))
        XCTAssertTrue(headline.isCurrent)
    }

    func testWithoutAnyPathTheLastValueStaysWithItsTimeThenTurnsOld() {
        let marked = WatchGlanceMerger.markingUnreachable(W.phoneGlance(at: F.t0), at: F.t0.addingTimeInterval(60))!
        let sensor = marked.sensor(with: F.temperatureID)!

        let soon = F.t0.addingTimeInterval(5 * 60)
        XCTAssertEqual(WatchGlancePresentation.headline(marked, now: soon), .notConfirmed(lastConfirmedAt: F.t0))
        XCTAssertEqual(WatchGlancePresentation.condition(of: sensor, in: marked, now: soon), .sourceUnverified)
        XCTAssertEqual(sensor.value, 23.4, "the last value is still shown")

        let later = F.t0.addingTimeInterval(HomeGlanceFreshness.staleAfter + 60)
        XCTAssertEqual(WatchGlancePresentation.headline(marked, now: later), .stale(lastConfirmedAt: F.t0))
        XCTAssertEqual(WatchGlancePresentation.condition(of: sensor, in: marked, now: later), .stale)
        XCTAssertFalse(WatchGlancePresentation.headline(marked, now: later).isCurrent)
    }

    func testAConfirmedStateAlsoTurnsOldWithoutNewData() {
        let glance = W.phoneGlance(at: F.t0)
        XCTAssertEqual(WatchGlancePresentation.headline(glance, now: F.t0.addingTimeInterval(HomeGlanceFreshness.staleAfter + 1)), .stale(lastConfirmedAt: F.t0))
        let changes = WatchGlancePresentation.changeDates(glance, selection: F.temperatureID, after: F.t0)
        XCTAssertTrue(changes.contains(F.t0.addingTimeInterval(HomeGlanceFreshness.staleAfter + 1)), "complication timelines get an entry when it turns old")
    }

    func testNothingReceivedAndNothingConfirmedAreNamedAsSuch() {
        XCTAssertEqual(WatchGlancePresentation.headline(nil, now: F.t0), .noData)
        var empty = W.phoneGlance(at: F.t0)
        empty.pogo = .empty
        XCTAssertEqual(WatchGlancePresentation.headline(empty, now: F.t0), .waitingForData)
        empty.pogo.state = .unverified
        XCTAssertEqual(WatchGlancePresentation.headline(empty, now: F.t0), .notConfirmed(lastConfirmedAt: nil))
    }

    func testSelectedValuesKeepTheIPhonesOrderAndNameWhatIsMissing() {
        let glance = W.phoneGlance(at: F.t0)
        let gone = HomeGlanceValueID.pogo(module: UUID(), kind: .humidity)
        let settings = W.settings(selection: [F.appleHomeTemperatureID, F.temperatureID, gone])
        let values = WatchGlancePresentation.selectedValues(glance, settings: settings, now: F.t0.addingTimeInterval(30))
        XCTAssertEqual(values.map(\.id), settings.selectedValueIDs)
        guard case let .found(first, .recent) = values[0].lookup else { return XCTFail("\(values[0].lookup)") }
        XCTAssertEqual(first.source, .appleHome)
        XCTAssertEqual(values[2].lookup, .missing)
        XCTAssertEqual(WatchGlancePresentation.selectedValues(glance, settings: nil, now: F.t0), [])
    }

    func testAppleHomeValuesAreNotShownOnceTheIPhoneLostAccess() {
        let glance = W.phoneGlance(at: F.t0, appleHome: .denied)
        let values = WatchGlancePresentation.selectedValues(glance, settings: W.settings(selection: [F.appleHomeTemperatureID]), now: F.t0)
        XCTAssertEqual(values.first?.lookup, .sourceUnavailable(.denied))
    }

    func testTheConnectionLineNamesThePathOrWhyNoneWorked() {
        let settings = W.settings()
        func status(_ round: WatchSyncRound?, settings: WatchSettings? = settings, checking: Bool = false) -> WatchConnectionStatus {
            WatchGlancePresentation.connection(settings: settings, record: WatchSyncRecord(lastRound: round, lastConfirmation: nil, lastPushAt: nil), isChecking: checking)
        }
        XCTAssertEqual(status(nil, settings: nil), .notConfigured)
        XCTAssertEqual(status(nil, settings: W.settings(mode: .mock)), .simulated)
        XCTAssertEqual(status(nil), .notChecked)
        XCTAssertEqual(status(nil, checking: true), .checking)
        XCTAssertEqual(status(WatchSyncRound(at: F.t0, direct: .confirmed, phone: .notTried)), .confirmed(.direct, at: F.t0))
        XCTAssertEqual(status(WatchSyncRound(at: F.t0, direct: .failed(.hubUnreachable), phone: .confirmed)), .confirmed(.phone, at: F.t0))
        XCTAssertEqual(
            status(WatchSyncRound(at: F.t0, direct: .failed(.hubUnreachable), phone: .failed(.phoneCannotReachHub))),
            .unreachable(direct: .failed(.hubUnreachable), phone: .failed(.phoneCannotReachHub), at: F.t0)
        )
    }
}
