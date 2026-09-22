import XCTest
@testable import PogoHome

@MainActor
final class LiveSensorDataSourceTests: XCTestCase {
    private let endpoint = PogoAPIEndpoint(baseURL: URL(string: "http://test.local")!)

    // MARK: - currentSnapshot()

    func testCurrentSnapshotFetchesAndDecodesImmediately() async throws {
        let transport = ScriptedSensorAPITransport(
            snapshotScript: [.success(PogoAPIFixtures.fullSnapshotJSON())],
            eventScript: []
        )
        let source = LiveSensorDataSource(endpoint: endpoint, transport: transport, sleeper: RecordingSleeper())
        let snapshot = try await source.currentSnapshot()
        XCTAssertEqual(snapshot.modules.count, 2)
        let fetches = await transport.snapshotFetchCount
        XCTAssertEqual(fetches, 1)
    }

    // MARK: - SSE snapshot events replace state atomically; heartbeats never trigger a fetch

    /// A heartbeat only proves the SSE socket is alive — registry-recovery convergence when
    /// no later `snapshot` event ever arrives is `AppModel`'s independent periodic-refresh
    /// job (see `AppModelPeriodicRefreshTests`), not this type's. This is a regression test
    /// for an earlier version of `LiveSensorDataSource` that re-fetched on every heartbeat:
    /// that never reliably converged on real hardware and doubled snapshot-fetch load on the
    /// server for no benefit, so it's gone — heartbeats must not cause any extra GET.
    func testSSESnapshotEventReplacesStateAndHeartbeatsTriggerNoExtraFetch() async throws {
        let initialJSON = PogoAPIFixtures.fullSnapshotJSON()
        let updatedJSON = PogoAPIFixtures.snapshotJSON(moduleUUID: PogoAPIFixtures.sgp41UUID)

        let transport = ScriptedSensorAPITransport(
            snapshotScript: [.success(initialJSON)],
            eventScript: [
                ScriptedSensorAPITransport.EventSession(
                    lines: [": heartbeat"] + PogoAPIFixtures.sseSnapshotEvent(json: updatedJSON) + [": heartbeat"],
                    ending: .finish
                ),
            ]
        )
        let sleeper = RecordingSleeper()
        await sleeper.setMaxSleeps(0) // stop the loop after it tries to reconnect once more
        let source = LiveSensorDataSource(endpoint: endpoint, transport: transport, sleeper: sleeper)

        let task = Task { () -> [HomeSnapshot] in
            var collected: [HomeSnapshot] = []
            for await snapshot in source.updates() {
                collected.append(snapshot)
            }
            return collected
        }
        let collected = await task.value

        XCTAssertEqual(collected.count, 2, "expected only the initial GET and the one SSE snapshot event — no heartbeat-triggered fetches")
        XCTAssertEqual(collected[0].modules.count, 2, "initial snapshot should have both real modules")
        XCTAssertEqual(collected[1].modules.count, 1, "SSE event should have atomically replaced state with the new snapshot")
        let fetches = await transport.snapshotFetchCount
        XCTAssertEqual(fetches, 1, "heartbeats must never trigger an extra snapshot GET")
    }

    func testMalformedSSEEventIsDroppedWithoutEndingTheConnection() async throws {
        let goodJSON = PogoAPIFixtures.snapshotJSON(moduleUUID: "1122334455667788")
        let transport = ScriptedSensorAPITransport(
            snapshotScript: [.success(PogoAPIFixtures.fullSnapshotJSON())],
            eventScript: [
                ScriptedSensorAPITransport.EventSession(
                    lines: ["event: snapshot", "data: { not valid json", ""] + PogoAPIFixtures.sseSnapshotEvent(json: goodJSON),
                    ending: .finish
                ),
            ]
        )
        let sleeper = RecordingSleeper()
        await sleeper.setMaxSleeps(0)
        let source = LiveSensorDataSource(endpoint: endpoint, transport: transport, sleeper: sleeper)

        let task = Task { () -> [HomeSnapshot] in
            var collected: [HomeSnapshot] = []
            for await snapshot in source.updates() {
                collected.append(snapshot)
            }
            return collected
        }
        let collected = await task.value

        // Initial GET + the one good SSE event; the malformed event in between was dropped.
        XCTAssertEqual(collected.count, 2)
    }

