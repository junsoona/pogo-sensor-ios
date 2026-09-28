import XCTest
@testable import PogoHome

/// The app side end to end: real `AppModel` and `AppleHomeModel`, a scripted data source and
/// HomeKit provider, and a fake store/WidgetKit — what reaches the widgets, and when.
@MainActor
final class HomeGlancePublisherTests: XCTestCase {
    private typealias F = GlanceFixtures

    private var dataSource: GlanceTestDataSource!
    private var appModel: AppModel!
    private var provider: ScriptedAppleHomeProvider!
    private var appleHome: AppleHomeModel!
    private var store: InMemoryGlanceStore!
    private var reloader: CountingReloader!
    private var clock = Date()
    private var publisher: HomeGlancePublisher!

    override func setUp() async throws {
        dataSource = GlanceTestDataSource()
        // The hub the stored glances of these tests come from, as the app is set up at launch.
        appModel = AppModel(dataSource: dataSource, sourceIdentity: F.hubSource, configurationStore: InMemoryHomeConfigurationStore(rooms: [F.room], language: .korean), language: .korean)
        provider = ScriptedAppleHomeProvider(snapshot: AppleHomeFixtures.ready([AppleHomeFixtures.light(), AppleHomeFixtures.sensor()]))
        appleHome = AppleHomeModel(provider: provider, defaults: makeIsolatedDefaults())
        store = InMemoryGlanceStore()
        reloader = CountingReloader()
        clock = Date()
        makePublisher()
    }

    private func makePublisher() {
        publisher = HomeGlancePublisher(
            appModel: appModel,
            appleHome: appleHome,
            store: store,
            reloader: reloader,
            isSimulatedData: { false },
            now: { [unowned self] in self.clock },
            // Tests evaluate explicitly.
            debounce: .seconds(3600)
        )
    }

    private func deliver(_ modules: [SensorModule], status: DataSourceConnectionStatus = .connected) async throws {
        let syncedBefore = appModel.lastSyncAt
        dataSource.send(status: status)
        dataSource.send(F.home(modules))
        try await waitUntil { self.appModel.connectionStatus == status && self.appModel.lastSyncAt != syncedBefore }
    }

    private var stored: HomeGlanceSnapshot? { store.snapshot }

    // MARK: -

    func testConnectedDataAndReadableAppleHomeReachTheWidgets() async throws {
        appModel.start()
        appleHome.enable()
        try await deliver([F.climate(), F.air()])
        publisher.resume()

        let glance = try XCTUnwrap(stored)
        XCTAssertEqual(glance.pogo.state, .healthy)
        XCTAssertEqual(glance.pogoSensors.count, 3)
        XCTAssertEqual(glance.appleHome.access, .ready)
        XCTAssertNotNil(glance.sensor(with: F.appleHomeTemperatureID))
        XCTAssertEqual(reloader.count, 1)
    }

    func testRevokingAppleHomeClearsItsValuesAtOnceAndKeepsPogo() async throws {
        appModel.start()
        appleHome.enable()
        try await deliver([F.climate()])
        publisher.resume()
        let before = try XCTUnwrap(stored)
        XCTAssertFalse(before.appleHomeSensors.isEmpty)

        clock += 1
        provider.publish(AppleHomeSnapshot(accessState: .denied))
        publisher.evaluate()

        let after = try XCTUnwrap(stored)
        XCTAssertEqual(after.appleHome.access, .denied)
        XCTAssertTrue(after.appleHomeSensors.isEmpty)
        XCTAssertEqual(after.pogo, before.pogo)
        XCTAssertEqual(after.pogoSensors, before.pogoSensors)
        XCTAssertEqual(reloader.count, 2, "no rate limit for this one")
        XCTAssertEqual(after.sensorLookup(F.appleHomeTemperatureID, at: clock), .sourceUnavailable(.denied))
    }

    func testSwitchingTheDataSourceTakesThePreviousSourcesValuesOffTheWidgetsAtOnce() async throws {
        appModel.start()
        appleHome.enable()
        try await deliver([F.climate(), F.air()])
        publisher.resume()
        let before = try XCTUnwrap(stored)
        XCTAssertFalse(before.pogoSensors.isEmpty)
        let reloadsBefore = reloader.count

        // Seconds later — well inside the state-change reload interval.
        clock += 5
        let hub = SensorSourceIdentity.hub(URL(string: "http://other.local:8787")!)
        let next = GlanceTestDataSource()
        appModel.replace(dataSource: next, identity: hub)
        next.send(status: .failed("unreachable"))
        try await waitUntil { self.appModel.connectionStatus == .failed("unreachable") }
        publisher.evaluate()

        let after = try XCTUnwrap(stored)
        XCTAssertEqual(after.pogoSensors, [])
        XCTAssertEqual(after.pogo.moduleCount, 0)
        XCTAssertEqual(after.pogo.state, .waitingForData)
        XCTAssertEqual(after.pogo.sourceID, hub.rawValue)
        XCTAssertEqual(after.appleHome.access, .ready)
        XCTAssertEqual(after.appleHomeSensors, before.appleHomeSensors, "Apple Home values are not the POGO source's")
        XCTAssertEqual(reloader.count, reloadsBefore + 1, "reloaded now, not after the state reload interval")
        // What the Watch is handed on a settings change.
        XCTAssertEqual(publisher.latestSnapshot()?.pogoSensors, [])
    }

