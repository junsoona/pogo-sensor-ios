import XCTest
@testable import PogoHome

/// The Watch's rounds: the bridge directly first, the iPhone second, and — when neither works — the
/// last values kept with their time, never a value assumed to have arrived.
@MainActor
final class WatchSyncEngineTests: XCTestCase {
    private typealias F = GlanceFixtures
    private typealias W = WatchFixtures

    private var clock = Clock(GlanceFixtures.t0)

    private func engine(
        store: InMemoryWatchStore = InMemoryWatchStore(),
        hub: ScriptedHub = ScriptedHub(),
        phone: ScriptedPhone = ScriptedPhone(),
        reloader: CountingWatchReloader = CountingWatchReloader()
    ) -> WatchSyncEngine {
        let clock = clock
        return WatchSyncEngine(store: store, hub: hub, phone: phone, reloader: reloader, language: .korean, now: { clock.now })
    }

    private func configured(_ glance: HomeGlanceSnapshot? = nil, settings: WatchSettings = WatchFixtures.settings()) -> InMemoryWatchStore {
        InMemoryWatchStore(WatchStoredState(glance: glance, settings: settings, record: .empty))
    }

    private func reply(_ outcome: WatchRelayReply.Outcome, glance: HomeGlanceSnapshot?, settings: WatchSettings = WatchFixtures.settings()) -> WatchRelayReply {
        WatchRelayReply(outcome: outcome, payload: W.payload(glance: glance, settings: settings, sentAt: clock.now))
    }

    // MARK: - Direct

    func testOnTheBridgesNetworkTheWatchReadsItDirectlyAndDoesntAskTheIPhone() async {
        let labels = [WatchModuleLabel(moduleID: F.climateID, name: "거실 센서", roomName: "거실")]
        let hub = ScriptedHub([.success(W.hubSnapshot(temperature: 25))])
        let phone = ScriptedPhone(reachable: true)
        let store = configured(settings: W.settings(labels: labels))
        let sync = engine(store: store, hub: hub, phone: phone)
        clock.now = F.t0.addingTimeInterval(60)

        let round = await sync.refresh()

        XCTAssertEqual(round?.confirmedBy, .direct)
        XCTAssertEqual(hub.urls.map(\.absoluteString), [W.hubURL])
        XCTAssertEqual(phone.requestCount, 0)
        let temperature = sync.glance?.sensor(with: F.temperatureID)
        XCTAssertEqual(temperature?.value, 25)
        XCTAssertEqual(temperature?.checkedAt, clock.now)
        XCTAssertEqual(temperature?.deviceName, "거실 센서", "named as on the iPhone")
        XCTAssertEqual(sync.record.lastConfirmation, WatchConfirmation(path: .direct, at: clock.now))
        XCTAssertEqual(sync.connectionStatus, .confirmed(.direct, at: clock.now))
        XCTAssertEqual(store.state, sync.state, "persisted for the widgets")
    }

    func testABridgeStillRebuildingIsNotAskedAgainThroughTheIPhone() async {
        let previous = W.phoneGlance(at: F.t0)
        let phone = ScriptedPhone(reachable: true)
        let sync = engine(store: configured(previous), hub: ScriptedHub([.success(W.hubSnapshot(airReadings: false))]), phone: phone)
        clock.now = F.t0.addingTimeInterval(60)

        let round = await sync.refresh()

        XCTAssertEqual(round?.direct, .failed(.hubRecovering))
        XCTAssertEqual(phone.requestCount, 0)
        XCTAssertEqual(sync.glance?.pogo.state, .unverified)
        XCTAssertEqual(sync.glance?.pogoSensors, previous.pogoSensors)
    }

    // MARK: - Through the iPhone

    func testAwayFromTheBridgeTheIPhoneAnswersWhenItReachesTheBridge() async {
        let phoneAt = F.t0.addingTimeInterval(90)
        let phone = ScriptedPhone(reachable: true, [.success(reply(.confirmed, glance: W.phoneGlance(at: phoneAt, temperature: 21)))])
        let sync = engine(store: configured(W.phoneGlance(at: F.t0)), hub: ScriptedHub([.failure(URLError(.cannotConnectToHost))]), phone: phone)
        clock.now = F.t0.addingTimeInterval(100)

        let round = await sync.refresh()

        XCTAssertEqual(round, WatchSyncRound(at: clock.now, direct: .failed(.hubUnreachable), phone: .confirmed))
        XCTAssertEqual(sync.glance?.sensor(with: F.temperatureID)?.value, 21)
        XCTAssertEqual(sync.glance?.pogo.state, .healthy)
        XCTAssertEqual(sync.record.lastConfirmation, WatchConfirmation(path: .phone, at: phoneAt))
    }