    // MARK: - Reconnect backoff is bounded, not a busy loop

    func testReconnectBackoffIncreasesAndIsBoundedWhenServerIsUnreachable() async throws {
        let transport = ScriptedSensorAPITransport(
            snapshotScript: [.failure(PogoAPIError.transport("connection refused"))],
            eventScript: []
        )
        let sleeper = RecordingSleeper()
        await sleeper.setMaxSleeps(3)
        let source = LiveSensorDataSource(endpoint: endpoint, transport: transport, sleeper: sleeper)

        var receivedAnything = false
        for await _ in source.updates() { receivedAnything = true }

        XCTAssertFalse(receivedAnything)
        let delays = await sleeper.recordedDelays
        XCTAssertEqual(delays, [1, 2, 4, 8])
        let fetchCount = await transport.snapshotFetchCount
        XCTAssertEqual(fetchCount, 4, "one fetch attempt per reconnect try, not a tight busy loop")
    }

    // MARK: - Cancellation stops reconnecting

    func testCancellingConsumingTaskStopsFurtherReconnectAttempts() async throws {
        let transport = ScriptedSensorAPITransport(
            snapshotScript: [.failure(PogoAPIError.transport("down"))],
            eventScript: []
        )
        let source = LiveSensorDataSource(endpoint: endpoint, transport: transport, sleeper: RecordingSleeper())

        let task = Task {
            for await _ in source.updates() {}
        }

        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        try? await Task.sleep(for: .milliseconds(50))
        let countAfterCancel = await transport.snapshotFetchCount

        try? await Task.sleep(for: .milliseconds(150))
        let countLater = await transport.snapshotFetchCount

        XCTAssertEqual(countAfterCancel, countLater, "fetches continued after the consuming task was cancelled")
    }

    // MARK: - No duplicate SSE connections

    func testSupersedingUpdatesCallDoesNotLeaveTwoLiveConnections() async throws {
        let transport = ScriptedSensorAPITransport(
            snapshotScript: [.success(PogoAPIFixtures.fullSnapshotJSON())],
            eventScript: [ScriptedSensorAPITransport.EventSession(lines: [], ending: .finish)]
        )
        let sleeper = RecordingSleeper()
        await sleeper.setMaxSleeps(0)
        let source = LiveSensorDataSource(endpoint: endpoint, transport: transport, sleeper: sleeper)

        _ = source.updates() // starts a reconnect loop that nobody consumes

        let task = Task { () -> [HomeSnapshot] in
            var collected: [HomeSnapshot] = []
            for await snapshot in source.updates() { // supersedes the loop above
                collected.append(snapshot)
                if collected.count == 1 { break }
            }
            return collected
        }
        let collected = await task.value
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(collected.count, 1)
        let opens = await transport.eventStreamOpenCount
        XCTAssertLessThanOrEqual(opens, 2, "a superseded loop must not keep opening SSE connections indefinitely")
    }

    // MARK: - Connection status

