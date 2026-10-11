#if os(macOS)
import XCTest
@testable import ESPProvisionSecurity2
@testable import PowerBaseBLEKit

/// The local reset, Swift client against the REAL C implementation: the firmware repository's host
/// harness runs ESP-IDF's protocomm + Security 2 server, the real BLE service and admission code
/// (pb_ble_service.c, pb_ble_admission.c) and the real reset (pb_reenroll.c, pb_reenroll_store.c,
/// power_base_enrollment.c) over the NVS simulator. Only OpenThread's store and the BLE link are
/// stand-ins. See `HarnessInteropTests` for what that does and does not show; in particular no
/// button, no GPIO and no radio is involved -- a "window boot" here is the harness being told so.
final class LocalResetInteropTests: XCTestCase {
    private static let authOK: UInt8 = 0
    private static let journalAbsent: UInt8 = 0
    private static let journalValid: UInt8 = 1
    private static let stageVerified: UInt8 = 2
    private static let recordAbsent: UInt8 = 0
    private static let recordValid: UInt8 = 1
    private static let pskd = "J01NME7K"

    private var fixture: HarnessFixture!
    private var logURL: URL!
    private var harnesses: [Harness] = []

    override func setUpWithError() throws {
        fixture = try HarnessFixture.load()
        logURL = FileManager.default.temporaryDirectory.appendingPathComponent("pb-harness-lr-\(UUID().uuidString).log")
    }

    override func tearDown() {
        harnesses.forEach { $0.quit() }
        harnesses = []
        if let logURL { try? FileManager.default.removeItem(at: logURL) }
    }

    /// One boot of a board, as `flags` say.
    private func boot(_ flags: Harness.LocalResetBoot) throws -> Harness {
        let harness = try Harness(path: fixture.harnessPath, logURL: logURL)
        harnesses.append(harness)
        do {
            guard try harness.prepareLocalReset(flags) else {
                throw XCTSkip("the harness at \(fixture.harnessPath) does not know the local reset (rebuild tools/host_ble_sec2)")
            }
        }
        XCTAssertEqual(try harness.boot(eui64: fixture.eui64, record: fixture.record), Self.authOK, "the service starts for this board's record")
        return harness
    }

    private func authenticatedClient(_ harness: Harness, session: UInt32 = 1) async throws -> (PowerBaseBLEBoardClient, HarnessLink) {
        XCTAssertTrue(try harness.connect(session))
        let link = HarnessLink(harness: harness, session: session)
        let client = PowerBaseBLEBoardClient(link: link)
        try await client.checkVersion()
        try await client.authenticate(eui64: fixture.eui64, setupCode: fixture.setupCode)
        return (client, link)
    }

    private func challenge(_ client: PowerBaseBLEBoardClient) async throws -> PowerBaseBLEChallenge {
        let status = try await client.status(issueChallenge: true)
        return try XCTUnwrap(status.challenge)
    }

    private func operation(_ seed: UInt8) -> PowerBaseBLEOperationID {
        PowerBaseBLEOperationID(bytes: Data((0..<16).map { seed &+ UInt8($0) }))!
    }

    private func reset(_ client: PowerBaseBLEBoardClient, _ id: PowerBaseBLEOperationID, target: PowerBaseBLEEUI64? = nil) async throws -> PowerBaseBLECode {
        try await client.localReset(
            target: target ?? fixture.eui64, operationID: id, challenge: try await challenge(client), confirmation: .userConfirmedErasingRegistration
        )
    }

    private func assertUntouched(_ harness: Harness, _ why: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let stats = try harness.localResetStats()
        XCTAssertEqual(stats.recordStatus, Self.recordValid, "the registration record is still there. \(why)", file: file, line: line)
        XCTAssertTrue(stats.datasetStored, "the stored network is still there. \(why)", file: file, line: line)
        XCTAssertEqual(stats.journalStatus, Self.journalAbsent, "no reset was journaled. \(why)", file: file, line: line)
        XCTAssertEqual(stats.resetRuns, 0, "the worker ran no reset. \(why)", file: file, line: line)
    }

