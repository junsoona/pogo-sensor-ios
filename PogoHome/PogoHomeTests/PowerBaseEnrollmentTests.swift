#if DEBUG
import XCTest
@testable import PogoHome

/// The DEBUG enrollment test's input rules and the hub's API contract ("Power Base enrollment" in
/// docs/pogohome-api-v1.md).
final class PowerBaseEnrollmentContractTests: XCTestCase {
    func testEUI64IsSixteenHexDigitsNormalizedToLowercase() {
        XCTAssertEqual(PowerBaseEUI64.normalized("00124B0001A2B3C4"), "00124b0001a2b3c4")
        XCTAssertEqual(PowerBaseEUI64.normalized("  00124b0001a2b3c4\n"), "00124b0001a2b3c4", "a pasted line")
        for bad in [
            "", "00124b0001a2b3c", "00124b0001a2b3c4a",   // length
            "00:12:4b:00:01:a2:b3:c4", "0012-4b00-01a2-b3c4", "00124b00 01a2b3c4", // separators
            "*", "****************", "00124b0001a2b3c*",  // wildcard Joiner
            "0000000000000000",                            // all zero
            "00124g0001a2b3c4",                            // not hex
            "００１２４ｂ０００１ａ２ｂ３ｃ４",                  // full-width digits
        ] {
            XCTAssertNil(PowerBaseEUI64.normalized(bad), bad)
        }
    }

    func testPSKdUsesTheThreadAlphabetWithTwelveSecureRandomCharacters() throws {
        XCTAssertEqual(ThreadPSKd.alphabet.count, 32)
        XCTAssertEqual(Set(ThreadPSKd.alphabet).intersection(["I", "O", "Q", "Z"]), [])
        XCTAssertEqual(String(ThreadPSKd.alphabet), "0123456789ABCDEFGHJKLMNPRSTUVWXY")

        var seen = Set<String>()
        for _ in 0..<200 {
            let code = try XCTUnwrap(ThreadPSKd.generate())
            XCTAssertEqual(code.count, 12)
            XCTAssertTrue(ThreadPSKd.isValid(code), code)
            seen.insert(code)
        }
        XCTAssertEqual(seen.count, 200, "every code is new")

        // Each byte's low 5 bits pick one of the 32 characters, so there is no bias.
        XCTAssertEqual(ThreadPSKd.generate(randomBytes: { Array(UInt8(0)..<UInt8($0)) }), "0123456789AB")
        XCTAssertEqual(ThreadPSKd.generate(randomBytes: { [UInt8](repeating: 0xFF, count: $0) }), "YYYYYYYYYYYY")
        XCTAssertNil(ThreadPSKd.generate(randomBytes: { _ in nil }), "no secure randomness, no code")
    }

    func testPSKdValidation() {
        XCTAssertTrue(ThreadPSKd.isValid("J01NME"))
        XCTAssertTrue(ThreadPSKd.isValid(String(repeating: "A", count: 32)))
        for bad in ["J01NM", String(repeating: "A", count: 33), "j01nme7k2", "J01NMEI", "J01NMEO", "J01NMEQ", "J01NMEZ", "J01 NME", "J01-NME"] {
            XCTAssertFalse(ThreadPSKd.isValid(bad), bad)
        }
    }