    func testOutsideTheHomeNothingNewArrivesAndTheLastValueTurnsOld() async {
        let last = W.phoneGlance(at: F.t0)
        // The iPhone is reachable but away from the bridge too: it answers with what it last had.
        let phone = ScriptedPhone(reachable: true, [.success(reply(.hubUnreachable, glance: last))])
        let sync = engine(store: configured(last), hub: ScriptedHub([.failure(URLError(.notConnectedToInternet))]), phone: phone)
        clock.now = F.t0.addingTimeInterval(120)

        let round = await sync.refresh()

        XCTAssertEqual(round?.direct, .failed(.hubUnreachable))
        XCTAssertEqual(round?.phone, .failed(.phoneCannotReachHub))
        XCTAssertNil(round?.confirmedBy)
        XCTAssertEqual(sync.glance?.pogo.state, .unverified)
        XCTAssertEqual(sync.glance?.pogo.verifiedAt, F.t0, "the confirmation time doesn't move")
        XCTAssertEqual(sync.glance?.pogoSensors, last.pogoSensors, "values kept, none invented")
        XCTAssertEqual(WatchGlancePresentation.headline(sync.glance, now: clock.now), .notConfirmed(lastConfirmedAt: F.t0))
        XCTAssertEqual(WatchGlancePresentation.headline(sync.glance, now: F.t0.addingTimeInterval(HomeGlanceFreshness.staleAfter + 1)), .stale(lastConfirmedAt: F.t0))
        guard case .unreachable = sync.connectionStatus else { return XCTFail("\(sync.connectionStatus)") }
    }

    func testWithoutTheIPhoneInReachItIsntAskedAndTheStateIsNotConfirmed() async {
        let phone = ScriptedPhone(reachable: false)
        let sync = engine(store: configured(W.phoneGlance(at: F.t0)), hub: ScriptedHub([.failure(URLError(.timedOut))]), phone: phone)
        clock.now = F.t0.addingTimeInterval(30)

        let round = await sync.refresh()

        XCTAssertEqual(round?.phone, .failed(.phoneUnreachable))
        XCTAssertEqual(phone.requestCount, 0)
        XCTAssertEqual(sync.glance?.pogo.state, .unverified)
    }

    func testAnIPhoneThatDoesntAnswerInTimeIsReportedAsSuch() async {
        let phone = ScriptedPhone(reachable: true, [.failure(WatchPhoneRelayError.timedOut)])
        let sync = engine(store: configured(W.phoneGlance(at: F.t0)), hub: ScriptedHub([.failure(URLError(.timedOut))]), phone: phone)
        let round = await sync.refresh()
        XCTAssertEqual(round?.phone, .failed(.phoneTimedOut))
    }

    func testABadBridgeAnswerIsToldApartFromNoAnswer() {
        XCTAssertEqual(WatchSyncEngine.classify(URLError(.cannotFindHost)), .hubUnreachable)
        XCTAssertEqual(WatchSyncEngine.classify(PogoAPIError.transport("HTTP 500")), .badResponse)
        XCTAssertEqual(WatchSyncEngine.classify(PogoAPIError.unsupportedSchemaVersion(found: 2, expected: 1)), .badResponse)
    }

    func testAWatchWithoutSettingsGetsThemFromTheIPhonesAnswer() async {
        let settings = W.settings(hubURL: "http://10.0.0.5:8787")
        let phone = ScriptedPhone(reachable: true, [.success(reply(.confirmed, glance: W.phoneGlance(at: F.t0), settings: settings))])
        let hub = ScriptedHub()
        let sync = engine(hub: hub, phone: phone)

        let round = await sync.refresh()

        XCTAssertEqual(round?.direct, .failed(.notConfigured))
        XCTAssertEqual(hub.fetchCount, 0)
        XCTAssertEqual(sync.settings, settings)
        XCTAssertEqual(round?.confirmedBy, .phone)
    }

