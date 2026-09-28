import XCTest
@testable import PogoHome

/// The iPhone's side of the first hand-over: the Watch gets the current settings once the link is
/// really ready — after a slow activation, a Watch app installed later, a callback missed while the
/// app was suspended, a failed hand-over or a switch to another Watch — not only when the user
/// changes a selection.
@MainActor
final class PhoneWatchRelayTests: XCTestCase {
    private typealias F = GlanceFixtures

    private var session: ScriptedPhoneWatchSession!
    private var defaults: UserDefaults!
    private var clock = GlanceFixtures.t0
    private var relay: PhoneWatchRelay!

    private static let ready = PhoneWatchSessionReading(activation: .activated, isPaired: true, isWatchAppInstalled: true, isReachable: false)
    private static let appNotInstalled = PhoneWatchSessionReading(activation: .activated, isPaired: true, isWatchAppInstalled: false, isReachable: false)

    override func setUp() async throws {
        session = ScriptedPhoneWatchSession()
        defaults = makeIsolatedDefaults()
        PhoneWatchSettings.setSelection([F.temperatureID.stringValue], in: defaults)
        let appModel = AppModel(dataSource: MockSensorDataSource(), configurationStore: InMemoryHomeConfigurationStore(language: .korean), language: .korean)
        let appleHome = AppleHomeModel(provider: ScriptedAppleHomeProvider(snapshot: AppleHomeFixtures.ready([])), defaults: makeIsolatedDefaults())
        let publisher = HomeGlancePublisher(appModel: appModel, appleHome: appleHome, store: InMemoryGlanceStore(), reloader: CountingReloader(), isSimulatedData: { false })
        relay = PhoneWatchRelay(appModel: appModel, publisher: publisher, defaults: defaults, session: session, now: { [unowned self] in self.clock })
    }

    func testBeforeActivationWatchConnectivitysFalseIsNotReadAsNotInstalled() {
        XCTAssertEqual(PhoneWatchRelay.state(for: .notActivated), .activating)
        XCTAssertEqual(PhoneWatchRelay.state(for: PhoneWatchSessionReading(activation: .inactive, isPaired: true, isWatchAppInstalled: true, isReachable: false)), .activating)
        XCTAssertEqual(PhoneWatchRelay.state(for: PhoneWatchSessionReading(activation: .activated, isPaired: false, isWatchAppInstalled: false, isReachable: false)), .notPaired)
        XCTAssertEqual(PhoneWatchRelay.state(for: Self.appNotInstalled), .appNotInstalled)
        XCTAssertEqual(PhoneWatchRelay.state(for: Self.ready), .ready)
    }

    func testASelectionMadeWhileActivatingIsHandedOverWhenActivationCompletes() throws {
        relay.activate()
        XCTAssertEqual(session.activateCount, 1)
        XCTAssertEqual(relay.watchState, .activating)

        PhoneWatchSettings.toggle(F.appleHomeTemperatureID.stringValue, in: defaults)
        relay.settingsDidChange()
        XCTAssertTrue(session.handedOver.isEmpty, "nothing can be handed over before activation")
        XCTAssertEqual(relay.handOver, .pending)

        clock = F.t0.addingTimeInterval(5)
        session.deliver(.activationCompleted, Self.ready)

        XCTAssertEqual(relay.watchState, .ready)
        XCTAssertEqual(session.handedOver.count, 1, "the first activation hands over the current settings")
        let settings = try XCTUnwrap(session.handedOver.last?.settings)
        XCTAssertEqual(settings.selectedValueIDs, [F.temperatureID.stringValue, F.appleHomeTemperatureID.stringValue])
        XCTAssertEqual(settings.updatedAt, clock)
        XCTAssertEqual(relay.handOver, .handedOver(at: clock))
    }

    func testAWatchAppInstalledLaterGetsTheSettingsAtOnce() {
        relay.activate()
        session.deliver(.activationCompleted, Self.appNotInstalled)
        XCTAssertEqual(relay.watchState, .appNotInstalled)
        relay.settingsDidChange()
        XCTAssertTrue(session.handedOver.isEmpty)
        XCTAssertEqual(relay.handOver, .pending)

        session.deliver(.watchStateChanged, Self.ready)

        XCTAssertEqual(relay.watchState, .ready)
        XCTAssertEqual(session.handedOver.count, 1)
        XCTAssertEqual(session.handedOver.last?.settings.selectedValueIDs, [F.temperatureID.stringValue])
    }

    /// What happened on the device: the Watch app was installed, but the running iPhone app never
    /// heard about it and kept saying "PogoHome not on Watch".
    func testAMissedInstallCallbackIsCaughtWhenTheAppReturnsToTheForeground() {
        relay.activate()
        session.deliver(.activationCompleted, Self.appNotInstalled)
        session.reading = Self.ready // no `sessionWatchStateDidChange`

        relay.recheck()

        XCTAssertEqual(relay.watchState, .ready)
        XCTAssertEqual(session.handedOver.count, 1)
    }

