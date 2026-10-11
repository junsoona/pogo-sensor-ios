import XCTest
@testable import PogoHome

/// The app's real transports against a real hub API server over real HTTP and TLS on this Mac:
/// `URLSessionHubSettingsTransport` (pairing), `LiveSensorDataSource` with its `URLSession`
/// transport (`GET /api/v1/snapshot`, `GET /api/v1/events`) and
/// `URLSessionPowerBaseRemovalTransport` (the removal request that names its registration), on one
/// side; the Linux bridge's own `pogohome_api::Server`, `PowerBaseManagement` and
/// `ingest::Registry`, built for the Mac, on the other. What it is for: that the request this app
/// really sends is the one that hub really accepts, and that what the hub really says is read as
/// this app's tests assume.
///
/// The hub side is a harness that also plays the board (it carries a removal out, the Base is
/// registered again, the board polls): there is no radio, no board, no Linux and no iPhone in this.
///
/// Skipped unless the control directory of a running harness is given (an environment variable of
/// the `xcodebuild` process):
///
///     TEST_RUNNER_POGO_REMOVAL_E2E_DIR=<directory>
///
/// The harness writes `info.json` there and answers `<n>.cmd` with `<n>.done`.
///
/// A second test reads a hub **older** than the request this app sends (Linux bridge 0.4.2, the
/// same harness built from that tree), given the same way:
///
///     TEST_RUNNER_POGO_REMOVAL_E2E_EARLIER_HUB_DIR=<directory>
final class PowerBaseRemovalLiveNetworkTests: XCTestCase {
    private struct Info: Decodable {
        let url: String
        let hub_id: String
        let code: String
        let fingerprint: String
        let power_base: String
    }

    private struct NoAnswer: Error {}

    @MainActor
    func testTheRemovalRequestAndTheSnapshotOrderAgainstARealHub() async throws {
        guard let directory = ProcessInfo.processInfo.environment["POGO_REMOVAL_E2E_DIR"], !directory.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_POGO_REMOVAL_E2E_DIR to the control directory of a running harness")
        }
        let info = try JSONDecoder().decode(Info.self, from: Data(contentsOf: URL(fileURLWithPath: directory + "/info.json")))
        let baseURL = try XCTUnwrap(URL(string: info.url))
        let base = info.power_base