    // MARK: - The whole path

    func testAConfirmedResetInAnOpenWindowIsAcceptedRunAndVerified() async throws {
        let harness = try boot([.supported, .window, .enrolled])
        let (client, link) = try await authenticatedClient(harness)
        let capabilities = await client.capabilities()
        XCTAssertEqual(capabilities, [.bridgeEndpointV1, .managementV1, .releaseReceiptV1, .localResetV1], "a board with the button lists the capability")

        // Who the board is and what it holds, inside the session.
        let boardStatus = try await client.status()
        XCTAssertEqual(boardStatus.eui64, fixture.eui64)
        XCTAssertEqual(boardStatus.state, .enrolled, "its registration was only not resumed for this boot")
        let before = try await client.localResetStatus(target: fixture.eui64, operationID: nil)
        XCTAssertEqual(before, PowerBaseBLELocalResetStatus(eui64: fixture.eui64, condition: .enrolled, isWindowOpen: true, windowSecondsLeft: 120))
        XCTAssertEqual(try harness.stats().threadEnabled, false, "Thread is not enabled in a window boot")
        XCTAssertEqual(try harness.stats().servicesAllowed, false, "and no service may start")
        try assertUntouched(harness, "authentication and status alone")

        // No registration is taken in a window boot.
        let endpoint = try PowerBaseBLEBridgeEndpoint(address: "fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79", port: 5684)
        let start = try await client.start(
            target: fixture.eui64, requestID: PowerBaseBLERequestID(bytes: Data(repeating: 7, count: 16))!, challenge: try await challenge(client),
            pskd: Self.pskd, endpoint: endpoint
        )
        XCTAssertEqual(start, .notWaiting, "pb-start is refused before the reset is verified and the board restarted")
        try harness.poll()
        XCTAssertEqual(try harness.stats().joinerStarts, 0)

        // The command.
        let id = operation(0x81)
        let accepted = try await reset(client, id)
        XCTAssertEqual(accepted, .accepted)
        try assertUntouched(harness, "accepted is queued: the BLE callback erased nothing")
        let queued = try await client.localResetStatus(target: fixture.eui64, operationID: id)
        XCTAssertEqual(queued.operationPhase, .queued)
        XCTAssertEqual(queued.condition, .resetPending)
        let again = try await reset(client, id)
        XCTAssertEqual(again, .duplicate, "the same operation again starts nothing new")
        let busy = try await reset(client, operation(0x21))
        XCTAssertEqual(busy, .busy, "another operation beside it is refused")

        // The worker runs it.
        XCTAssertEqual(try harness.poll(), .open)
        let stats = try harness.localResetStats()
        XCTAssertEqual(stats.resetRuns, 1, "exactly one reset")
        XCTAssertEqual(stats.quiesceCalls, 1)
        XCTAssertEqual(stats.journalStatus, Self.journalValid)
        XCTAssertEqual(stats.journalStage, Self.stageVerified)
        XCTAssertEqual(stats.journalOperation, id.bytes, "the journal names the operation id the Swift client chose")
        XCTAssertEqual(stats.recordStatus, Self.recordAbsent, "the registration record is gone")
        XCTAssertFalse(stats.datasetStored, "the stored network is gone")

        let verified = try await client.localResetStatus(target: fixture.eui64, operationID: id)
        XCTAssertEqual(verified.operationPhase, .verified)
        XCTAssertEqual(verified.condition, .notEnrolled)
        XCTAssertEqual(verified.operationReason, 0)
        let unknown = try await client.localResetStatus(target: fixture.eui64, operationID: operation(0x21))
        XCTAssertNil(unknown.operationPhase, "an operation that never ran is not known")
        let duplicate = try await reset(client, id)
        XCTAssertEqual(duplicate, .duplicate)
        try harness.poll()
        XCTAssertEqual(try harness.localResetStats().resetRuns, 1, "still exactly one reset")

        // The grace period, then the board restarts.
        try harness.advance(milliseconds: 2999)
        XCTAssertEqual(try harness.poll(), .open, "BLE stays up for a moment so the result can be read")
        try harness.advance(milliseconds: 1)
        XCTAssertEqual(try harness.poll(), .localResetDone)
        XCTAssertTrue(link.exchanges.allSatisfy { $0.request.count <= 512 && ($0.response?.count ?? 0) <= 512 }, "every value fits one attribute")
    }