    func testTheIPhoneSwitchingFromMockToLiveDropsTheMockValuesOnTheWatch() {
        var simulated = W.phoneGlance(at: F.t0)
        simulated.pogo.isSimulated = true
        simulated.pogo.sourceID = SensorSourceIdentity.simulated.rawValue
        let store = configured(simulated, settings: W.settings(mode: .mock))
        let sync = engine(store: store)
        XCTAssertFalse(sync.glance?.pogoSensors.isEmpty ?? true)
        clock.now = F.t0.addingTimeInterval(60)

        // The new settings arrive together with a late glance of the Mock source.
        sync.receivePush(W.payload(glance: simulated, settings: W.settings(updatedAt: clock.now), sentAt: clock.now))

        XCTAssertEqual(sync.glance?.pogoSensors, [])
        XCTAssertEqual(sync.glance?.pogo.isSimulated, false)
        XCTAssertEqual(sync.glance?.pogo.moduleCount, 0)
        XCTAssertEqual(sync.glance?.appleHomeSensors, simulated.appleHomeSensors)
        XCTAssertEqual(store.state.glance, sync.glance, "persisted for the Watch widgets")
    }

    func testTheIPhoneSwitchingToAnotherHubDropsTheOldHubsValuesOnTheWatch() async {
        let sync = engine(store: configured(W.phoneGlance(at: F.t0)))
        XCTAssertFalse(sync.glance?.pogoSensors.isEmpty ?? true)
        clock.now = F.t0.addingTimeInterval(60)

        sync.receivePush(W.payload(glance: nil, settings: W.settings(updatedAt: clock.now, hubURL: "http://192.168.50.130:8787"), sentAt: clock.now))
        XCTAssertEqual(sync.glance?.pogoSensors, [])

        // Still unreachable: nothing of the old hub comes back as "unverified".
        let round = await sync.refresh(allowsPhone: false)
        XCTAssertEqual(round?.direct, .failed(.hubUnreachable))
        XCTAssertEqual(sync.glance?.pogoSensors, [])
    }

    func testSimulatedDataIsNeverFetchedFromABridge() async {
        var simulated = W.phoneGlance(at: F.t0)
        simulated.pogo.isSimulated = true
        simulated.pogo.sourceID = SensorSourceIdentity.simulated.rawValue
        let hub = ScriptedHub([.success(W.hubSnapshot())])
        let phone = ScriptedPhone(reachable: true, [.success(reply(.simulated, glance: simulated, settings: W.settings(mode: .mock)))])
        let sync = engine(store: configured(settings: W.settings(mode: .mock)), hub: hub, phone: phone)

        let round = await sync.refresh()

        XCTAssertEqual(hub.fetchCount, 0)
        XCTAssertEqual(round?.direct, .failed(.simulated))
        XCTAssertEqual(sync.glance?.pogo.isSimulated, true)
        XCTAssertEqual(sync.connectionStatus, .simulated)
    }

    func testABackgroundRefreshOnlyTriesTheBridge() async {
        let phone = ScriptedPhone(reachable: true, [.success(reply(.confirmed, glance: W.phoneGlance(at: F.t0)))])
        let sync = engine(store: configured(W.phoneGlance(at: F.t0)), hub: ScriptedHub([.failure(URLError(.timedOut))]), phone: phone)

        let round = await sync.refresh(allowsPhone: false)

        XCTAssertEqual(phone.requestCount, 0)
        XCTAssertEqual(round?.phone, .notTried)
        XCTAssertEqual(sync.glance?.pogo.state, .unverified)
    }

    // MARK: - Hand-overs

    func testAHandOverIsMergedAndAnOlderOneChangesNothing() {
        let sync = engine()
        // The iPhone's glance comes from the hub its settings name.
        var newerGlance = W.phoneGlance(at: F.t0.addingTimeInterval(60), temperature: 22)
        newerGlance.pogo.sourceID = SensorSourceIdentity.hub(URL(string: "http://10.0.0.9:8787")!).rawValue
        let newer = W.payload(glance: newerGlance, settings: W.settings(updatedAt: F.t0.addingTimeInterval(60), hubURL: "http://10.0.0.9:8787"))
        let older = W.payload(glance: W.phoneGlance(at: F.t0, temperature: 30), settings: W.settings(updatedAt: F.t0))

        sync.receivePush(newer)
        sync.receivePush(older)

        XCTAssertEqual(sync.settings?.hubBaseURL, "http://10.0.0.9:8787")
        XCTAssertEqual(sync.glance?.sensor(with: F.temperatureID)?.value, 22)
        XCTAssertEqual(sync.record.lastPushAt, clock.now)
    }