    func testConnectionStatusReportsConnectingThenConnected() async throws {
        // A GET succeeding alone must never report `.connected` (see
        // `testConnectedIsNotReportedUntilSSEConnectionActuallyOpensAndDeliversALine` below)
        // — this session needs at least one SSE line before `.connected` can appear.
        let transport = ScriptedSensorAPITransport(
            snapshotScript: [.success(PogoAPIFixtures.fullSnapshotJSON())],
            eventScript: [ScriptedSensorAPITransport.EventSession(lines: [": heartbeat"], ending: .finish)]
        )
        let sleeper = RecordingSleeper()
        await sleeper.setMaxSleeps(0)
        let source = LiveSensorDataSource(endpoint: endpoint, transport: transport, sleeper: sleeper)

        var observedStatuses: [DataSourceConnectionStatus] = []
        let statusTask = Task {
            for await status in source.connectionStatusUpdates() {
                observedStatuses.append(status)
            }
        }

        // Give the status subscription a moment to register before the update loop starts
        // publishing, so the first `.connecting` status isn't missed by a race.
        try? await Task.sleep(for: .milliseconds(20))

        // `for await _ in source.updates() { break }` used to be safe here because the old
        // (buggy) implementation published `.connected` synchronously right after the GET,
        // before a `break`'s implicit stream teardown could cancel anything. Now that
        // `.connected` only follows real SSE activity, breaking immediately would let ARC
        // deallocate the discarded stream's continuation — firing `onTermination` and
        // cancelling the reconnect loop's Task before it ever opens the SSE connection — so
        // `.connected` would never arrive and the unbounded status wait below would hang the
        // whole suite. Keep the stream alive and actively consumed for the entire test
        // instead, and bound every wait so a future regression fails fast instead of hanging.
        let updatesStream = source.updates()
        let updatesTask = Task {
            for await _ in updatesStream {}
        }
        defer {
            statusTask.cancel()
            updatesTask.cancel()
        }

        try await waitUntil(timeout: 3) { observedStatuses.contains(.connected) }

        XCTAssertTrue(observedStatuses.contains(.connecting))
        XCTAssertTrue(observedStatuses.contains(.connected))
    }

    /// The regression this whole milestone started from: a successful `GET /snapshot` alone
    /// must never be reported as `.connected` — only real SSE activity (opened connection +
    /// at least one line) can.
    func testConnectedIsNotReportedUntilSSEConnectionActuallyOpensAndDeliversALine() async throws {
        let transport = ControllableSensorAPITransport { PogoAPIFixtures.fullSnapshotJSON() }
        let source = LiveSensorDataSource(endpoint: endpoint, transport: transport, sleeper: RecordingSleeper())

        var observedStatuses: [DataSourceConnectionStatus] = []
        let statusTask = Task {
            for await status in source.connectionStatusUpdates() {
                observedStatuses.append(status)
            }
        }
        try? await Task.sleep(for: .milliseconds(20)) // let the subscription register first

        // Kicks off the GET + SSE-open sequence. `AsyncStream`'s build closure runs
        // eagerly (so the reconnect loop starts here, not on first consumption) but its
        // backing continuation is torn down — cancelling that loop — as soon as nothing
        // retains the returned stream, so this deliberately keeps `updatesStream` alive for
        // the rest of the test even though nothing ever iterates it.
        let updatesStream = source.updates()

        try await waitUntil { await transport.hasOpenEventStream }
        try? await Task.sleep(for: .milliseconds(30)) // give a (buggy) premature publish a chance to land

        XCTAssertTrue(observedStatuses.contains(.connecting))
        XCTAssertFalse(
            observedStatuses.contains(.connected),
            "a successful GET plus an opened-but-silent SSE connection must not be reported as connected"
        )

        await transport.sendLine(": heartbeat")
        try await waitUntil { observedStatuses.contains(.connected) }

        statusTask.cancel()
        _ = updatesStream
    }

    func testConnectionDropsToReconnectingAssoonAsSSEStreamEnds() async throws {
        let transport = ControllableSensorAPITransport { PogoAPIFixtures.fullSnapshotJSON() }
        let source = LiveSensorDataSource(endpoint: endpoint, transport: transport, sleeper: RecordingSleeper())

        var observedStatuses: [DataSourceConnectionStatus] = []
        let statusTask = Task {
            for await status in source.connectionStatusUpdates() {
                observedStatuses.append(status)
            }
        }
        try? await Task.sleep(for: .milliseconds(20))
        let updatesStream = source.updates() // kept alive for the same reason as above

        try await waitUntil { await transport.hasOpenEventStream }
        await transport.sendLine(": heartbeat")
        try await waitUntil { observedStatuses.contains(.connected) }

        await transport.finishCurrentEventStream() // the server closed the connection
        try await waitUntil { observedStatuses.last != .connected }

        statusTask.cancel()
        _ = updatesStream
    }
}