    func testAHandOverReadsTheSessionNowInsteadOfTheLastCallback() {
        relay.activate()
        session.deliver(.activationCompleted, Self.appNotInstalled)
        session.reading = Self.ready

        relay.settingsDidChange()

        XCTAssertEqual(relay.watchState, .ready, "the stale state is corrected")
        XCTAssertEqual(session.handedOver.count, 1)
    }

    func testAFailedHandOverIsTriedAgain() {
        session.failsUpdates = true
        relay.activate()
        session.deliver(.activationCompleted, Self.ready)
        XCTAssertEqual(relay.handOver, .failed)
        XCTAssertTrue(session.handedOver.isEmpty)

        session.failsUpdates = false
        relay.recheck()

        XCTAssertEqual(session.handedOver.count, 1)
        XCTAssertEqual(relay.handOver, .handedOver(at: clock))
    }

    func testOnceHandedOverReturningToTheForegroundDoesntSendAgain() {
        relay.activate()
        session.deliver(.activationCompleted, Self.ready)
        session.deliver(.reachabilityChanged, PhoneWatchSessionReading(activation: .activated, isPaired: true, isWatchAppInstalled: true, isReachable: true))
        relay.recheck()

        XCTAssertEqual(session.handedOver.count, 1)
    }

    func testAnotherWatchGetsTheSettingsAgain() {
        relay.activate()
        session.deliver(.activationCompleted, Self.ready)
        XCTAssertEqual(session.handedOver.count, 1)

        session.deliver(.becameInactive, PhoneWatchSessionReading(activation: .inactive, isPaired: true, isWatchAppInstalled: true, isReachable: false))
        XCTAssertEqual(relay.watchState, .activating)
        XCTAssertEqual(relay.handOver, .pending)
        session.deliver(.deactivated, .notActivated)
        clock = F.t0.addingTimeInterval(60)
        session.deliver(.activationCompleted, Self.ready)

        XCTAssertEqual(session.handedOver.count, 2)
        XCTAssertEqual(session.handedOver.last?.settings.updatedAt, clock)
    }

    func testEachHandOverCarriesNewerSettingsSoTheWatchKeepsTheLatest() throws {
        relay.activate()
        session.deliver(.activationCompleted, Self.ready)
        clock = F.t0.addingTimeInterval(30)
        PhoneWatchSettings.setSelection([F.appleHomeTemperatureID.stringValue], in: defaults)
        relay.settingsDidChange()

        let first = try XCTUnwrap(session.handedOver.first?.settings)
        let latest = try XCTUnwrap(session.handedOver.last?.settings)
        XCTAssertTrue(WatchSettings.shouldAccept(latest, over: first))
        XCTAssertFalse(WatchSettings.shouldAccept(first, over: latest), "a late copy of the first never undoes the latest")
    }

    func testWhereNoWatchCanPairNothingHappens() {
        let appModel = AppModel(dataSource: MockSensorDataSource(), configurationStore: InMemoryHomeConfigurationStore(language: .korean), language: .korean)
        let appleHome = AppleHomeModel(provider: ScriptedAppleHomeProvider(snapshot: AppleHomeFixtures.ready([])), defaults: makeIsolatedDefaults())
        let publisher = HomeGlancePublisher(appModel: appModel, appleHome: appleHome, store: InMemoryGlanceStore(), reloader: CountingReloader(), isSimulatedData: { false })
        let unsupported = PhoneWatchRelay(appModel: appModel, publisher: publisher, defaults: defaults, session: nil)

        unsupported.activate()
        unsupported.recheck()
        unsupported.settingsDidChange()

        XCTAssertEqual(unsupported.watchState, .unsupported)
        XCTAssertFalse(unsupported.isSupported)
    }
}

/// A WatchConnectivity session whose readings and callbacks the test decides.
@MainActor
final class ScriptedPhoneWatchSession: PhoneWatchSession {
    var onEvent: (@MainActor (PhoneWatchSessionEvent) -> Void)?
    var onRefreshRequest: (@MainActor () async -> [String: Any])?
    var reading: PhoneWatchSessionReading = .notActivated
    var failsUpdates = false
    private(set) var activateCount = 0
    private(set) var handedOver: [WatchSyncPayload] = []

    func activate() {
        activateCount += 1
    }

    func updateApplicationContext(_ context: [String: Any]) throws {
        if failsUpdates { throw NSError(domain: "WCErrorDomain", code: 7006) }
        if let payload = WatchSyncCoding.payload(from: context) { handedOver.append(payload) }
    }

    func transferComplicationUserInfo(_ userInfo: [String: Any]) -> Bool {
        false
    }

    /// Changes the reading, then calls back — as WatchConnectivity does.
    func deliver(_ event: PhoneWatchSessionEvent, _ reading: PhoneWatchSessionReading) {
        self.reading = reading
        onEvent?(event)
    }
}
