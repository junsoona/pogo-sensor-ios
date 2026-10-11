import XCTest
@testable import PogoHome

/// The app follows a real hub API server **through its event stream alone**: the real `AppModel`
/// on the real `LiveSensorDataSource` and its `URLSession` transport, with the periodic `GET`
/// switched off -- so whatever the model shows after its connect answer can only have come as an
/// event -- against the Linux bridge's own `pogohome_api::Server`, `PowerBaseManagement` and
/// `ingest::Registry`, built for this Mac. Real HTTP and TLS on loopback.
///
/// The hub side is a harness that also plays the board and the other device (a Base is heard
/// from, a removal is carried out, the Base is registered again, the server is started again):
/// there is no radio, no board, no Linux and no iPhone in this, and one app instance is not two
/// phones.
///
/// Skipped unless the control directory of a running harness is given (an environment variable of
/// the `xcodebuild` process):
///
///     TEST_RUNNER_POGO_EVENTS_E2E_DIR=<directory>
///
/// The harness writes `info.json` there and answers `<n>.cmd` with `<n>.done`. The test takes
/// about forty seconds: it waits for the hub's heartbeat (every fifteen) once.
final class HubEventStreamLiveNetworkTests: XCTestCase {
    private struct Info: Decodable {
        let url: String
        let hub_id: String
        let code: String
        let fingerprint: String
        let power_base: String
    }

    private struct NoAnswer: Error {}

    @MainActor
    func testAnAppFollowsARealHubThroughItsEventStreamAlone() async throws {
        guard let directory = ProcessInfo.processInfo.environment["POGO_EVENTS_E2E_DIR"], !directory.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_POGO_EVENTS_E2E_DIR to the control directory of a running harness")
        }
        let info = try JSONDecoder().decode(Info.self, from: Data(contentsOf: URL(fileURLWithPath: directory + "/info.json")))
        let baseURL = try XCTUnwrap(URL(string: info.url))
        let base = info.power_base
        let otherBase = "744dbdfffe65d358", thirdBase = "744dbdfffe65d359"