        // The harness's side of things: one word in, one word out.
        var commandNumber = 0
        func harness(_ word: String) async throws -> String {
            commandNumber += 1
            let command = URL(fileURLWithPath: "\(directory)/\(commandNumber).cmd")
            let done = URL(fileURLWithPath: "\(directory)/\(commandNumber).done")
            try Data((word + "\n").utf8).write(to: command, options: .atomic)
            for _ in 0..<300 {
                if let answer = try? String(contentsOf: done, encoding: .utf8) {
                    return answer.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw NoAnswer()
        }

        // This device pairs with the hub: the real proofs, the hub's own certificate pinned.
        let code = try XCTUnwrap(HubPairingCode.normalized(info.code))
        let credential = try await URLSessionHubSettingsTransport().pair(
            baseURL: baseURL, hubID: info.hub_id, code: code, deviceName: "E2E iPhone"
        )
        XCTAssertEqual(credential.certificateSHA256, info.fingerprint, "the pinned certificate is the hub's")

        let source = LiveSensorDataSource(endpoint: PogoAPIEndpoint(baseURL: baseURL), periodicRefreshInterval: nil)
        let removals = URLSessionPowerBaseRemovalTransport()
        func listed(_ snapshot: HomeSnapshot) -> PowerBase? {
            snapshot.powerBases.first { $0.hardwareIdentifier == base }
        }
        func ask(_ binding: PowerBaseRemovalBinding, _ requestID: String) async throws -> PowerBaseRemoval {
            try await removals.request(
                baseURL: baseURL, credential: credential, powerBaseIdentifier: base, binding: binding, requestID: requestID
            )
        }
        func refusal(_ binding: PowerBaseRemovalBinding, _ requestID: String) async -> PowerBaseRemovalError? {
            do {
                let job = try await ask(binding, requestID)
                XCTFail("the hub created or returned job \(job.id) (\(job.state)) for a request it had to refuse")
                return nil
            } catch {
                return error as? PowerBaseRemovalError
            }
        }

        // 1. What the hub says of the Base, as this app reads it: the registration, its removal
        //    serial, and where each snapshot stands.
        let first = try await source.currentSnapshot()
        let shown = try XCTUnwrap(listed(first), "the hub lists the Base")
        XCTAssertEqual(shown.management, .supported)
        let binding = try XCTUnwrap(shown.removalBinding, "the hub gives the registration and its removal serial")
        XCTAssertEqual(binding.serial, 0, "no removal was asked of this registration yet")
        let firstOrder = try XCTUnwrap(first.delivery.hubOrder, "the hub says where its snapshot stands")
        let second = try await source.currentSnapshot()
        let secondOrder = try XCTUnwrap(second.delivery.hubOrder)
        XCTAssertEqual(secondOrder.stream, firstOrder.stream, "one run of the hub: one stream")
        XCTAssertGreaterThan(secondOrder.sequence, firstOrder.sequence, "the later answer has the larger number")
        let firstAsked = try XCTUnwrap(first.delivery.requestOrdinal)
        XCTAssertGreaterThan(try XCTUnwrap(second.delivery.requestOrdinal), firstAsked, "and was asked for later")
        // The app's rule on the hub's real numbers: the later answer applied, then the earlier one
        // arriving after it.
        var ordering = HubSnapshotOrdering()
        XCTAssertTrue(ordering.admits(second.delivery, now: SnapshotRequestClock.now))
        XCTAssertFalse(ordering.admits(first.delivery, now: SnapshotRequestClock.now), "the older answer is not applied after the newer")

        // 2. What an app older than this one sends -- the Base alone -- is refused by this hub, and
        //    nothing comes of it.
        let https = PinnedHubHTTPS(timeout: 10)
        var legacy = try https.makeRequest(
            baseURL: baseURL, path: URLSessionPowerBaseRemovalTransport.collectionPath, method: "POST", token: credential.token
        )
        legacy.httpBody = Data("{\"power_base_uuid\":\"\(base)\"}".utf8)
        let (legacyBody, legacyStatus) = try await https.send(legacy, pinning: credential.certificateSHA256)
        XCTAssertEqual(legacyStatus, 422)
        XCTAssertEqual(
            URLSessionPowerBaseRemovalTransport.error(status: legacyStatus, data: legacyBody), .rejected("removal_registration_required")
        )
        let none = try await removals.list(baseURL: baseURL, credential: credential)
        XCTAssertTrue(none.isEmpty, "the request that named no registration created nothing")

        // 3. This app's request is the one the hub accepts.
        let requestID = PowerBaseForgetRequestID.make()
        let job = try await ask(binding, requestID)
        XCTAssertEqual(job.requestID, requestID, "the job says which request created it")
        XCTAssertEqual(job.record, binding.record, "and is about the registration that was confirmed")
        XCTAssertEqual(job.state, .pending)

        // 4. The same request again (its answer did not arrive): the same job, nothing twice.
        let again = try await ask(binding, requestID)
        XCTAssertEqual(again.id, job.id)
        let afterRetry = try await removals.list(baseURL: baseURL, credential: credential)
        XCTAssertEqual(afterRetry.map(\.id), [job.id])
        let during = try await source.currentSnapshot()
        XCTAssertEqual(during.powerBaseRemovals.first { $0.id == job.id }?.requestID, requestID, "the snapshot's job carries the request id too")
        XCTAssertEqual(listed(during)?.removalSerial, 1, "the registration's removal serial moved on with the job")

        // 5. The board carries the removal out; 6. another device registers the Base again.
        let carriedOut = try await harness("complete")
        XCTAssertEqual(carriedOut, "released")
        let released = try await source.currentSnapshot()
        XCTAssertNil(listed(released), "the Base is out of the hub's list")
        XCTAssertTrue(released.powerBaseDepartures.contains { $0.powerBaseIdentifier == base }, "and the hub says so")
        let registered = try await harness("reregister")
        XCTAssertEqual(registered, "registered-again")
        let renewed = try await source.currentSnapshot()
        let newBinding = try XCTUnwrap(listed(renewed)?.removalBinding, "the Base is listed again")
        XCTAssertNotEqual(newBinding.record, binding.record, "under another registration")
        XCTAssertEqual(newBinding.serial, 0)

        // 7. The earlier request once more, exactly as it was. The hub answers with that request's
        //    own job (as long as it still has it) or refuses -- and asks nothing of the new
        //    registration either way.
        do {
            let answer = try await ask(binding, requestID)
            XCTAssertEqual(answer.id, job.id, "the answer is the job of that request")
            XCTAssertEqual(answer.record, binding.record)
            XCTAssertNotEqual(answer.state, .pending, "which is over")
        } catch {
            XCTAssertEqual(error as? PowerBaseRemovalError, .staleRecord)
        }
        // 8. A request that names the earlier registration and that the hub never saw (its first
        //    delivery was delayed until now): refused.
        let delayed = await refusal(binding, PowerBaseForgetRequestID.make())
        XCTAssertEqual(delayed, .staleRecord)
        let afterOldRequests = try await removals.list(baseURL: baseURL, credential: credential)
        XCTAssertFalse(afterOldRequests.contains { $0.record == newBinding.record }, "no job of the new registration exists")
        let nothingForTheBoard = try await harness("poll")
        XCTAssertEqual(nothingForTheBoard, "idle", "the newly registered board is given no command")
        let untouched = try await source.currentSnapshot()
        XCTAssertEqual(listed(untouched)?.removalBinding, newBinding, "the new registration is as it was")

        // 9. A removal the user confirms now, of what is listed now, is carried out.
        let newRequestID = PowerBaseForgetRequestID.make()
        let newJob = try await ask(newBinding, newRequestID)
        XCTAssertEqual(newJob.record, newBinding.record)
        XCTAssertNotEqual(newJob.id, job.id)
        XCTAssertEqual(newJob.state, .pending)
        let cancelled = try await removals.cancel(baseURL: baseURL, credential: credential, removalID: newJob.id)
        XCTAssertEqual(cancelled.state, .cancelled)

        // 10. The cancelled request again is that cancelled job, not a new removal; so is nothing
        //     that names the serial of before it.
        let replayed = try await ask(newBinding, newRequestID)
        XCTAssertEqual(replayed.id, newJob.id)
        XCTAssertEqual(replayed.state, .cancelled)
        let staleSerial = await refusal(newBinding, PowerBaseForgetRequestID.make())
        XCTAssertEqual(staleSerial, .staleRecord)
        let stillNothing = try await harness("poll")
        XCTAssertEqual(stillNothing, "idle")

        // 11. A new confirmation -- of the registration and the serial the hub lists now -- is a
        //     new removal, and the board gets its command.
        let now = try await source.currentSnapshot()
        let nowBinding = try XCTUnwrap(listed(now)?.removalBinding)
        XCTAssertEqual(nowBinding, PowerBaseRemovalBinding(record: newBinding.record, serial: 1))
        let third = try await ask(nowBinding, PowerBaseForgetRequestID.make())
        XCTAssertEqual(third.state, .pending)
        XCTAssertNotEqual(third.id, newJob.id)
        let commandForTheBoard = try await harness("poll")
        XCTAssertEqual(commandForTheBoard, "unenroll")

        // 12. The data source's own connection (`updates()`): its connect answer continues the same
        //     line of numbers and says which request brought it.
        let nowOrder = try XCTUnwrap(now.delivery.hubOrder)
        let connectAnswers = await Self.firstSnapshots(of: source, count: 1, within: 15)
        let connectAnswer = try XCTUnwrap(connectAnswers.first, "the connect answer arrives")
        let connectOrder = try XCTUnwrap(connectAnswer.delivery.hubOrder)
        XCTAssertEqual(connectOrder.stream, nowOrder.stream)
        XCTAssertGreaterThan(connectOrder.sequence, nowOrder.sequence, "every snapshot of the run is numbered in one line")
        XCTAssertGreaterThan(try XCTUnwrap(connectAnswer.delivery.requestOrdinal), try XCTUnwrap(now.delivery.requestOrdinal))

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

    /// Over a real connection the first snapshot of `GET /api/v1/events` reaches the app. With no
    /// periodic `GET`: the second snapshot can only have come as an event.
    ///
    /// Until 1.3.3 it did not: the hub ends an event with an empty line,
    /// `URLSession.AsyncBytes.lines` does not hand empty lines on, and `SSELineParser` dispatches
    /// an event only at one. This test recorded that as an expected failure; 1.3.4 reads the
    /// connection with `SSELineSplitter`, and the mark is gone.
    @MainActor
    func testTheEventStreamOfARealHubDeliversItsFirstSnapshot() async throws {
        guard let directory = ProcessInfo.processInfo.environment["POGO_REMOVAL_E2E_DIR"], !directory.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_POGO_REMOVAL_E2E_DIR to the control directory of a running harness")
        }
        let info = try JSONDecoder().decode(Info.self, from: Data(contentsOf: URL(fileURLWithPath: directory + "/info.json")))
        let source = LiveSensorDataSource(endpoint: PogoAPIEndpoint(baseURL: try XCTUnwrap(URL(string: info.url))), periodicRefreshInterval: nil)
        // The hub sends the first event as soon as the stream is opened; ten seconds is ample.
        let received = await Self.firstSnapshots(of: source, count: 2, within: 10)
        XCTAssertEqual(received.count, 2, "the connect answer and the stream's first event arrive")
        guard received.count == 2 else { return }
        let first = try XCTUnwrap(received[0].delivery.hubOrder), second = try XCTUnwrap(received[1].delivery.hubOrder)
        XCTAssertEqual(second.stream, first.stream)
        XCTAssertGreaterThan(second.sequence, first.sequence, "GET answers and events are numbered in one line")
        XCTAssertGreaterThan(try XCTUnwrap(received[1].delivery.requestOrdinal), try XCTUnwrap(received[0].delivery.requestOrdinal))
    }

    /// A hub from before the request that names its registration: what it really says is read as
    /// "this hub cannot be asked", so the app offers no removal and sends nothing.
    @MainActor
    func testAnEarlierHubIsReadAsOneThatCannotBeAskedToRemove() async throws {
        guard let directory = ProcessInfo.processInfo.environment["POGO_REMOVAL_E2E_EARLIER_HUB_DIR"], !directory.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_POGO_REMOVAL_E2E_EARLIER_HUB_DIR to the control directory of a running harness of an earlier hub")
        }
        let info = try JSONDecoder().decode(Info.self, from: Data(contentsOf: URL(fileURLWithPath: directory + "/info.json")))
        let baseURL = try XCTUnwrap(URL(string: info.url))
        let source = LiveSensorDataSource(endpoint: PogoAPIEndpoint(baseURL: baseURL), periodicRefreshInterval: nil)
        let first = try await source.currentSnapshot()
        let second = try await source.currentSnapshot()
        let shown = try XCTUnwrap(first.powerBases.first { $0.hardwareIdentifier == info.power_base }, "the hub lists the Base")
        XCTAssertEqual(shown.management, .supported, "the hub can remove it")
        XCTAssertNotNil(shown.record, "and names its registration")
        XCTAssertNil(shown.removalSerial, "but gives no removal serial")
        XCTAssertNil(shown.removalBinding, "so there is nothing a request of this app could name")
        let state = PowerBaseManagementPresentation.state(
            identifier: info.power_base, snapshot: first,
            target: PowerBaseHubTarget(hubID: info.hub_id, baseURL: baseURL, isSimulated: false, isPaired: true),
            removal: nil, action: nil, isCurrentStateVerified: true
        )
        XCTAssertEqual(state.availability, .hubUnsupported, "no removal is offered: the hub has to be updated")
        // Its snapshots do not say where they stand: both are applied as they arrive, as before.
        XCTAssertNil(first.delivery.hubOrder)
        XCTAssertNil(second.delivery.hubOrder)
        var ordering = HubSnapshotOrdering()
        XCTAssertTrue(ordering.admits(second.delivery, now: SnapshotRequestClock.now))
        XCTAssertTrue(ordering.admits(first.delivery, now: SnapshotRequestClock.now))
        // Its event stream has the same form as the present hub's: the first event arrives here
        // too (1.3.4), without the two order fields.
        let received = await Self.firstSnapshots(of: source, count: 2, within: 10)
        XCTAssertEqual(received.count, 2, "the connect answer and the stream's first event of the earlier hub")
        XCTAssertTrue(received.allSatisfy { $0.delivery.hubOrder == nil })

        let command = URL(fileURLWithPath: "\(directory)/1.cmd")
        try? Data("quit\n".utf8).write(to: command, options: .atomic)
    }
}