    // MARK: - Nothing without the confirmation, the window, the right board, a fresh challenge

    func testAuthenticationAloneChangesNothingAndTheWindowRunsOut() async throws {
        let harness = try boot([.supported, .window, .enrolled])
        let (client, _) = try await authenticatedClient(harness)
        _ = try await client.status(issueChallenge: true)
        let status = try await client.localResetStatus(target: fixture.eui64, operationID: operation(0x55))
        XCTAssertNil(status.operationPhase, "asking about an operation creates none")
        try harness.poll()
        try assertUntouched(harness, "a session, a challenge and status questions")

        try harness.advance(milliseconds: 110_000)
        let late = try await client.localResetStatus(target: fixture.eui64, operationID: nil)
        XCTAssertEqual(late.windowSecondsLeft, 10, "being connected does not extend the window")
        try harness.advance(milliseconds: 10_000)
        let closedWindow = try await reset(client, operation(0x55))
        XCTAssertEqual(closedWindow, .windowClosed, "a command after 120 s")
        XCTAssertEqual(try harness.poll(), .windowExpired)
        try assertUntouched(harness, "an expired window")
    }

    func testWrongBoardStaleChallengeAndNoWindowAreRefusedWithNothingChanged() async throws {
        let harness = try boot([.supported, .window, .enrolled])
        let (client, _) = try await authenticatedClient(harness)
        let other = try XCTUnwrap(PowerBaseBLEEUI64(hex: "6055f9fffe005678"))
        let id = operation(0x31)

        let wrongTarget = try await reset(client, id, target: other)
        XCTAssertEqual(wrongTarget, .wrongTarget)
        await assertClientError(.refusedByBoard(.wrongTarget), "status for another board") {
            _ = try await client.localResetStatus(target: other, operationID: nil)
        }

        // A second session; the first one's challenge is not its.
        let (first, _) = try await authenticatedClient(harness, session: 2)
        let stale = try await challenge(first)
        XCTAssertTrue(try harness.disconnect(2))
        let (second, _) = try await authenticatedClient(harness, session: 3)
        let staleCode = try await second.localReset(target: fixture.eui64, operationID: id, challenge: stale, confirmation: .userConfirmedErasingRegistration)
        XCTAssertEqual(staleCode, .challengeInvalid, "a challenge of an earlier session")

        let fresh = try await challenge(second)
        try harness.advance(milliseconds: 60_000)
        let expired = try await second.localReset(target: fixture.eui64, operationID: id, challenge: fresh, confirmation: .userConfirmedErasingRegistration)
        XCTAssertEqual(expired, .challengeExpired, "a challenge older than its lifetime")
        let spent = try await second.localReset(target: fixture.eui64, operationID: id, challenge: fresh, confirmation: .userConfirmedErasingRegistration)
        XCTAssertEqual(spent, .challengeInvalid, "and it is used up")
        try harness.poll()
        try assertUntouched(harness, "refused commands")

        // The same board in an ordinary boot: authenticated and confirmed, but no button.
        let ordinary = try boot([.supported, .enrolled])
        let (noWindow, _) = try await authenticatedClient(ordinary)
        let state = try await noWindow.localResetStatus(target: fixture.eui64, operationID: nil)
        XCTAssertFalse(state.isWindowOpen)
        XCTAssertEqual(state.condition, .enrolled)
        let refused = try await reset(noWindow, id)
        XCTAssertEqual(refused, .windowClosed, "authentication without the physical window resets nothing")
        try ordinary.poll()
        let stats = try ordinary.localResetStats()
        XCTAssertEqual(stats.recordStatus, Self.recordValid)
        XCTAssertEqual(stats.journalStatus, Self.journalAbsent)
        XCTAssertEqual(stats.resetRuns, 0)
    }

