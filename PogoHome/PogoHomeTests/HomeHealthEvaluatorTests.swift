import XCTest
@testable import PogoHome

final class HomeHealthEvaluatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var freshSync: Date { now.addingTimeInterval(-1) }
    private var staleSync: Date { now.addingTimeInterval(-1000) }

    private func snapshot(modules: [SensorModule]) -> HomeSnapshot {
        HomeSnapshot(timestamp: now, rooms: [], modules: modules)
    }

    private func module(online: Bool = true, needsAttention: Bool = false, hasReadings: Bool = true) -> SensorModule {
        let readings: [SensorReading]
        if !hasReadings {
            readings = []
        } else if needsAttention {
            readings = [SensorReading(kind: .temperature, value: 1, timestamp: now, status: .error)]
        } else {
            readings = [SensorReading(kind: .temperature, value: 22, timestamp: now, status: .normal)]
        }
        return SensorModule(
            id: UUID(),
            name: "m",
            roomID: UUID(),
            readings: readings,
            isOnline: online,
            lastSeen: now
        )
    }

    func testNeverReceivedAnyModuleIsWaitingForDataEvenWhenConnected() {
        let state = HomeHealthEvaluator.evaluate(
            snapshot: snapshot(modules: []),
            connectionStatus: .connected,
            lastSyncAt: freshSync,
            now: now
        )
        XCTAssertEqual(state, .waitingForData)
    }

    func testEmptyModulesIsNeverHealthyRegardlessOfConnectionStatus() {
        let statuses: [DataSourceConnectionStatus] = [.connected, .idle, .connecting, .reconnecting(attempt: 1), .failed("x")]
        for status in statuses {
            let state = HomeHealthEvaluator.evaluate(snapshot: snapshot(modules: []), connectionStatus: status, lastSyncAt: freshSync, now: now)
            XCTAssertNotEqual(state, .healthy, "\(status) must never be reported healthy with zero modules")
        }
    }

    func testDisconnectedStatusesShowReconnectingNotHealthyWhenAGoodSnapshotExists() {
        let statuses: [DataSourceConnectionStatus] = [.idle, .connecting, .reconnecting(attempt: 2), .failed("down")]
        for status in statuses {
            let state = HomeHealthEvaluator.evaluate(snapshot: snapshot(modules: [module()]), connectionStatus: status, lastSyncAt: freshSync, now: now)
            XCTAssertEqual(state, .reconnecting, "\(status) with a previously-good snapshot must show as reconnecting, not healthy")
        }
    }

    func testHealthyRequiresConnectedFreshAndAllModulesClean() {
        let state = HomeHealthEvaluator.evaluate(
            snapshot: snapshot(modules: [module(), module()]),
            connectionStatus: .connected,
            lastSyncAt: freshSync,
            now: now
        )
        XCTAssertEqual(state, .healthy)
    }

    func testOnlineModuleWithoutReadingsIsWaitingForDataNotHealthy() {
        let state = HomeHealthEvaluator.evaluate(
            snapshot: snapshot(modules: [module(hasReadings: false)]),
            connectionStatus: .connected,
            lastSyncAt: freshSync,
            now: now
        )
        XCTAssertEqual(state, .waitingForData)
    }

    func testRegistryRecoveryCannotBeHealthyEvenWithLastCompleteSnapshotVisible() {
        let state = HomeHealthEvaluator.evaluate(
            snapshot: snapshot(modules: [module(), module()]),
            connectionStatus: .connected,
            lastSyncAt: freshSync,
            isRegistryRecovering: true,
            now: now
        )
        XCTAssertEqual(state, .recoveringRegistry)
        XCTAssertFalse(state.isCurrentStateVerified)
    }

    func testOnlyHealthyAndAttentionStatesHaveVerifiedCurrentState() {
        XCTAssertTrue(HomeHealthState.healthy.isCurrentStateVerified)
        XCTAssertTrue(HomeHealthState.attentionNeeded.isCurrentStateVerified)
        XCTAssertFalse(HomeHealthState.waitingForData.isCurrentStateVerified)
        XCTAssertFalse(HomeHealthState.reconnecting.isCurrentStateVerified)
        XCTAssertFalse(HomeHealthState.recoveringRegistry.isCurrentStateVerified)
    }

    func testAttentionNeededReadingIsNotHealthyEvenWhenConnectedAndFresh() {
        let state = HomeHealthEvaluator.evaluate(
            snapshot: snapshot(modules: [module(needsAttention: true)]),
            connectionStatus: .connected,
            lastSyncAt: freshSync,
            now: now
        )
        XCTAssertEqual(state, .attentionNeeded)
    }

    func testOfflineModuleIsAttentionNeededNotHealthy() {
        let state = HomeHealthEvaluator.evaluate(
            snapshot: snapshot(modules: [module(online: false)]),
            connectionStatus: .connected,
            lastSyncAt: freshSync,
            now: now
        )
        XCTAssertEqual(state, .attentionNeeded)
    }

    func testStaleSyncDegradesToReconnectingEvenIfStatusStillClaimsConnected() {
        // Defense-in-depth: a `connectionStatus` of `.connected` isn't trusted forever — if
        // nothing has actually synced within the freshness window, `health` must not report
        // `.healthy`. This is the backstop `SSELivenessWatchdog` is expected to make moot in
        // practice, but `health` doesn't rely on that alone.
        let state = HomeHealthEvaluator.evaluate(
            snapshot: snapshot(modules: [module()]),
            connectionStatus: .connected,
            lastSyncAt: staleSync,
            now: now,
            freshnessWindow: 60
        )
        XCTAssertEqual(state, .reconnecting)
    }

    func testNilLastSyncWithNoDataIsWaitingForData() {
        let state = HomeHealthEvaluator.evaluate(snapshot: snapshot(modules: []), connectionStatus: .idle, lastSyncAt: nil, now: now)
        XCTAssertEqual(state, .waitingForData)
    }

    // MARK: - A Power Base's own state

    func testAPowerBasesStateIsKnownFromALiveFreshConnectionWithoutAnySensor() {
        // No sensor at all, or one without a first reading: the home is waiting for data, and
        // stays so -- but what the hub says about a Base is current.
        for modules in [[], [module(hasReadings: false)]] {
            XCTAssertEqual(HomeHealthEvaluator.evaluate(snapshot: snapshot(modules: modules), connectionStatus: .connected, lastSyncAt: freshSync, now: now), .waitingForData)
        }
        XCTAssertTrue(HomeHealthEvaluator.isPowerBaseStateVerified(connectionStatus: .connected, lastSyncAt: freshSync, isHoldingBackSensorData: false, now: now))
    }

    func testAPowerBasesStateIsNotKnownWithoutALiveFreshConnectionOrWhileSensorsAreHeldBack() {
        let notConnected: [DataSourceConnectionStatus] = [.idle, .connecting, .reconnecting(attempt: 1), .failed("down")]
        for status in notConnected {
            XCTAssertFalse(HomeHealthEvaluator.isPowerBaseStateVerified(connectionStatus: status, lastSyncAt: freshSync, isHoldingBackSensorData: false, now: now), "\(status)")
        }
        XCTAssertFalse(HomeHealthEvaluator.isPowerBaseStateVerified(connectionStatus: .connected, lastSyncAt: staleSync, isHoldingBackSensorData: false, now: now), "nothing received recently")
        XCTAssertFalse(HomeHealthEvaluator.isPowerBaseStateVerified(connectionStatus: .connected, lastSyncAt: nil, isHoldingBackSensorData: false, now: now), "nothing received at all")
        XCTAssertFalse(HomeHealthEvaluator.isPowerBaseStateVerified(connectionStatus: .connected, lastSyncAt: freshSync, isHoldingBackSensorData: true, now: now),
                       "the Bases on screen are the last confirmed ones, not the hub's latest")
    }
}