    func testStartBodyIsExactlyTheTwoDocumentedFields() throws {
        let body = try URLSessionPowerBaseEnrollmentTransport.startBody(eui64: "00124b0001a2b3c4", pskd: "J01NME7K2ABC")
        XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"eui64":"00124b0001a2b3c4","pskd":"J01NME7K2ABC"}"#)
    }

    func testSessionPathAcceptsOnlyAHubIssuedID() throws {
        XCTAssertEqual(try URLSessionPowerBaseEnrollmentTransport.sessionPath(EnrollmentFixtures.sessionID),
                       "api/v1/power-base-enrollments/" + EnrollmentFixtures.sessionID)
        for bad in ["", "../settings", EnrollmentFixtures.sessionID.uppercased(), EnrollmentFixtures.sessionID + "0", "5f0c1d2e3f405162738495a6b7c8d9e?"] {
            XCTAssertThrowsError(try URLSessionPowerBaseEnrollmentTransport.sessionPath(bad), bad)
        }
    }

    func testMalformedValuesNeverLeaveTheDevice() async {
        // An address nothing listens on: a request would fail as unreachable, not as rejected.
        let transport = URLSessionPowerBaseEnrollmentTransport()
        let url = URL(string: "http://127.0.0.1:9")!
        await XCTAssertThrowsErrorAsync(try await transport.start(baseURL: url, credential: EnrollmentFixtures.credential(), eui64: "00124b0001a2b3c4", pskd: "abc")) {
            XCTAssertEqual($0 as? PowerBaseEnrollmentError, .rejected("invalid_pskd"))
        }
        await XCTAssertThrowsErrorAsync(try await transport.start(baseURL: url, credential: EnrollmentFixtures.credential(), eui64: "00124B0001A2B3C4", pskd: "J01NME7K2ABC")) {
            XCTAssertEqual($0 as? PowerBaseEnrollmentError, .rejected("invalid_eui64"), "only the normalized form is sent")
        }
    }

    private let sessionJSON = """
    {"session_id":"5f0c1d2e3f405162738495a6b7c8d9e0","eui64":"00124b0001a2b3c4","state":"waiting_for_heartbeat","finished":false,"joiner_entry":"allowed","error":null,"window_seconds":120,"created_at_unix_ms":1790000000000,"expires_at_unix_ms":1790000120000,"expires_in_ms":118250,"heartbeat_received_at_unix_ms":null,"started_by_device_id":"0123456789abcdef"}
    """

    func testSessionDecodingIsStrictAboutDocumentedFields() throws {
        let session = try URLSessionPowerBaseEnrollmentTransport.decodeSession(Data(sessionJSON.utf8), deviceID: EnrollmentFixtures.deviceID)
        XCTAssertEqual(session, EnrollmentFixtures.session(.waitingForHeartbeat, bridgeEndpoint: .none))

        // Unknown additional fields are ignored (the API's compatibility policy).
        let extended = sessionJSON.replacingOccurrences(of: "}", with: #","future_field":1}"#)
        XCTAssertNoThrow(try URLSessionPowerBaseEnrollmentTransport.decodeSession(Data(extended.utf8), deviceID: EnrollmentFixtures.deviceID))

        let malformed = [
            sessionJSON.replacingOccurrences(of: #""error":null,"#, with: ""),                          // missing field
            sessionJSON.replacingOccurrences(of: "waiting_for_heartbeat", with: "joined"),              // unknown state
            sessionJSON.replacingOccurrences(of: "5f0c1d2e", with: "5F0C1D2E"),                         // id not lowercase
            sessionJSON.replacingOccurrences(of: #""finished":false"#, with: #""finished":"no""#),      // wrong type
            sessionJSON.replacingOccurrences(of: "00124b0001a2b3c4", with: "0000000000000000"),         // bad EUI-64
            sessionJSON.replacingOccurrences(of: "118250", with: "-1"),                                 // negative time
        ]
        for json in malformed {
            XCTAssertThrowsError(try URLSessionPowerBaseEnrollmentTransport.decodeSession(Data(json.utf8), deviceID: EnrollmentFixtures.deviceID)) {
                XCTAssertEqual($0 as? PowerBaseEnrollmentError, .badResponse("session"))
            }
        }
        XCTAssertThrowsError(try URLSessionPowerBaseEnrollmentTransport.decodeSession(Data(sessionJSON.utf8), deviceID: "ffffffffffffffff"),
                             "another device's session is never taken as this one's")
    }

    func testErrorAnswersMapToTheDocumentedCases() {
        func map(_ status: Int, _ body: String) -> PowerBaseEnrollmentError {
            URLSessionPowerBaseEnrollmentTransport.error(status: status, data: Data(body.utf8), deviceID: EnrollmentFixtures.deviceID)
        }
        XCTAssertEqual(map(401, #"{"error":"unauthorized"}"#), .unauthorized)
        XCTAssertEqual(map(403, #"{"error":"tls_required"}"#), .forbidden("tls_required"))
        XCTAssertEqual(map(404, #"{"error":"enrollment_disabled"}"#), .enrollmentDisabled)
        XCTAssertEqual(map(404, #"{"error":"session_not_found"}"#), .sessionNotFound)
        XCTAssertEqual(map(404, "Not Found"), .notSupported)
        XCTAssertEqual(map(405, ""), .notSupported)
        XCTAssertEqual(map(409, #"{"error":"enrollment_in_progress"}"#), .enrollmentInProgress(ownSession: nil), "another device's session")
        XCTAssertEqual(map(409, #"{"error":"enrollment_in_progress","session":\#(sessionJSON)}"#),
                       .enrollmentInProgress(ownSession: EnrollmentFixtures.session(.waitingForHeartbeat, bridgeEndpoint: .none)), "this device's own session")
        let othersSession = sessionJSON.replacingOccurrences(of: "0123456789abcdef", with: "ffffffffffffffff")
        XCTAssertEqual(map(409, #"{"error":"enrollment_in_progress","session":\#(othersSession)}"#), .enrollmentInProgress(ownSession: nil))
        XCTAssertEqual(map(409, #"{"error":"power_base_already_connected"}"#), .powerBaseAlreadyConnected)
        let finalJSON = sessionJSON.replacingOccurrences(of: "waiting_for_heartbeat", with: "heartbeat_received")
            .replacingOccurrences(of: #""heartbeat_received_at_unix_ms":null"#, with: #""heartbeat_received_at_unix_ms":1790000030000"#)
        if case let .sessionAlreadyFinal(session) = map(409, #"{"error":"session_already_final","session":\#(finalJSON)}"#) {
            XCTAssertEqual(session.state, .heartbeatReceived)
        } else {
            XCTFail("session_already_final carries the final session")
        }
        XCTAssertEqual(map(409, #"{"error":"session_already_final"}"#), .badResponse("HTTP 409"))
        XCTAssertEqual(map(422, #"{"error":"invalid_pskd"}"#), .rejected("invalid_pskd"))
        XCTAssertEqual(map(411, #"{"error":"length_required"}"#), .rejected("length_required"))
        XCTAssertEqual(map(503, #"{"error":"enrollment_unavailable","reason":"startup"}"#), .unavailable("startup"))
        XCTAssertEqual(map(503, #"{"error":"auth_unavailable"}"#), .unavailable("auth_unavailable"))
        XCTAssertEqual(map(500, #"{"error":"internal_error"}"#), .internalError)
        XCTAssertEqual(map(302, ""), .badResponse("HTTP 302"), "a redirect is not followed and not trusted")
    }
}

/// The DEBUG enrollment test's state machine against a scripted hub.
@MainActor
final class PowerBaseEnrollmentControllerTests: XCTestCase {
    private var hub: FakeEnrollmentHub!
    private var clipboard: FakeEnrollmentClipboard!
    private var credentials: InMemoryHubCredentialStore!

    override func setUp() async throws {
        hub = FakeEnrollmentHub()
        clipboard = FakeEnrollmentClipboard()
        credentials = InMemoryHubCredentialStore([
            EnrollmentFixtures.credential(hubID: EnrollmentFixtures.hubA, token: "token-A"),
            EnrollmentFixtures.credential(hubID: EnrollmentFixtures.hubB, token: "token-B", certificate: String(repeating: "d", count: 64)),
        ])
    }

    private func makeController(target: PowerBaseEnrollmentController.Target = EnrollmentFixtures.pairedTarget()) -> PowerBaseEnrollmentController {
        let controller = PowerBaseEnrollmentController(transport: hub, credentials: credentials, clipboard: clipboard, pollInterval: .milliseconds(10))
        controller.targetDidChange(target)
        return controller
    }

    private func finishedState(_ controller: PowerBaseEnrollmentController) -> PowerBaseEnrollmentSession.State? {
        if case let .finished(session) = controller.phase { return session.state }
        return nil
    }

    private func runningState(_ controller: PowerBaseEnrollmentController) -> PowerBaseEnrollmentSession.State? {
        if case let .running(session) = controller.phase { return session.state }
        return nil
    }

    /// Lets queued tasks (a late answer, a poll that should not happen) run.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(60))
    }

    // MARK: - Sessions

    /// The Joiner probe on the spare board joins Thread but never sends Power Base heartbeats, so a
    /// probe test must end `expired` — even after the board really joined. That is the expected,
    /// correct result, never shown as success.
    func testJoinerProbeSessionRunsPreparingThenWaitingThenEndsExpired() async throws {
        hub.scriptStart(.success(EnrollmentFixtures.session(.preparing)))
        hub.scriptStatus(.success(EnrollmentFixtures.session(.preparing)),
                         .success(EnrollmentFixtures.session(.waitingForHeartbeat)),
                         .success(EnrollmentFixtures.session(.waitingForHeartbeat)),
                         .success(EnrollmentFixtures.session(.expired, joinerEntry: "removed")))
        let controller = makeController()
        XCTAssertTrue(controller.canStart)

        controller.start(eui64: "00124B0001A2B3C4")
        XCTAssertEqual(controller.phase, .starting)
        XCTAssertNil(controller.pskd, "the PSKd is shown only after the hub accepted the session")

        try await eventually { self.runningState(controller) != nil }
        let post = try XCTUnwrap(hub.recorded(.start).first)
        XCTAssertEqual(post.eui64, "00124b0001a2b3c4", "sent normalized")
        XCTAssertEqual(post.baseURL, EnrollmentFixtures.urlA)
        XCTAssertEqual(post.token, "token-A", "this device's own credential for this hub")
        XCTAssertEqual(post.pinnedCertificate, String(repeating: "c", count: 64))
        let code = try XCTUnwrap(controller.pskd)
        XCTAssertEqual(post.pskd, code, "the code on screen is the one the hub accepted")
        XCTAssertTrue(ThreadPSKd.isValid(code) && code.count == 12)
        XCTAssertNotNil(controller.expiresAround)

        try await eventually { self.runningState(controller) == .waitingForHeartbeat }
        XCTAssertNotNil(controller.pskd)

        try await eventually { self.finishedState(controller) != nil }
        XCTAssertEqual(finishedState(controller), .expired, "a Joiner probe never sends heartbeats: expired is the normal end")
        XCTAssertNil(controller.pskd, "dropped at the end")
        XCTAssertNil(controller.expiresAround)
        XCTAssertTrue(hub.recorded.allSatisfy { $0.sessionID == nil || $0.sessionID == EnrollmentFixtures.sessionID })

        let polls = hub.recorded(.status).count
        try await settle()
        XCTAssertEqual(hub.recorded(.status).count, polls, "polling stops at the final state")
        XCTAssertTrue(hub.recorded(.cancel).isEmpty)
    }

    func testOnlyTheHubsHeartbeatReceivedIsSuccess() async throws {
        hub.scriptStart(.success(EnrollmentFixtures.session(.preparing)))
        hub.scriptStatus(.success(EnrollmentFixtures.session(.waitingForHeartbeat)), .success(EnrollmentFixtures.session(.heartbeatReceived)))
        let controller = makeController()
        controller.start(eui64: EnrollmentFixtures.eui64)
        try await eventually { self.finishedState(controller) != nil }
        XCTAssertEqual(finishedState(controller), .heartbeatReceived)
        XCTAssertNil(controller.pskd)
    }

    func testEachStartUsesANewPSKd() async throws {
        for _ in 0..<2 {
            hub.scriptStart(.success(EnrollmentFixtures.session(.cancelled)))
        }
        let controller = makeController()
        controller.start(eui64: EnrollmentFixtures.eui64)
        try await eventually { self.finishedState(controller) != nil }
        controller.start(eui64: EnrollmentFixtures.eui64)
        try await eventually { self.hub.recorded(.start).count == 2 }
        let codes = hub.recorded(.start).compactMap(\.pskd)
        XCTAssertEqual(codes.count, 2)
        XCTAssertNotEqual(codes[0], codes[1])
    }

    func testClientCountdownNeverEndsTheSession() async throws {
        // The hub says the window is over (expires_in_ms 0) but hasn't decided yet.
        hub.scriptStart(.success(EnrollmentFixtures.session(.waitingForHeartbeat, expiresInMs: 0)))
        hub.scriptStatus(.success(EnrollmentFixtures.session(.waitingForHeartbeat, expiresInMs: 0)))
        let controller = makeController()
        controller.start(eui64: EnrollmentFixtures.eui64)
        try await eventually { self.hub.recorded(.status).count >= 3 }
        XCTAssertEqual(runningState(controller), .waitingForHeartbeat, "only the hub's answer ends it")
        XCTAssertNotNil(controller.pskd)
        controller.leave()
    }

    func testAPollThatFailsForAMomentKeepsFollowing() async throws {
        hub.scriptStart(.success(EnrollmentFixtures.session(.preparing)))
        hub.scriptStatus(.failure(.unreachable("timeout")), .failure(.unavailable("startup")), .success(EnrollmentFixtures.session(.expired)))
        let controller = makeController()
        controller.start(eui64: EnrollmentFixtures.eui64)
        try await eventually { controller.pollProblem != nil }
        XCTAssertNotNil(controller.pskd, "the session still runs on the hub")
        try await eventually { self.finishedState(controller) == .expired }
        XCTAssertNil(controller.pollProblem)
    }

    // MARK: - Cancel

    func testCancelSendsOneDeleteAndShowsTheHubsAnswer() async throws {
        hub.scriptStart(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        hub.scriptStatus(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled, joinerEntry: "removing")))
        let controller = makeController()
        controller.start(eui64: EnrollmentFixtures.eui64)
        try await eventually { self.runningState(controller) != nil }
        controller.copyCode()
        XCTAssertEqual(clipboard.copied.count, 1)

        controller.cancel()
        controller.cancel()
        try await eventually { self.finishedState(controller) != nil }
        XCTAssertEqual(finishedState(controller), .cancelled)
        let deletes = hub.recorded(.cancel)
        XCTAssertEqual(deletes.count, 1, "a second tap sends nothing")
        XCTAssertEqual(deletes.first?.sessionID, EnrollmentFixtures.sessionID)
        XCTAssertEqual(deletes.first?.token, "token-A")
        XCTAssertNil(controller.pskd)
        XCTAssertEqual(clipboard.clearCount, 1, "the copied PSKd is removed")

        let polls = hub.recorded(.status).count
        try await settle()
        XCTAssertEqual(hub.recorded(.status).count, polls)
    }

    func testCancelLosingTheRaceShowsTheHubsFinalState() async throws {
        hub.scriptStart(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        hub.scriptStatus(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        hub.scriptCancel(.failure(.sessionAlreadyFinal(EnrollmentFixtures.session(.heartbeatReceived))))
        let controller = makeController()
        controller.start(eui64: EnrollmentFixtures.eui64)
        try await eventually { self.runningState(controller) != nil }
        controller.cancel()
        try await eventually { self.finishedState(controller) != nil }
        XCTAssertEqual(finishedState(controller), .heartbeatReceived, "the hub's word, not the tap")
    }

    func testACancelThatDoesNotGetThroughKeepsTheSession() async throws {
        hub.scriptStart(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        hub.scriptStatus(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        hub.scriptCancel(.failure(.unreachable("timeout")))
        let controller = makeController()
        controller.start(eui64: EnrollmentFixtures.eui64)
        try await eventually { self.runningState(controller) != nil }
        controller.cancel()
        try await eventually { controller.pollProblem == .unreachable("timeout") }
        XCTAssertEqual(runningState(controller), .waitingForHeartbeat)
        XCTAssertTrue(controller.canCancel, "can be cancelled again")
        controller.leave()
    }

    // MARK: - 409

    func testAnotherDevicesSessionRefusesTheStart() async throws {
        hub.scriptStart(.failure(.enrollmentInProgress(ownSession: nil)))
        let controller = makeController()
        controller.start(eui64: EnrollmentFixtures.eui64)
        try await eventually { controller.phase != .starting }
        XCTAssertEqual(controller.phase, .failed(.request(.enrollmentInProgress(ownSession: nil))))
        XCTAssertNil(controller.pskd, "a refused code is never shown")
        XCTAssertTrue(controller.canStart)
    }

    func testThisDevicesEarlierSessionIsFollowedWithoutAnyCode() async throws {
        let earlier = EnrollmentFixtures.session(.waitingForHeartbeat, id: EnrollmentFixtures.otherSessionID)
        hub.scriptStart(.failure(.enrollmentInProgress(ownSession: earlier)))
        hub.scriptStatus(.success(earlier))
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled, id: EnrollmentFixtures.otherSessionID)))
        let controller = makeController()
        controller.start(eui64: EnrollmentFixtures.eui64)
        try await eventually { if case .earlierSessionRunning = controller.phase { true } else { false } }
        XCTAssertNil(controller.pskd, "the new code was not accepted; the earlier one is gone")
        XCTAssertFalse(controller.canStart)
        try await eventually { !self.hub.recorded(.status).isEmpty }
        XCTAssertEqual(hub.recorded(.status).first?.sessionID, EnrollmentFixtures.otherSessionID)

        controller.cancel()
        try await eventually { self.finishedState(controller) == .cancelled }
        XCTAssertEqual(hub.recorded(.cancel).map(\.sessionID), [EnrollmentFixtures.otherSessionID])
    }

    func testStartingTwiceSendsOnePost() async throws {
        hub.holdStarts()
        hub.scriptStart(.success(EnrollmentFixtures.session(.preparing)))
        hub.scriptStatus(.success(EnrollmentFixtures.session(.preparing)))
        let controller = makeController()
        controller.start(eui64: EnrollmentFixtures.eui64)
        controller.start(eui64: EnrollmentFixtures.eui64)
        try await eventually { self.hub.heldCount == 1 }
        XCTAssertEqual(hub.recorded(.start).count, 1)
        hub.releaseHeld()
        try await eventually { self.runningState(controller) != nil }
        controller.start(eui64: EnrollmentFixtures.eui64)
        try await settle()
        XCTAssertEqual(hub.recorded(.start).count, 1, "no second session while one runs")
        controller.leave()
    }

    // MARK: - Who may start

    func testIneligibleSourcesSendNothing() async throws {
        let cases: [(PowerBaseEnrollmentController.Target, PowerBaseEnrollmentController.Ineligibility)] = [
            (.init(hubID: nil, baseURL: nil, isSimulated: true, isPaired: false), .simulatedData),
            (.init(hubID: nil, baseURL: EnrollmentFixtures.urlA, isSimulated: false, isPaired: false), .typedAddress),
            (.init(hubID: EnrollmentFixtures.hubA, baseURL: nil, isSimulated: false, isPaired: true), .noAddress),
            (.init(hubID: EnrollmentFixtures.hubA, baseURL: EnrollmentFixtures.urlA, isSimulated: false, isPaired: false), .notPaired),
        ]
        for (target, reason) in cases {
            let controller = makeController(target: target)
            XCTAssertEqual(controller.ineligibility, reason)
            XCTAssertFalse(controller.canStart)
            controller.start(eui64: EnrollmentFixtures.eui64)
            XCTAssertEqual(controller.phase, .idle)
        }
        try await settle()
        XCTAssertTrue(hub.recorded.isEmpty)
    }

    func testAMissingCredentialSendsNothing() async throws {
        try credentials.deleteCredential(forHubID: EnrollmentFixtures.hubA)
        let controller = makeController()
        controller.start(eui64: EnrollmentFixtures.eui64)
        XCTAssertEqual(controller.phase, .failed(.credentialUnavailable))
        try await settle()
        XCTAssertTrue(hub.recorded.isEmpty)
    }

    func testMalformedEUI64SendsNothing() async throws {
        let controller = makeController()
        for bad in ["00:12:4b:00:01:a2:b3:c4", "*", "0000000000000000"] {
            controller.start(eui64: bad)
            XCTAssertEqual(controller.phase, .failed(.invalidEUI64))
        }
        try await settle()
        XCTAssertTrue(hub.recorded.isEmpty)
    }

    func testNoSecureRandomnessSendsNothing() async throws {
        let controller = PowerBaseEnrollmentController(transport: hub, credentials: credentials, clipboard: clipboard, pollInterval: .milliseconds(10), randomBytes: { _ in nil })
        controller.targetDidChange(EnrollmentFixtures.pairedTarget())
        controller.start(eui64: EnrollmentFixtures.eui64)
        XCTAssertEqual(controller.phase, .failed(.randomnessUnavailable))
        try await settle()
        XCTAssertTrue(hub.recorded.isEmpty)
    }

    // MARK: - Certificate

    func testAChangedCertificateStopsEverything() async throws {
        hub.scriptStart(.failure(.certificateMismatch))
        let controller = makeController()
        controller.start(eui64: EnrollmentFixtures.eui64)
        try await eventually { controller.phase != .starting }
        XCTAssertEqual(controller.phase, .failed(.request(.certificateMismatch)))
        XCTAssertNil(controller.pskd)
    }

    func testAChangedCertificateWhilePollingEndsWithoutAnotherRequest() async throws {
        hub.scriptStart(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        hub.scriptStatus(.failure(.certificateMismatch))
        let controller = makeController()
        controller.start(eui64: EnrollmentFixtures.eui64)
        try await eventually { controller.phase == .failed(.request(.certificateMismatch)) }
        XCTAssertNil(controller.pskd)
        let count = hub.recorded.count
        try await settle()
        XCTAssertEqual(hub.recorded.count, count, "no more polls and no DELETE to a server that failed the pin")
    }

    func testRevokedAccessWhilePollingEnds() async throws {
        hub.scriptStart(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        hub.scriptStatus(.failure(.unauthorized))
        let controller = makeController()
        controller.start(eui64: EnrollmentFixtures.eui64)
        try await eventually { controller.phase == .failed(.request(.unauthorized)) }
        XCTAssertNil(controller.pskd)
    }

    // MARK: - Leaving and switching

    func testLeavingStopsPollingAndCancelsOnTheOriginalHub() async throws {
        hub.scriptStart(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        hub.scriptStatus(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        let controller = makeController()
        controller.start(eui64: EnrollmentFixtures.eui64)
        try await eventually { !self.hub.recorded(.status).isEmpty }
        controller.copyCode()

        controller.leave()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNil(controller.pskd)
        XCTAssertEqual(clipboard.clearCount, 1)
        try await eventually { self.hub.recorded(.cancel).count == 1 }
        let delete = try XCTUnwrap(hub.recorded(.cancel).first)
        XCTAssertEqual(delete.baseURL, EnrollmentFixtures.urlA)
        XCTAssertEqual(delete.token, "token-A")
        XCTAssertEqual(delete.sessionID, EnrollmentFixtures.sessionID)

        let polls = hub.recorded(.status).count
        try await settle()
        XCTAssertEqual(hub.recorded(.status).count, polls, "no poll after leaving")
    }

    func testTheSameTargetAgainKeepsTheSession() async throws {
        // What the app going to the background looks like here: the source stays the same.
        hub.scriptStart(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        hub.scriptStatus(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        let controller = makeController()
        controller.start(eui64: EnrollmentFixtures.eui64)
        try await eventually { self.runningState(controller) != nil }
        controller.targetDidChange(EnrollmentFixtures.pairedTarget())
        XCTAssertEqual(runningState(controller), .waitingForHeartbeat)
        XCTAssertNotNil(controller.pskd)
        XCTAssertTrue(hub.recorded(.cancel).isEmpty)
        controller.leave()
    }

    func testTheSameHubAtANewAddressCarriesOnThereWithTheSamePin() async throws {
        hub.scriptStart(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        hub.scriptStatus(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
        let controller = makeController()
        controller.start(eui64: EnrollmentFixtures.eui64)
        try await eventually { self.runningState(controller) != nil }
        controller.targetDidChange(EnrollmentFixtures.pairedTarget(url: EnrollmentFixtures.urlAMoved))
        let before = hub.recorded(.status).count
        try await eventually { self.hub.recorded(.status).count > before + 1 }
        let latest = try XCTUnwrap(hub.recorded(.status).last)
        XCTAssertEqual(latest.baseURL, EnrollmentFixtures.urlAMoved)
        XCTAssertEqual(latest.pinnedCertificate, String(repeating: "c", count: 64))
        XCTAssertEqual(latest.token, "token-A")
        XCTAssertNotNil(controller.pskd)
        controller.leave()
    }

    func testALatePostAnswerAfterSwitchingHubsIsNotShownAndIsCancelledOnTheOriginalHub() async throws {
        hub.holdStarts()
        hub.scriptStart(.success(EnrollmentFixtures.session(.preparing)))
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        let controller = makeController()
        controller.start(eui64: EnrollmentFixtures.eui64)
        try await eventually { self.hub.heldCount == 1 }

        controller.targetDidChange(EnrollmentFixtures.pairedTarget(hubID: EnrollmentFixtures.hubB, url: EnrollmentFixtures.urlB))
        XCTAssertEqual(controller.phase, .failed(.sourceChanged))
        hub.releaseHeld()

        try await eventually { self.hub.recorded(.cancel).count == 1 }
        XCTAssertEqual(controller.phase, .failed(.sourceChanged), "the old hub's answer never reaches the new screen")
        XCTAssertNil(controller.pskd)
        let delete = try XCTUnwrap(hub.recorded(.cancel).first)
        XCTAssertEqual(delete.baseURL, EnrollmentFixtures.urlA)
        XCTAssertEqual(delete.token, "token-A", "the original hub's credential")
        try await settle()
        XCTAssertFalse(hub.recorded.contains { $0.baseURL == EnrollmentFixtures.urlB || $0.token == "token-B" }, "nothing goes to the other hub")
        XCTAssertTrue(hub.recorded(.status).isEmpty)
    }

    func testALatePollAnswerAfterSwitchingToSimulatedDataIsIgnored() async throws {
        hub.scriptStart(.success(EnrollmentFixtures.session(.preparing)))
        hub.scriptStatus(.success(EnrollmentFixtures.session(.heartbeatReceived)))
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        hub.holdStatus()
        let controller = makeController()
        controller.start(eui64: EnrollmentFixtures.eui64)
        try await eventually { self.hub.heldCount == 1 }

        controller.targetDidChange(.init(hubID: nil, baseURL: nil, isSimulated: true, isPaired: false))
        XCTAssertEqual(controller.phase, .failed(.sourceChanged))
        XCTAssertNil(controller.pskd)
        try await eventually { self.hub.recorded(.cancel).count == 1 }
        XCTAssertEqual(hub.recorded(.cancel).first?.baseURL, EnrollmentFixtures.urlA)

        hub.releaseHeld()
        try await settle()
        XCTAssertEqual(controller.phase, .failed(.sourceChanged), "a late heartbeat_received is not shown for the new source")
        XCTAssertEqual(hub.recorded(.status).count, 1, "polling stopped")
    }

    func testAnotherHubClearsThePreviousHubsResult() async throws {
        hub.scriptStart(.success(EnrollmentFixtures.session(.expired)))
        let controller = makeController()
        controller.start(eui64: EnrollmentFixtures.eui64)
        try await eventually { self.finishedState(controller) == .expired }
        controller.targetDidChange(EnrollmentFixtures.pairedTarget(hubID: EnrollmentFixtures.hubB, url: EnrollmentFixtures.urlB))
        XCTAssertEqual(controller.phase, .idle)
    }
}
/// The test screen's own string table (left out of Release builds) is complete in every language.
final class PowerBaseEnrollmentLocalizationTests: XCTestCase {
    private func table(_ language: String) -> [String: String] {
        guard let url = Bundle.main.url(forResource: "PowerBaseEnrollmentDebug.strings", withExtension: nil, subdirectory: nil, localization: language),
              let dictionary = NSDictionary(contentsOf: url) as? [String: String] else { return [:] }
        return dictionary
    }

    private func placeholders(_ format: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?(lld|ld|d|@)")
        return regex.matches(in: format, range: NSRange(format.startIndex..., in: format)).map { (format as NSString).substring(with: $0.range) }
    }

    func testEnglishAndSpanishTranslateEveryKeyWithTheSamePlaceholders() {
        let english = table("en")
        let spanish = table("es")
        XCTAssertGreaterThan(english.count, 40)
        XCTAssertEqual(Set(english.keys), Set(spanish.keys))
        for (key, value) in english {
            XCTAssertEqual(placeholders(value), placeholders(key), "en: \(key)")
            XCTAssertEqual(placeholders(spanish[key] ?? ""), placeholders(key), "es: \(key)")
            XCTAssertNotEqual(value, key, "en is translated: \(key)")
        }
    }
}
#endif