        var commandNumber = 0
        func harness(_ word: String) async throws -> String {
            commandNumber += 1
            let command = URL(fileURLWithPath: "\(directory)/\(commandNumber).cmd")
            let done = URL(fileURLWithPath: "\(directory)/\(commandNumber).done")
            try Data((word + "\n").utf8).write(to: command, options: .atomic)
            for _ in 0..<400 {
                if let answer = try? String(contentsOf: done, encoding: .utf8) {
                    return answer.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw NoAnswer()
        }

        let settingsTransport = URLSessionHubSettingsTransport()
        let credential = try await settingsTransport.pair(
            baseURL: baseURL, hubID: info.hub_id, code: try XCTUnwrap(HubPairingCode.normalized(info.code)), deviceName: "E2E iPhone"
        )

        // No periodic GET. The watchdog's limit is between one heartbeat period (15 s) and two:
        // a connection whose heartbeats did not arrive as lines would be given up at 22 s.
        let live = LiveSensorDataSource(endpoint: PogoAPIEndpoint(baseURL: baseURL), livenessIdleTimeout: 22, periodicRefreshInterval: nil)
        XCTAssertNil(live.periodicRefreshInterval)
        let model = AppModel(
            dataSource: live, sourceIdentity: .hub(id: info.hub_id), sourceAddress: baseURL,
            configurationStore: InMemoryHomeConfigurationStore(language: .korean), language: .korean
        )
        model.start()
        defer { model.stop() }
        func listed() -> [String] { model.snapshot.powerBases.map(\.hardwareIdentifier).sorted() }
        func record(of identifier: String) -> String? { model.snapshot.powerBases.first { $0.hardwareIdentifier == identifier }?.record }

        // The connect answer, and the stream is open.
        try await waitUntil(timeout: 15) { listed() == [base] && model.connectionStatus == .connected }
        let firstRecord = try XCTUnwrap(record(of: base))

        // 1. A later event: another Base is heard from. Only an event can say so here.
        let heardB = try await harness("hear-b")
        XCTAssertEqual(heardB, "heard")
        try await waitUntil(timeout: 10) { listed() == [base, otherBase].sorted() }

        // 2. A removal and a registration, each seen as it happens.
        let binding = try XCTUnwrap(model.snapshot.powerBases.first { $0.hardwareIdentifier == base }?.removalBinding)
        let removals = URLSessionPowerBaseRemovalTransport()
        let job = try await removals.request(
            baseURL: baseURL, credential: credential, powerBaseIdentifier: base, binding: binding, requestID: PowerBaseForgetRequestID.make()
        )
        try await waitUntil(timeout: 10) { model.snapshot.powerBaseRemovals.contains { $0.id == job.id } }
        let carriedOut = try await harness("complete")
        XCTAssertEqual(carriedOut, "released")
        try await waitUntil(timeout: 10) { !listed().contains(base) }
        XCTAssertTrue(model.snapshot.powerBaseDepartures.contains { $0.powerBaseIdentifier == base }, "the hub's word that the Base is out of its list arrived with the event")
        let registered = try await harness("reregister")
        XCTAssertEqual(registered, "registered-again")
        try await waitUntil(timeout: 10) { listed().contains(base) }
        XCTAssertNotEqual(record(of: base), firstRecord, "listed again, under another registration")

        // 3. A change of the shared settings alone is an event too.
        let room = HubRoomSetting(id: UUID(), nameKind: .custom, name: "E2E", suggestionSymbol: nil, suggestionOrdinal: nil, symbol: "sofa.fill")
        let saved = try await settingsTransport.putSettings(
            baseURL: baseURL, credential: credential, baseRevision: nil,
            settings: HubSettingsDocument(homeName: "E2E", rooms: [room], modules: [])
        )
        let revision = try XCTUnwrap(saved.revision)
        try await waitUntil(timeout: 10) { model.snapshot.hubSettings?.revision == revision }

        // 4. Heartbeats. Nothing changes on the hub for longer than the watchdog's limit: the
        //    connection is kept only if the heartbeat (a comment line) came through.
        var statuses: Set<String> = []
        for _ in 0..<50 {
            statuses.insert(String(describing: model.connectionStatus))
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertEqual(statuses, ["connected"], "25 seconds without an event: the connection was not given up and not opened again")

        // 5. An answer to a GET that the hub made BEFORE an event, applied AFTER it: the real
        //    numbers of the real hub, through the app's rule. (A second data source of this app,
        //    so that the answer and the event can be held in hand.)
        let probe = LiveSensorDataSource(endpoint: PogoAPIEndpoint(baseURL: baseURL), periodicRefreshInterval: nil)
        let olderAnswer = try await probe.currentSnapshot()
        XCTAssertFalse(olderAnswer.powerBases.contains { $0.hardwareIdentifier == thirdBase })
        let heardC = try await harness("hear-c")
        XCTAssertEqual(heardC, "heard")
        try await waitUntil(timeout: 10) { listed().contains(thirdBase) }
        let afterwards = await Self.firstSnapshots(of: probe, count: 2, within: 10)
        XCTAssertEqual(afterwards.count, 2, "the probe's connect answer and its stream's first event")
        let event = try XCTUnwrap(afterwards.last)
        XCTAssertTrue(event.powerBases.contains { $0.hardwareIdentifier == thirdBase })
        var ordering = HubSnapshotOrdering()
        XCTAssertTrue(ordering.admits(event.delivery, now: SnapshotRequestClock.now))
        XCTAssertFalse(ordering.admits(olderAnswer.delivery, now: SnapshotRequestClock.now), "the older GET answer is not applied after the event")
        XCTAssertEqual(model.staleSnapshotCount, 0, "and nothing the model itself received was out of order")

        // 6. The hub's API server is started again: the connection ends, the app connects again
        //    by itself and follows the new run -- through its events, as before.
        let streamBefore = try XCTUnwrap(event.delivery.hubOrder?.stream)
        let restarted = try await harness("restart")
        XCTAssertEqual(restarted, "restarted")
        try await waitUntil(timeout: 30) { model.connectionStatus != .connected }
        try await waitUntil(timeout: 30) { model.connectionStatus == .connected }
        let afterRestart = try await probe.currentSnapshot()
        XCTAssertNotEqual(afterRestart.delivery.hubOrder?.stream, streamBefore, "another run of the server: another stream")
        // The registered Base is still listed (the Registry is the same); what the new run says
        // next arrives as an event of the new stream.
        let settingsAgain = try await settingsTransport.putSettings(
            baseURL: baseURL, credential: credential, baseRevision: revision,
            settings: HubSettingsDocument(homeName: "E2E 2", rooms: [room], modules: [])
        )
        let newRevision = try XCTUnwrap(settingsAgain.revision)
        try await waitUntil(timeout: 15) { model.snapshot.hubSettings?.revision == newRevision }
        XCTAssertTrue(listed().contains(base))

        _ = try? await harness("quit")
    }

    /// The snapshots `source.updates()` yields first, at most `count` of them, waiting no longer than
    /// `seconds`.
    @MainActor
    private static func firstSnapshots(of source: LiveSensorDataSource, count: Int, within seconds: UInt64) async -> [HomeSnapshot] {
        let collector = Task { @MainActor () -> [HomeSnapshot] in
            var seen: [HomeSnapshot] = []
            for await snapshot in source.updates() {
                seen.append(snapshot)
                if seen.count == count { break }
            }
            return seen
        }
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            collector.cancel()
        }
        let received = await collector.value
        watchdog.cancel()
        return received
    }
}
