import XCTest
@testable import PogoHome

/// End-to-end coverage of the actual field regression: `AppModel` + `LiveSensorDataSource`
/// wired together (as the real app wires them), driven through a full
/// connect → Linux-service-restart → empty-registry → partial-then-full-recovery cycle with
/// no app restart in between — exactly the flow that was broken.
@MainActor
final class LiveReconnectIntegrationTests: XCTestCase {
    private let endpoint = PogoAPIEndpoint(baseURL: URL(string: "http://test.local")!)

    func testFullSnapshotDisconnectEmptyGETThenSSERecoveryWithoutAppRestart() async throws {
        let transport = ControllableSensorAPITransport { PogoAPIFixtures.fullSnapshotJSON() }
        let source = LiveSensorDataSource(
            endpoint: endpoint,
            transport: transport,
            sleeper: RecordingSleeper(),
            // Generous on purpose: this test drives every disconnect explicitly (it isn't
            // testing the watchdog itself — see SSELivenessWatchdogTests for that).
            livenessIdleTimeout: 5
        )
        let model = AppModel(dataSource: source)
        model.start()

        // 1) Initial connect: two real modules, SSE opens and delivers activity.
        try await waitUntil { model.snapshot.modules.count == 2 }
        try await waitUntil { await transport.hasOpenEventStream }
        await transport.sendLine(": heartbeat")
        try await waitUntil { model.connectionStatus == .connected }
        XCTAssertEqual(model.health, .healthy)

        // 2) Prime the *next* GET to return an empty registry (as a just-restarted Linux
        // service would), then simulate the Linux service going down.
        await transport.setSnapshotProvider { PogoAPIFixtures.snapshotJSON(schemaVersion: 1) }
        let sessionsBeforeRestart = await transport.eventStreamOpenCount
        await transport.finishCurrentEventStream()

        try await waitUntil { model.connectionStatus != .connected }
        XCTAssertEqual(model.snapshot.modules.count, 2, "the last good snapshot must stay on screen while reconnecting")
        XCTAssertEqual(model.health, .reconnecting)

        // 3) The reconnect loop's GET lands on the empty registry — this must never clear
        // the screen, only `connectionStatus`/`health` may say "still recovering".
        try await waitUntil { await transport.snapshotFetchCount >= 2 }
        XCTAssertEqual(model.snapshot.modules.count, 2, "a transient empty registry must never clear the last good snapshot")
        XCTAssertNotEqual(model.health, .healthy)

        // 4) Registry recovers: a topology-only strict subset must not replace the last
        // complete state or claim healthy; the full set is applied once it returns.
        try await waitUntil { await transport.hasOpenEventStream(after: sessionsBeforeRestart) }
        await transport.sendLines(PogoAPIFixtures.sseSnapshotEvent(json: PogoAPIFixtures.snapshotJSON(moduleUUID: PogoAPIFixtures.sgp41UUID)))
        try await waitUntil { model.isRegistryRecovering }
        try await waitUntil { model.connectionStatus == .connected }
        XCTAssertEqual(model.snapshot.modules.count, 2)
        XCTAssertEqual(model.health, .recoveringRegistry)

        await transport.sendLines(PogoAPIFixtures.sseSnapshotEvent(json: PogoAPIFixtures.fullSnapshotJSON()))
        try await waitUntil { !model.isRegistryRecovering && model.snapshot.modules.count == 2 }

        // 5) Fully recovered, no app restart happened anywhere in this test.
        XCTAssertEqual(model.health, .healthy)

        model.stop()
    }