    func testStateSurvivesARelaunchThroughTheStore() async {
        let store = configured(settings: W.settings())
        let first = engine(store: store, hub: ScriptedHub([.success(W.hubSnapshot())]))
        await first.refresh()
        let relaunched = engine(store: store)
        XCTAssertEqual(relaunched.state, first.state)
    }

    func testTheFileStoreRoundTripsAndReadsADamagedFileAsEmpty() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WatchStateStore(directory: directory)
        XCTAssertEqual(store.load(), .empty)
        let state = WatchStoredState(glance: W.phoneGlance(at: F.t0), settings: W.settings(), record: WatchSyncRecord(lastRound: WatchSyncRound(at: F.t0, direct: .confirmed, phone: .notTried), lastConfirmation: nil, lastPushAt: nil))
        try store.save(state)
        XCTAssertEqual(store.load(), state)
        try Data("not json".utf8).write(to: store.fileURL)
        XCTAssertEqual(store.load(), .empty)
    }

    // MARK: - Widgets

    func testWidgetsRedrawForAStateChangeButNotForEveryRound() async {
        let reloader = CountingWatchReloader()
        let hub = ScriptedHub([.success(W.hubSnapshot(temperature: 24.0))])
        let sync = engine(store: configured(settings: W.settings()), hub: hub, reloader: reloader)

        await sync.refresh()
        XCTAssertEqual(reloader.count, 1, "first data")

        clock.now = F.t0.addingTimeInterval(30)
        hub.results = [.success(W.hubSnapshot(temperature: 24.1))]
        await sync.refresh()
        XCTAssertEqual(reloader.count, 1, "a tiny drift isn't worth a reload")

        clock.now = F.t0.addingTimeInterval(120)
        hub.results = [.failure(URLError(.timedOut))]
        await sync.refresh()
        XCTAssertEqual(reloader.count, 2, "'not confirmed' must reach the complications")
    }

    func testChangingTheSelectionRedrawsTheWidgets() {
        let reloader = CountingWatchReloader()
        let sync = engine(store: configured(W.phoneGlance(at: F.t0)), reloader: reloader)
        sync.receivePush(W.payload(glance: nil, settings: W.settings(updatedAt: F.t0.addingTimeInterval(1), selection: [F.appleHomeTemperatureID])))
        XCTAssertEqual(reloader.count, 1)
    }
}

/// The iPhone answering the Watch — possibly launched in the background just for it.
@MainActor
final class WatchRelayResponderTests: XCTestCase {
    private typealias F = GlanceFixtures
    private typealias W = WatchFixtures

    private var fetches = 0

    private func responder(
        settings: WatchSettings = WatchFixtures.settings(),
        live: HomeGlanceSnapshot? = nil,
        last: HomeGlanceSnapshot? = WatchFixtures.phoneGlance(at: GlanceFixtures.t0),
        fetch: @escaping @MainActor (URL) async throws -> HomeSnapshot = { _ in throw URLError(.timedOut) },
        now: Date = GlanceFixtures.t0.addingTimeInterval(300)
    ) -> WatchRelayResponder {
        WatchRelayResponder(
            settings: { settings },
            liveGlance: { live },
            lastGlance: { last },
            applyConfiguration: { PogoGlanceRefresher.applyingLabels([WatchModuleLabel(moduleID: F.climateID, name: "거실 센서", roomName: "거실")], to: $0) },
            homeName: { "우리 집" },
            fetchSnapshot: { [unowned self] url in
                self.fetches += 1
                return try await fetch(url)
            },
            now: { now }
        )
    }

    func testALiveConfirmedStateIsTheAnswerWithoutAnotherFetch() async {
        let live = W.phoneGlance(at: F.t0.addingTimeInterval(299))
        let reply = await responder(live: live).reply()
        XCTAssertEqual(reply.outcome, .confirmed)
        XCTAssertEqual(reply.payload.glance, live)
        XCTAssertEqual(fetches, 0)
    }