    func testTurningAppleHomeOffInPogoHomeClearsItsValues() async throws {
        appModel.start()
        appleHome.enable()
        try await deliver([F.climate()])
        publisher.resume()

        clock += 1
        appleHome.disable()
        publisher.evaluate()

        XCTAssertEqual(stored?.appleHome.access, .off)
        XCTAssertEqual(stored?.appleHomeSensors, [])
        XCTAssertEqual(stored?.pogoSensors.isEmpty, false)
    }

    func testGoingToTheBackgroundFlushesTheLastConfirmedStateAndStoppingIsNotAFailure() async throws {
        appModel.start()
        try await deliver([F.climate()])
        publisher.resume()
        let reloadsBefore = reloader.count

        // A while later, more confirmations arrived (minor: not written yet).
        clock += 30
        try await deliver([F.climate(temperature: 23.5)])
        publisher.evaluate()
        let lastSync = try XCTUnwrap(appModel.lastSyncAt)

        // The app's order on leaving the foreground.
        publisher.suspend()
        appModel.stop()
        XCTAssertEqual(appModel.connectionStatus, .idle)
        publisher.evaluate()

        let glance = try XCTUnwrap(stored)
        XCTAssertEqual(glance.pogo.state, .healthy, "stopping in the background isn't a lost connection")
        XCTAssertEqual(glance.pogo.verifiedAt, lastSync)
        XCTAssertEqual(glance.sensor(with: F.temperatureID)?.value, 23.5)
        XCTAssertEqual(reloader.count, reloadsBefore + 1)
    }

    func testRelaunchingKeepsTheStoredStateUntilTheBridgeAnswers() async throws {
        // A previous app session left this behind.
        let previous = F.build(
            pogo: F.pogoInput(F.home([F.climate()]), lastSyncAt: clock.addingTimeInterval(-600), sessionStartedAt: clock.addingTimeInterval(-700)),
            appleHome: F.appleHomeInput(isEnabled: false),
            now: clock.addingTimeInterval(-600)
        )
        store.snapshot = previous
        XCTAssertEqual(previous.pogo.state, .healthy)

        appModel.start()
        dataSource.send(status: .connecting)
        try await waitUntil { self.appModel.connectionStatus == .connecting }
        publisher.resume()

        XCTAssertEqual(stored?.pogo, previous.pogo)
        XCTAssertEqual(stored?.pogoSensors, previous.pogoSensors)
        XCTAssertEqual(reloader.count, 0, "nothing the widgets show changed")

        // The bridge can't be reached in this session: same values, no longer confirmed.
        clock += 5
        dataSource.send(status: .reconnecting(attempt: 1))
        try await waitUntil { self.appModel.connectionStatus == .reconnecting(attempt: 1) }
        publisher.evaluate()
        XCTAssertEqual(stored?.pogo.state, .unverified)
        XCTAssertEqual(stored?.pogo.verifiedAt, previous.pogo.verifiedAt)
        XCTAssertEqual(stored?.pogoSensors, previous.pogoSensors)
    }

    func testADetachedModulesValueDisappearsForItsWidget() async throws {
        appModel.start()
        try await deliver([F.climate(), F.air()])
        publisher.resume()
        XCTAssertNotNil(stored?.sensor(with: F.temperatureID))

        clock += 120
        try await deliver([F.air()])
        publisher.evaluate()
        XCTAssertEqual(stored?.sensorLookup(F.temperatureID, at: clock), .missing)
    }

    func testNothingIsWrittenWhileSuspended() async throws {
        appModel.start()
        try await deliver([F.climate()])
        publisher.resume()
        publisher.suspend()
        let writes = store.saveCount

        clock += 3600
        try await deliver([F.air()])
        publisher.evaluate()
        XCTAssertEqual(store.saveCount, writes)
    }
}

// MARK: - Fakes

final class InMemoryGlanceStore: HomeGlanceStoring, @unchecked Sendable {
    var snapshot: HomeGlanceSnapshot?
    private(set) var saveCount = 0

    func load() -> HomeGlanceStore.LoadResult {
        snapshot.map(HomeGlanceStore.LoadResult.snapshot) ?? .missing
    }

    func save(_ snapshot: HomeGlanceSnapshot) throws {
        saveCount += 1
        self.snapshot = snapshot
    }
}

@MainActor
final class CountingReloader: HomeGlanceReloading {
    private(set) var count = 0
    func reloadWidgets() { count += 1 }
}

/// Snapshots and connection states pushed by the test.
@MainActor
private final class GlanceTestDataSource: SensorDataSource {
    private var snapshotContinuation: AsyncStream<HomeSnapshot>.Continuation?
    private var statusContinuation: AsyncStream<DataSourceConnectionStatus>.Continuation?
    private var pendingSnapshots: [HomeSnapshot] = []
    private var pendingStatuses: [DataSourceConnectionStatus] = []

    func currentSnapshot() async throws -> HomeSnapshot {
        HomeSnapshot(timestamp: Date(), rooms: [], modules: [])
    }

    func updates() -> AsyncStream<HomeSnapshot> {
        AsyncStream { continuation in
            snapshotContinuation = continuation
            pendingSnapshots.forEach { continuation.yield($0) }
            pendingSnapshots = []
        }
    }

    func connectionStatusUpdates() -> AsyncStream<DataSourceConnectionStatus> {
        AsyncStream { continuation in
            statusContinuation = continuation
            pendingStatuses.forEach { continuation.yield($0) }
            pendingStatuses = []
        }
    }

    func send(_ snapshot: HomeSnapshot) {
        if let snapshotContinuation { snapshotContinuation.yield(snapshot) } else { pendingSnapshots.append(snapshot) }
    }

    func send(status: DataSourceConnectionStatus) {
        if let statusContinuation { statusContinuation.yield(status) } else { pendingStatuses.append(status) }
    }
}