    func testReconnectDeliversPartialThenFullModuleRecoveryInOrder() async throws {
        // Starts already "mid-recovery": the registry is empty on the very first GET, like
        // catching a Linux restart already in progress.
        let transport = ControllableSensorAPITransport { PogoAPIFixtures.snapshotJSON(schemaVersion: 1) }
        let source = LiveSensorDataSource(endpoint: endpoint, transport: transport, sleeper: RecordingSleeper(), livenessIdleTimeout: 5)
        let model = AppModel(dataSource: source)
        model.start()

        try await waitUntil { await transport.hasOpenEventStream }
        XCTAssertEqual(model.snapshot.modules.count, 0)
        XCTAssertEqual(model.health, .waitingForData)

        await transport.sendLines(PogoAPIFixtures.sseSnapshotEvent(json: PogoAPIFixtures.snapshotJSON(moduleUUID: PogoAPIFixtures.sgp41UUID)))
        try await waitUntil { model.snapshot.modules.count == 1 }
        XCTAssertEqual(model.connectionStatus, .connected)
        XCTAssertEqual(model.health, .waitingForData)

        await transport.sendLines(PogoAPIFixtures.sseSnapshotEvent(json: PogoAPIFixtures.fullSnapshotJSON()))
        try await waitUntil { model.snapshot.modules.count == 2 }
        XCTAssertEqual(model.health, .healthy)

        model.stop()
    }

    /// The exact real-device failure that previously required an app force quit — and the
    /// exact "센서 정보를 다시 확인하고 있습니다" grey banner reported in the field: SSE stays
    /// technically `.connected` (heartbeats keep arriving, so `HomeHealthEvaluator` can even
    /// reach `.recoveringRegistry` at all — it requires `connectionStatus == .connected` as a
    /// precondition), but the server never again emits a later `event: snapshot` once the
    /// registry becomes complete. Recovery must not depend on that event — `AppModel`'s
    /// independent periodic refresh (wired here with a short interval so the test doesn't
    /// wait multiple real seconds) is what converges it.
    func testPeriodicRefreshCompletesRecoveryWhenServerEmitsHeartbeatsButNoLaterSnapshotEvent() async throws {
        let transport = ControllableSensorAPITransport { PogoAPIFixtures.fullSnapshotJSON() }
        let source = LiveSensorDataSource(
            endpoint: endpoint,
            transport: transport,
            sleeper: RecordingSleeper(),
            livenessIdleTimeout: 5,
            periodicRefreshInterval: 0.03
        )
        let model = AppModel(dataSource: source)
        model.start()

        try await waitUntil { model.snapshot.modules.count == 2 }
        try await waitUntil { await transport.hasOpenEventStream }
        await transport.sendLine(": heartbeat")
        try await waitUntil { model.connectionStatus == .connected }
        XCTAssertEqual(model.health, .healthy)

        // The service restarts. Its first reconnect GET contains only topology for one
        // module, and this time it never emits a later `event: snapshot` after the registry
        // becomes complete again — only its normal heartbeat, forever.
        await transport.setSnapshotProvider {
            PogoAPIFixtures.snapshotJSON(moduleUUID: PogoAPIFixtures.sgp41UUID)
        }
        let sessionsBeforeRestart = await transport.eventStreamOpenCount
        await transport.finishCurrentEventStream()

        // Wait for the *reconnected* session: the finished one can still look open until its
        // termination callback runs, and a heartbeat sent to it would be silently dropped.
        try await waitUntil { await transport.hasOpenEventStream(after: sessionsBeforeRestart) }
        await transport.sendLine(": heartbeat")
        try await waitUntil { model.isRegistryRecovering && model.connectionStatus == .connected }
        XCTAssertEqual(model.snapshot.modules.count, 2, "last complete values stay visible during recovery")
        XCTAssertEqual(model.health, .recoveringRegistry)

        // Linux now has the complete registry. Heartbeats keep coming (connection status
        // never has a reason to drop), but no `snapshot` event ever does — only the
        // independent periodic GET can observe the recovered registry.
        await transport.setSnapshotProvider { PogoAPIFixtures.fullSnapshotJSON() }
        await transport.sendLine(": heartbeat")

        try await waitUntil(timeout: 3) { !model.isRegistryRecovering && model.health == .healthy }
        XCTAssertEqual(model.snapshot.modules.count, 2)

        model.stop()
    }
}