    func testAWrongSetupCodeInTheWindowGetsNothing() async throws {
        let harness = try boot([.supported, .window, .enrolled])
        XCTAssertTrue(try harness.connect(1))
        let link = HarnessLink(harness: harness, session: 1)
        let client = PowerBaseBLEBoardClient(link: link)
        try await client.checkVersion()
        let wrong = String(fixture.setupCode.dropLast()) + (fixture.setupCode.last == "A" ? "B" : "A")
        do {
            try await client.authenticate(eui64: fixture.eui64, setupCode: wrong)
            XCTFail("a wrong setup code must not authenticate")
        } catch {
            XCTAssertEqual(error as? PowerBaseBLEClientError, .authenticationFailed)
        }
        await assertClientError(.noSession, "no session, no command") {
            _ = try await client.localResetStatus(target: fixture.eui64, operationID: nil)
        }
        // The command's bytes without a session: the board cannot decrypt them.
        let raw = PowerBaseBLECodec.localResetRequest(
            target: fixture.eui64, operationID: operation(0x41), challenge: PowerBaseBLEChallenge(bytes: Data(repeating: 9, count: 16), lifetimeSeconds: 60)!,
            confirmation: .userConfirmedErasingRegistration
        )
        let unauthenticated = try harness.request(session: 1, endpoint: "pb-start", data: raw)
        XCTAssertNotEqual(unauthenticated.error, 0, "a plaintext command is not accepted")
        try harness.poll()
        try assertUntouched(harness, "a wrong setup code and an unauthenticated command")
    }

    // MARK: - A lost answer is asked about, never sent again

    func testALostAnswerIsResolvedByAskingAboutTheSameOperation() async throws {
        let harness = try boot([.supported, .window, .enrolled])
        let (client, link) = try await authenticatedClient(harness)
        let id = operation(0x61)
        let fresh = try await challenge(client)
        // The board takes the command; its answer is destroyed on the way back.
        link.tamperResponses { endpoint, response in
            guard endpoint == .start else { return response }
            var broken = response
            broken[broken.count - 1] ^= 0x01
            return broken
        }
        await assertClientError(.decryptionFailed, "the answer was lost") {
            _ = try await client.localReset(target: fixture.eui64, operationID: id, challenge: fresh, confirmation: .userConfirmedErasingRegistration)
        }
        link.tamperResponses(nil)
        await assertClientError(.noSession, "the session is gone with it: nothing more is sent on it") {
            _ = try await client.localResetStatus(target: fixture.eui64, operationID: id)
        }
        XCTAssertEqual(try harness.poll(), .open)
        XCTAssertEqual(try harness.localResetStats().resetRuns, 1, "the board ran the command it took")

        // A new connection asks; it does not send the command again.
        XCTAssertTrue(try harness.disconnect(1))
        let (asking, askingLink) = try await authenticatedClient(harness, session: 2)
        let outcome = try await asking.localResetStatus(target: fixture.eui64, operationID: id)
        XCTAssertEqual(outcome.operationPhase, .verified)
        XCTAssertEqual(outcome.condition, .notEnrolled)
        XCTAssertEqual(askingLink.exchangeCount(.start), 0, "nothing was written to pb-start by the question")
        try harness.poll()
        XCTAssertEqual(try harness.localResetStats().resetRuns, 1, "one operation, one reset")
    }

    // MARK: - Boards that have nothing to reset, or do not know the messages

    func testABoardThatIsNotEnrolledIsNotResetAgain() async throws {
        let harness = try boot([.supported, .window])
        let (client, _) = try await authenticatedClient(harness)
        let status = try await client.localResetStatus(target: fixture.eui64, operationID: nil)
        XCTAssertEqual(status.condition, .notEnrolled, "nothing to reset: register it the usual way")
        let code = try await reset(client, operation(0x71))
        XCTAssertEqual(code, .notEnrolled)
        try harness.poll()
        let stats = try harness.localResetStats()
        XCTAssertEqual(stats.resetRuns, 0)
        XCTAssertEqual(stats.journalStatus, Self.journalAbsent)
    }