    func testInTheBackgroundTheIPhoneFetchesOnceWithTheUsersNames() async {
        let reply = await responder(fetch: { _ in W.hubSnapshot(temperature: 27) }).reply()
        XCTAssertEqual(reply.outcome, .confirmed)
        let temperature = reply.payload.glance?.sensor(with: F.temperatureID)
        XCTAssertEqual(temperature?.value, 27)
        XCTAssertEqual(temperature?.deviceName, "거실 센서")
        XCTAssertEqual(reply.payload.glance?.pogo.verifiedAt, F.t0.addingTimeInterval(300))
        XCTAssertEqual(reply.payload.glance?.appleHome.access, .ready, "Apple Home carried over from the stored glance")
        XCTAssertEqual(fetches, 1)
    }

    func testAnIPhoneAwayFromTheBridgeSaysSoAndSendsItsLastState() async {
        let last = W.phoneGlance(at: F.t0)
        let reply = await responder(last: last).reply()
        XCTAssertEqual(reply.outcome, .hubUnreachable)
        XCTAssertEqual(reply.payload.glance, last, "nothing new is claimed")
    }

    func testARebuildingBridgeIsReportedAsSuch() async {
        let reply = await responder(fetch: { _ in W.hubSnapshot(airReadings: false) }).reply()
        XCTAssertEqual(reply.outcome, .hubRecovering)
        XCTAssertEqual(reply.payload.glance?.pogo.state, .unverified)
    }

    func testSimulatedDataIsAnsweredAsSimulated() async {
        let reply = await responder(settings: W.settings(mode: .mock)).reply()
        XCTAssertEqual(reply.outcome, .simulated)
        XCTAssertEqual(fetches, 0)
    }
}

/// What the iPhone sends as the Watch's settings.
final class PhoneWatchSettingsTests: XCTestCase {
    private typealias F = GlanceFixtures
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        suiteName = "PhoneWatchSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    func testTheWatchGetsTheAddressAndModeTheIPhoneItselfUses() {
        defaults.set("http://10.1.2.3:8787", forKey: PogoSettingsKeys.liveBaseURL)
        var settings = PhoneWatchSettings.make(defaults: defaults, snapshot: F.home([F.climate()]), now: F.t0)
        XCTAssertEqual(settings.hubBaseURL, "http://10.1.2.3:8787")
        XCTAssertEqual(settings.dataSourceMode, .live)
        XCTAssertEqual(settings.updatedAt, F.t0)

        defaults.set("not a url", forKey: PogoSettingsKeys.liveBaseURL)
        defaults.set(DataSourceMode.mock.rawValue, forKey: PogoSettingsKeys.dataSourceMode)
        settings = PhoneWatchSettings.make(defaults: defaults, snapshot: F.home([F.climate()]), now: F.t0)
        XCTAssertEqual(settings.hubBaseURL, PogoAPIEndpoint.defaultBaseURLString, "the same fallback the app connects to")
        XCTAssertEqual(settings.dataSourceMode, .mock)
    }

    @MainActor
    func testTheSelectionIsLimitedToFourAndKeepsItsOrder() {
        let ids = (0..<5).map { _ in HomeGlanceValueID.pogo(module: UUID(), kind: .humidity).stringValue }
        for id in ids.prefix(4) { XCTAssertTrue(PhoneWatchSettings.toggle(id, in: defaults)) }
        XCTAssertFalse(PhoneWatchSettings.toggle(ids[4], in: defaults), "a fifth value is refused")
        XCTAssertTrue(PhoneWatchSettings.toggle(ids[1], in: defaults))
        XCTAssertEqual(PhoneWatchSettings.selection(in: defaults), [ids[0], ids[2], ids[3]])
    }

    @MainActor
    func testModuleLabelsCarryTheUsersNamesInRoomOrder() {
        let bedroom = Room(id: UUID(), name: "침실", symbolName: "bed.double.fill", sortOrder: 5)
        let air = F.air()
        let inBedroom = SensorModule(id: air.id, name: "침실 공기", roomID: bedroom.id, readings: air.readings, isOnline: true, lastSeen: F.t0)
        let snapshot = HomeSnapshot(timestamp: F.t0, rooms: [F.room, bedroom], modules: [inBedroom, F.climate()])
        XCTAssertEqual(PhoneWatchSettings.moduleLabels(of: snapshot), [
            WatchModuleLabel(moduleID: F.climateID, name: "거실 센서", roomName: "거실"),
            WatchModuleLabel(moduleID: F.airID, name: "침실 공기", roomName: "침실"),
        ])
    }
}
