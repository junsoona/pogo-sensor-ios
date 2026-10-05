#if DEBUG
import PowerBaseBLEKit
import XCTest
@testable import PogoHome

/// Bridge endpoint delivery in the DEBUG "BLE 등록 시험": what the hub is asked, how its answer is
/// read, and what the board is (and is not) sent -- with a board or a hub that cannot do it, a
/// session without an endpoint, and an endpoint that changes. Scripted hub and board; no Bluetooth,
/// no network.

/// The request and the answers, as bytes and JSON.
final class PowerBaseEnrollmentBridgeEndpointCodingTests: XCTestCase {
    private func sessionJSON(_ endpoint: String?, state: String = "waiting_for_heartbeat") -> String {
        let tail = endpoint.map { #","bridge_endpoint":"# + $0 } ?? ""
        return #"{"session_id":"5f0c1d2e3f405162738495a6b7c8d9e0","eui64":"00124b0001a2b3c4","state":""# + state
            + #"","finished":false,"joiner_entry":"allowed","error":null,"window_seconds":120,"created_at_unix_ms":1790000000000,"expires_at_unix_ms":1790000120000,"expires_in_ms":118250,"heartbeat_received_at_unix_ms":null,"started_by_device_id":"0123456789abcdef""#
            + tail + "}"
    }

    private func decode(_ json: String) throws -> PowerBaseEnrollmentSession {
        try URLSessionPowerBaseEnrollmentTransport.decodeSession(Data(json.utf8), deviceID: EnrollmentFixtures.deviceID)
    }

    func testTheRequestAsksForTheEndpointAndCarriesNoAddress() throws {
        let plain = try URLSessionPowerBaseEnrollmentTransport.startBody(eui64: "00124b0001a2b3c4", pskd: "J01NME7K2ABC")
        XCTAssertEqual(String(decoding: plain, as: UTF8.self), #"{"eui64":"00124b0001a2b3c4","pskd":"J01NME7K2ABC"}"#,
                       "the request without the option is byte for byte what it was")
        let asking = try URLSessionPowerBaseEnrollmentTransport.startBody(eui64: "00124b0001a2b3c4", pskd: "J01NME7K2ABC", bridgeEndpointVersion: 1)
        XCTAssertEqual(String(decoding: asking, as: UTF8.self), #"{"bridge_endpoint_version":1,"eui64":"00124b0001a2b3c4","pskd":"J01NME7K2ABC"}"#,
                       "exactly the two fields and the option: no address, no port, no URL")
    }

    func testTheHubsEndpointIsDecodedStrictly() throws {
        let good = #"{"version":1,"address":"fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79","port":5701}"#
        let session = try decode(sessionJSON(good))
        XCTAssertEqual(session.bridgeEndpoint, EnrollmentFixtures.bridgeEndpoint)
        XCTAssertEqual(session.bridgeEndpoint?.port, 5701)
        XCTAssertEqual(session.bridgeEndpoint.map { [UInt8]($0.address) },
                       [0xfd, 0x11, 0x22, 0x33, 0x44, 0x55, 0x00, 0x00, 0x8c, 0x1f, 0x2e, 0x3d, 0x4c, 0x5b, 0x6a, 0x79])

        XCTAssertNil(try decode(sessionJSON("null", state: "preparing")).bridgeEndpoint, "null while preparing: not established yet")
        XCTAssertNil(try decode(sessionJSON(nil)).bridgeEndpoint, "no key: a session started without the option")
        // Unknown additional fields inside the object are ignored, like everywhere in the API.
        XCTAssertEqual(try decode(sessionJSON(#"{"version":1,"address":"fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79","port":5701,"future":true}"#)).bridgeEndpoint,
                       EnrollmentFixtures.bridgeEndpoint)

        func endpoint(address: String, port: String = "5701", version: String = "1") -> String {
            #"{"version":"# + version + #","address":"# + address + #","port":"# + port + "}"
        }
        let refused: [(String, String)] = [
            ("IPv4", endpoint(address: #""192.168.1.10""#)),
            ("IPv4-mapped", endpoint(address: #""::ffff:192.168.1.10""#)),
            ("IPv4-mapped, hex", endpoint(address: #""::ffff:c0a8:10a""#)),
            ("IPv4-compatible", endpoint(address: #""::c0a8:10a""#)),
            ("unspecified", endpoint(address: #""::""#)),
            ("loopback", endpoint(address: #""::1""#)),
            ("multicast", endpoint(address: #""ff03::1""#)),
            ("link-local", endpoint(address: #""fe80::8c1f:2e3d:4c5b:6a79""#)),
            ("zone id", endpoint(address: #""fe80::8c1f:2e3d:4c5b:6a79%wpan0""#)),
            ("zone id on a mesh-local address", endpoint(address: #""fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79%en0""#)),
            ("URL", endpoint(address: #""coap://[fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79]:5701""#)),
            ("the hub's HTTP API URL", endpoint(address: #""http://192.168.1.10:8787""#)),
            ("brackets", endpoint(address: #""[fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79]""#)),
            ("host name", endpoint(address: #""jogakbo-hub.local""#)),
            ("global address", endpoint(address: #""2001:db8::1""#)),
            ("an RLOC", endpoint(address: #""fd11:2233:4455:0:0:ff:fe00:4c00""#)),
            ("an ALOC", endpoint(address: #""fd11:2233:4455:0:0:ff:fe00:fc00""#)),
            ("upper case", endpoint(address: #""FD11:2233:4455:0:8C1F:2E3D:4C5B:6A79""#)),
            ("empty address", endpoint(address: #""""#)),
            ("address is a number", endpoint(address: "5701")),
            ("address is null", endpoint(address: "null")),
            ("port 0", endpoint(address: #""fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79""#, port: "0")),
            ("port 65536", endpoint(address: #""fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79""#, port: "65536")),
            ("negative port", endpoint(address: #""fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79""#, port: "-1")),
            ("port as a string", endpoint(address: #""fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79""#, port: #""5701""#)),
            ("a fractional port", endpoint(address: #""fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79""#, port: "5701.5")),
            ("format version 2", endpoint(address: #""fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79""#, version: "2")),
            ("format version 0", endpoint(address: #""fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79""#, version: "0")),
            ("version as a string", endpoint(address: #""fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79""#, version: #""1""#)),
            ("no version", #"{"address":"fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79","port":5701}"#),
            ("no address", #"{"version":1,"port":5701}"#),
            ("no port", #"{"version":1,"address":"fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79"}"#),
            ("a bare string", #""fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79""#),
            ("an array", #"["fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79",5701]"#),
        ]
        for (what, json) in refused {
            XCTAssertThrowsError(try decode(sessionJSON(json)), what) {
                XCTAssertEqual($0 as? PowerBaseEnrollmentError, .badResponse("session"), "\(what): the whole answer is refused, nothing of it is used")
            }
        }
    }

    func testAHubWithoutTheFeatureIsToldApartFromOtherRefusals() {
        func map(_ status: Int, _ body: String) -> PowerBaseEnrollmentError {
            URLSessionPowerBaseEnrollmentTransport.bridgeEndpointStartError(status: status, data: Data(body.utf8), deviceID: EnrollmentFixtures.deviceID)
        }
        XCTAssertEqual(map(400, #"{"error":"invalid_request"}"#), .bridgeEndpointNotSupported,
                       "a bridge from before the option accepts exactly two fields")
        XCTAssertEqual(map(422, #"{"error":"unsupported_bridge_endpoint_version"}"#), .bridgeEndpointNotSupported)
        XCTAssertEqual(map(422, #"{"error":"invalid_pskd"}"#), .rejected("invalid_pskd"))
        XCTAssertEqual(map(422, #"{"error":"invalid_eui64"}"#), .rejected("invalid_eui64"))
        XCTAssertEqual(map(400, #"{"error":"malformed_headers"}"#), .rejected("malformed_headers"))
        XCTAssertEqual(map(503, #"{"error":"enrollment_unavailable","reason":"bridge_endpoint"}"#), .unavailable("bridge_endpoint"))
        XCTAssertEqual(map(404, #"{"error":"enrollment_disabled"}"#), .enrollmentDisabled)
        XCTAssertEqual(map(409, #"{"error":"power_base_already_connected"}"#), .powerBaseAlreadyConnected)
        XCTAssertEqual(map(401, ""), .unauthorized)
        // The request without the option keeps its own mapping.
        XCTAssertEqual(URLSessionPowerBaseEnrollmentTransport.error(status: 400, data: Data(#"{"error":"invalid_request"}"#.utf8), deviceID: EnrollmentFixtures.deviceID),
                       .rejected("invalid_request"))
    }
}

@MainActor
final class PowerBaseEnrollmentBridgeEndpointControllerTests: XCTestCase {
    typealias Controller = PowerBaseEnrollmentBLEController

    private var log: EnrollmentEventLog!
    private var hub: FakeEnrollmentHub!
    private var board: FakeBoard!
    private var provider: FakeBLEBoardProvider!
    private var credentials: InMemoryHubCredentialStore!

    override func setUp() async throws {
        log = EnrollmentEventLog()
        hub = FakeEnrollmentHub()
        board = FakeBoard(log: log)
        provider = FakeBLEBoardProvider(board: board, log: log)
        credentials = InMemoryHubCredentialStore([
            EnrollmentFixtures.credential(hubID: EnrollmentFixtures.hubA, token: "token-A"),
            EnrollmentFixtures.credential(hubID: EnrollmentFixtures.hubB, token: "token-B", certificate: String(repeating: "d", count: 64)),
        ])
    }

    private func makeController(maxReconnects: Int = 3) -> Controller {
        let controller = Controller(
            provider: provider, transport: LoggedEnrollmentHub(hub: hub, log: log), credentials: credentials,
            pollInterval: .milliseconds(10), boardPollInterval: .milliseconds(10), leaveGrace: .milliseconds(40),
            quietScanPeriod: .milliseconds(30), maxReconnects: maxReconnects
        )
        controller.targetDidChange(EnrollmentFixtures.pairedTarget())
        controller.activate()
        return controller
    }

    private func start(_ controller: Controller) {
        controller.start(boardID: FakeBLEBoardProvider.boardID, expectedEUI64: EnrollmentFixtures.eui64, setupCode: EnrollmentFixtures.setupCode)
    }

    private func isJoining(_ controller: Controller) -> Bool {
        if case .joining = controller.phase { true } else { false }
    }

    private func failure(_ controller: Controller) -> Controller.Failure? {
        if case let .failed(failure) = controller.phase { return failure }
        return nil
    }

    private func outcome(_ controller: Controller) -> Controller.Outcome? {
        if case let .finished(outcome) = controller.phase { return outcome }
        return nil
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(80))
    }

    private typealias Session = PowerBaseEnrollmentSession.State

    private func answer(_ state: Session, _ endpoint: EnrollmentFixtures.Endpoint = .asTheHubSends) -> Result<PowerBaseEnrollmentSession, PowerBaseEnrollmentError> {
        .success(EnrollmentFixtures.session(state, bridgeEndpoint: endpoint))
    }

    // MARK: - The hub's endpoint reaches the board, once

    func testTheBoardIsGivenExactlyTheEndpointOfTheWaitingSession() async throws {
        hub.scriptStart(answer(.preparing))
        hub.scriptStatus(answer(.preparing), answer(.preparing), answer(.waitingForHeartbeat))
        let controller = makeController()
        start(controller)
        try await eventually { self.hub.recorded(.status).count >= 2 }
        XCTAssertTrue(board.starts.isEmpty, "nothing goes to the board while the hub is preparing and has no endpoint")
        XCTAssertNil(controller.bridgeEndpoint)

        try await eventually { self.isJoining(controller) }
        let posts = hub.recorded(.start)
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?.asksForBridgeEndpoint, true, "the hub is asked for its bridge endpoint")
        XCTAssertEqual(board.starts.count, 1, "exactly one pb-start")
        XCTAssertEqual(board.starts.first?.endpoint, EnrollmentFixtures.bridgeEndpoint, "with the address and port of the hub's session answer")
        XCTAssertEqual(board.starts.first?.endpoint.port, 5701, "the hub's ingest port, not a number built into the app")
        XCTAssertEqual(board.starts.first?.pskd, posts.first?.pskd, "and the PSKd the hub was given")
        XCTAssertEqual(controller.bridgeEndpoint, EnrollmentFixtures.bridgeEndpoint)
        // The endpoint is not derived from where the app reaches the hub.
        XCTAssertFalse(EnrollmentFixtures.urlA.absoluteString.contains(EnrollmentFixtures.bridgeEndpoint.addressText))

        let order = log.all
        let lastHubAnswer = try XCTUnwrap(order.lastIndex(of: "hub GET"))
        let challenge = try XCTUnwrap(order.firstIndex(of: "board status+challenge"))
        let boardStart = try XCTUnwrap(order.firstIndex(of: "board start"))
        XCTAssertLessThan(try XCTUnwrap(order.firstIndex(of: "hub POST")), challenge, "the challenge is asked for after the hub session exists")
        XCTAssertLessThan(challenge, boardStart)
        XCTAssertGreaterThanOrEqual(lastHubAnswer, 0)

        // Board progress is not success; only the hub's heartbeat is.
        board.advance(to: .enrolled, state: .enrolled, result: 17)
        try await settle()
        XCTAssertNil(outcome(controller), "ACCEPTED, the Joiner and the board's 'enrolled' never end the run as a success")
        hub.replaceStatus(answer(.heartbeatReceived))
        try await eventually { self.outcome(controller)?.session.state == .heartbeatReceived }
        XCTAssertEqual(board.starts.count, 1)
    }

    func testAnEndpointAlreadyThereWhilePreparingIsNotDeliveredBeforeTheHubWaits() async throws {
        hub.scriptStart(answer(.preparing, .some(EnrollmentFixtures.bridgeEndpoint)))
        hub.scriptStatus(answer(.preparing, .some(EnrollmentFixtures.bridgeEndpoint)), answer(.preparing, .some(EnrollmentFixtures.bridgeEndpoint)))
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        let controller = makeController()
        start(controller)
        try await eventually { self.hub.recorded(.status).count >= 3 }
        XCTAssertTrue(board.starts.isEmpty, "an endpoint alone is not the hub's go-ahead: the Joiner is not open yet")
        XCTAssertEqual(board.challengeRequests, 0, "no challenge is taken early either")
        controller.cancel()
        try await eventually { !controller.isBusy }
    }

    func testALostStartAnswerSendsTheSameRequestWithTheSameEndpointAgain() async throws {
        hub.scriptStart(answer(.waitingForHeartbeat))
        hub.scriptStatus(answer(.waitingForHeartbeat))
        board.loseNextStartAnswer(reachesBoard: false)
        let controller = makeController()
        start(controller)
        try await eventually { self.isJoining(controller) }
        XCTAssertEqual(board.starts.count, 2, "the start whose answer was lost and never arrived is sent once more")
        XCTAssertEqual(Set(board.starts.map(\.requestID)).count, 1, "under the same request id")
        XCTAssertEqual(Set(board.starts.map(\.endpoint)), [EnrollmentFixtures.bridgeEndpoint], "with the same endpoint")
        XCTAssertEqual(Set(board.starts.map(\.pskd)).count, 1, "and the same PSKd")
        XCTAssertEqual(hub.recorded(.start).count, 1, "no second hub session")
        XCTAssertEqual(board.joinerStarts, 1)
    }

    // MARK: - A board or a hub that cannot do it

    func testABoardWithoutTheCapabilityStopsTheRunBeforeAnyHubSession() async throws {
        board.set(capabilities: [])
        let controller = makeController()
        start(controller)
        try await eventually { self.failure(controller) != nil }
        XCTAssertEqual(failure(controller), .boardNeedsUpdate)
        try await settle()
        XCTAssertTrue(hub.recorded.isEmpty, "no hub session was asked for")
        XCTAssertTrue(board.starts.isEmpty, "no start of any kind reached the board")
        XCTAssertEqual(board.challengeRequests, 0)
        XCTAssertEqual(board.closed.count, 1, "the connection is closed")
        XCTAssertFalse(controller.isBusy)
        XCTAssertNil(controller.bridgeEndpoint)
    }

    func testAHubWithoutTheFeatureEndsTheRunWithoutFallingBack() async throws {
        hub.scriptStart(.failure(.bridgeEndpointNotSupported))
        // Would be the answer if the app asked again without the option. It must never be used.
        hub.scriptStart(answer(.waitingForHeartbeat, .none))
        let controller = makeController()
        start(controller)
        try await eventually { self.failure(controller) != nil }
        XCTAssertEqual(failure(controller), .hub(.bridgeEndpointNotSupported, board: nil))
        try await settle()
        XCTAssertEqual(hub.recorded(.start).count, 1, "one POST: not repeated without the option")
        XCTAssertEqual(hub.recorded(.start).first?.asksForBridgeEndpoint, true)
        XCTAssertTrue(hub.recorded(.status).isEmpty)
        XCTAssertTrue(hub.recorded(.cancel).isEmpty, "there is no session to cancel")
        XCTAssertTrue(board.starts.isEmpty, "the board is given nothing: no address is guessed")
        XCTAssertEqual(board.challengeRequests, 0)
        XCTAssertFalse(controller.isBusy)
    }

    func testAHubThatWaitsWithoutAnEndpointGetsNoStartAndIsCancelled() async throws {
        hub.scriptStart(answer(.waitingForHeartbeat, .none))
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled, bridgeEndpoint: .none)))
        let controller = makeController()
        start(controller)
        try await eventually { self.failure(controller) != nil }
        guard case let .hubEndpoint(problem, cleanup)? = failure(controller) else { return XCTFail("\(String(describing: failure(controller)))") }
        XCTAssertEqual(problem, .missing)
        XCTAssertEqual(cleanup.board, .notNeeded, "nothing was ever sent to the board")
        XCTAssertEqual(hub.recorded(.cancel).count, 1, "the session that could not be used is cancelled on the hub")
        XCTAssertTrue(board.starts.isEmpty)
        XCTAssertEqual(board.challengeRequests, 0, "not even a challenge was taken")
    }

    // MARK: - An endpoint that changes

    func testAnEndpointThatChangesBeforeDeliveryIsNeverSent() async throws {
        hub.scriptStart(answer(.preparing, .some(EnrollmentFixtures.bridgeEndpoint)))
        hub.scriptStatus(answer(.waitingForHeartbeat, .some(EnrollmentFixtures.otherBridgeEndpoint)))
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        let controller = makeController()
        start(controller)
        try await eventually { self.failure(controller) != nil }
        guard case let .hubEndpoint(problem, cleanup)? = failure(controller) else { return XCTFail("\(String(describing: failure(controller)))") }
        XCTAssertEqual(problem, .changed)
        XCTAssertEqual(cleanup.board, .notNeeded)
        XCTAssertTrue(board.starts.isEmpty, "neither the first endpoint nor the changed one is delivered")
        XCTAssertEqual(hub.recorded(.cancel).count, 1)
    }

    func testAnEndpointThatChangesAfterDeliveryIsNotSentAsANewStart() async throws {
        hub.scriptStart(answer(.waitingForHeartbeat))
        hub.scriptStatus(answer(.waitingForHeartbeat), answer(.waitingForHeartbeat), answer(.waitingForHeartbeat, .some(EnrollmentFixtures.otherBridgeEndpoint)))
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        let controller = makeController()
        start(controller)
        try await eventually { self.failure(controller) != nil }
        guard case let .hubEndpoint(problem, cleanup)? = failure(controller) else { return XCTFail("\(String(describing: failure(controller)))") }
        XCTAssertEqual(problem, .changed)
        XCTAssertEqual(board.starts.count, 1, "the one start that was sent; no second one with the other endpoint")
        XCTAssertEqual(board.starts.first?.endpoint, EnrollmentFixtures.bridgeEndpoint)
        XCTAssertEqual(Set(board.cancels.map(\.requestID)), Set(board.starts.map(\.requestID)), "the board is asked to cancel that same request")
        XCTAssertEqual(cleanup.board, .taken)
        XCTAssertEqual(hub.recorded(.cancel).count, 1, "and the hub its session")
        try await settle()
        XCTAssertEqual(board.starts.count, 1)
        XCTAssertEqual(board.joinerStarts, 1)
    }

    func testAnEndpointThatDisappearsIsAChangeToo() async throws {
        hub.scriptStart(answer(.waitingForHeartbeat))
        hub.scriptStatus(answer(.waitingForHeartbeat), answer(.waitingForHeartbeat, .none))
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        let controller = makeController()
        start(controller)
        try await eventually { self.failure(controller) != nil }
        guard case let .hubEndpoint(problem, _)? = failure(controller) else { return XCTFail("\(String(describing: failure(controller)))") }
        XCTAssertEqual(problem, .changed)
        XCTAssertEqual(board.starts.count, 1)
    }

    func testTheHubsFinalStateDecidesEvenIfItsLastAnswerCarriesAnotherEndpoint() async throws {
        hub.scriptStart(answer(.waitingForHeartbeat))
        hub.scriptStatus(answer(.waitingForHeartbeat), answer(.heartbeatReceived, .some(EnrollmentFixtures.otherBridgeEndpoint)))
        let controller = makeController()
        start(controller)
        try await eventually { self.outcome(controller) != nil }
        XCTAssertEqual(outcome(controller)?.session.state, .heartbeatReceived, "a final state is the result; nothing more is sent after it")
        XCTAssertEqual(board.starts.count, 1)
        XCTAssertEqual(board.starts.first?.endpoint, EnrollmentFixtures.bridgeEndpoint)
        XCTAssertTrue(board.cancels.isEmpty)
    }

    // MARK: - What stays as it was

    func testAnEarlierSessionOfThisDeviceIsFollowedAndItsEndpointIsNotDelivered() async throws {
        // 409: this device's own session from an earlier start, whose PSKd this run does not have.
        hub.scriptStart(.failure(.enrollmentInProgress(ownSession: EnrollmentFixtures.session(.waitingForHeartbeat, id: EnrollmentFixtures.otherSessionID))))
        hub.scriptStatus(.success(EnrollmentFixtures.session(.waitingForHeartbeat, id: EnrollmentFixtures.otherSessionID)))
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled, id: EnrollmentFixtures.otherSessionID)))
        let controller = makeController()
        start(controller)
        try await eventually { if case .earlierHubSession = controller.phase { true } else { false } }
        try await settle()
        XCTAssertTrue(board.starts.isEmpty, "an endpoint is no reason to deliver a PSKd the hub does not expect")
        XCTAssertNil(controller.bridgeEndpoint)
        controller.cancel()
        try await eventually { !controller.isBusy }
    }

    func testABoardThatLostTheCapabilityAfterReconnectingIsNotSentAStart() async throws {
        hub.scriptStart(answer(.preparing))
        hub.scriptStatus(answer(.preparing), answer(.waitingForHeartbeat))
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        let controller = makeController()
        start(controller)
        try await eventually { self.hub.recorded(.start).count == 1 }
        // The connection drops and what answers afterwards is firmware without the capability.
        board.disconnect()
        board.set(capabilities: [])
        try await eventually { self.failure(controller) != nil }
        guard case let .boardProblem(problem, cleanup)? = failure(controller) else { return XCTFail("\(String(describing: failure(controller)))") }
        XCTAssertEqual(problem, .needsUpdate)
        XCTAssertEqual(cleanup.board, .notNeeded)
        XCTAssertTrue(board.starts.isEmpty, "no start was sent -- not the endpoint start, and not the earlier one in its place")
        XCTAssertEqual(hub.recorded(.cancel).count, 1, "the hub session is cancelled")
    }

    func testChangingTheHubDuringARunCleansUpOnTheOriginalHubAndDeliversNothingMore() async throws {
        hub.scriptStart(answer(.waitingForHeartbeat))
        hub.scriptStatus(answer(.waitingForHeartbeat))
        hub.scriptCancel(.success(EnrollmentFixtures.session(.cancelled)))
        let controller = makeController()
        var reports: [Controller.CleanupReport] = []
        controller.onCleanupReport = { reports.append($0) }
        start(controller)
        try await eventually { self.isJoining(controller) }
        controller.targetDidChange(EnrollmentFixtures.pairedTarget(hubID: EnrollmentFixtures.hubB, url: EnrollmentFixtures.urlB))
        XCTAssertEqual(controller.phase, .failed(.sourceChanged))
        XCTAssertNil(controller.bridgeEndpoint, "the endpoint belonged to the previous hub's session")
        try await eventually { reports.count == 1 }
        XCTAssertEqual(hub.recorded(.cancel).first?.baseURL, EnrollmentFixtures.urlA, "the session is cancelled on the hub it was started on")
        XCTAssertEqual(hub.recorded(.cancel).first?.token, "token-A")
        XCTAssertEqual(board.starts.count, 1, "nothing more is delivered")
        XCTAssertEqual(board.cancels.count, 1, "the board's request is cancelled by its own id")
        XCTAssertEqual(hub.recorded(.start).count, 1, "no session is started on the new hub")
    }
}
#endif