    func testFirmwareWithoutTheCapabilityAnswersBothMessagesAsUnknownTypes() async throws {
        // No 'W': the board every earlier driver gets.
        let harness = try Harness(path: fixture.harnessPath, logURL: logURL)
        harnesses.append(harness)
        XCTAssertEqual(try harness.boot(eui64: fixture.eui64, record: fixture.record), Self.authOK)
        let (client, link) = try await authenticatedClient(harness)
        let capabilities = await client.capabilities()
        XCTAssertEqual(capabilities, [.bridgeEndpointV1, .managementV1, .releaseReceiptV1], "no local_reset_v1")
        await assertClientError(.invalidInput("capability"), "the client sends nothing") {
            _ = try await client.localReset(
                target: fixture.eui64, operationID: operation(0x11), challenge: try await challenge(client), confirmation: .userConfirmedErasingRegistration
            )
        }
        await assertClientError(.invalidInput("capability"), "and asks nothing") {
            _ = try await client.localResetStatus(target: fixture.eui64, operationID: nil)
        }
        XCTAssertEqual(link.exchangeCount(.start), 0, "nothing was written to pb-start -- no older start in its place either")

        // What such firmware would answer if the bytes were sent all the same.
        let handshake = Security2Handshake(username: fixture.eui64.hex, password: fixture.setupCode)
        XCTAssertTrue(try harness.connect(2))
        let response0 = try harness.request(session: 2, endpoint: "prov-session", data: try handshake.command0())
        let response1 = try harness.request(session: 2, endpoint: "prov-session", data: try handshake.command1(response0: response0.response))
        try handshake.finish(response1: response1.response)
        let statusRequest = PowerBaseBLECodec.statusRequest(issueChallenge: true, requestID: nil)
        let statusAnswer = try harness.request(session: 2, endpoint: "pb-status", data: try XCTUnwrap(handshake.encrypt(statusRequest)))
        let status = try PowerBaseBLECodec.decodeStatusResponse(try XCTUnwrap(handshake.decrypt(statusAnswer.response)))
        let command = PowerBaseBLECodec.localResetRequest(
            target: fixture.eui64, operationID: operation(0x11), challenge: try XCTUnwrap(status.challenge), confirmation: .userConfirmedErasingRegistration
        )
        let commandAnswer = try harness.request(session: 2, endpoint: "pb-start", data: try XCTUnwrap(handshake.encrypt(command)))
        let commandPlain = try XCTUnwrap(handshake.decrypt(commandAnswer.response))
        XCTAssertEqual(commandPlain, Data([1, 0x82, 0x11, 0]), "pb-start's MALFORMED, as for any unknown type")
        XCTAssertThrowsError(try PowerBaseBLECodec.decodeLocalResetResponse(commandPlain)) {
            XCTAssertEqual($0 as? PowerBaseBLECodecError, .type(0x82), "which this codec does not take for an answer")
        }
        let question = PowerBaseBLECodec.localResetStatusRequest(target: fixture.eui64, operationID: nil)
        let questionAnswer = try harness.request(session: 2, endpoint: "pb-status", data: try XCTUnwrap(handshake.encrypt(question)))
        let questionPlain = try XCTUnwrap(handshake.decrypt(questionAnswer.response))
        XCTAssertEqual(questionPlain.count, 40)
        XCTAssertEqual(Data(questionPlain.prefix(4)), Data([1, 0x81, 0x11, 0]), "pb-status's 40-byte MALFORMED")
        XCTAssertThrowsError(try PowerBaseBLECodec.decodeLocalResetStatusResponse(questionPlain, target: fixture.eui64))
    }

    private func assertClientError(
        _ expected: PowerBaseBLEClientError, _ message: String = "", file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected). \(message)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? PowerBaseBLEClientError, expected, message, file: file, line: line)
        }
    }
}
#endif
