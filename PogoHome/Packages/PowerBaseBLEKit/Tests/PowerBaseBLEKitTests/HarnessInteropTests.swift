#if DEBUG && os(macOS)
import XCTest
@testable import ESPProvisionSecurity2
@testable import PowerBaseBLEKit

/// The Swift client the app uses (`PowerBaseBLEBoardClient` driving the vendored Espressif
/// Security 2 code) against the firmware repository's host harness: ESP-IDF's real protocomm.c,
/// security2.c and esp_srp.c plus the real BLE enrollment service, with a credential record made
/// by the real prepare tool. Run with `swift test` on the Mac; see README.md.
///
/// This is NOT a BLE test. The "connection" is the harness's pipe; advertising, GATT long writes
/// and reads, MTU, CoreBluetooth and radio coexistence are not exercised by anything here.
final class HarnessInteropTests: XCTestCase {
    private static let pskd = "J01NME7K"
    private static let otherPSKd = "ANY0THER1"
    private static let authOK: UInt8 = 0
    private static let stateWaiting: UInt8 = 0
    private static let stateJoining: UInt8 = 1
    private static let stateEnrolled: UInt8 = 3

    private var fixture: HarnessFixture!
    private var logURL: URL!
    private var harnesses: [Harness] = []

    override func setUpWithError() throws {
        fixture = try HarnessFixture.load()
        logURL = FileManager.default.temporaryDirectory.appendingPathComponent("pb-harness-\(UUID().uuidString).log")
    }

    override func tearDown() {
        harnesses.forEach { $0.quit() }
        harnesses = []
        if let logURL { try? FileManager.default.removeItem(at: logURL) }
    }

    /// One boot of the board, with the BLE enrollment service running.
    private func boot() throws -> Harness {
        let harness = try Harness(path: fixture.harnessPath, logURL: logURL)
        harnesses.append(harness)
        XCTAssertEqual(try harness.boot(eui64: fixture.eui64, record: fixture.record), Self.authOK, "the service starts for this board's record")
        return harness
    }

    /// A connection and a client that has read `proto-ver` and authenticated.
    private func authenticatedClient(_ harness: Harness, session: UInt32 = 1) async throws -> (PowerBaseBLEBoardClient, HarnessLink) {
        let link = HarnessLink(harness: harness, session: session)
        let client = PowerBaseBLEBoardClient(link: link)
        try await client.checkVersion()
        try await client.authenticate(eui64: fixture.eui64, setupCode: fixture.setupCode)
        return (client, link)
    }

    /// A challenge issued in `client`'s session.
    private func freshChallenge(_ client: PowerBaseBLEBoardClient, asking id: PowerBaseBLERequestID? = nil) async throws -> PowerBaseBLEChallenge {
        let status = try await client.status(issueChallenge: true, requestID: id)
        return try XCTUnwrap(status.challenge)
    }

    private func requestID(_ seed: UInt8) -> PowerBaseBLERequestID {
        PowerBaseBLERequestID(bytes: Data((0..<16).map { seed &+ UInt8($0) }))!
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

    // MARK: - Handshake and the three endpoints

    func testHandshakeThenEncryptedStatusStartAndCancelAgainstTheRealServer() async throws {
        let harness = try boot()
        XCTAssertTrue(try harness.connect(1))
        let started = Date()
        let (client, link) = try await authenticatedClient(harness)
        print("Swift Security 2 handshake against the host harness: \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        let established = await client.hasSession
        XCTAssertTrue(established, "SRP-6a completed and the client verified the board's proof")

        let handshake = link.exchanges.filter { $0.endpoint == .session }
        XCTAssertEqual(handshake.count, 2, "one handshake: two messages")
        XCTAssertEqual(Security2Handshake.clientPublicKey(inCommand0: handshake[0].request)?.count, 384)
        XCTAssertTrue(link.exchanges.allSatisfy { $0.request.count <= 512 && ($0.response?.count ?? 0) <= 512 }, "every value fits one attribute")
        XCTAssertGreaterThan(handshake[0].request.count, 244, "the first exchange needs a GATT long write on any iOS MTU (not exercised here)")

        // The board's real identity and a challenge, inside the session.
        let status = try await client.status(issueChallenge: true)
        XCTAssertEqual(status.code, .ok)
        XCTAssertEqual(status.eui64, fixture.eui64, "the authenticated EUI-64")
        XCTAssertEqual(status.state, .waiting)
        XCTAssertEqual(status.challenge?.lifetimeSeconds, 60)
        let challenge = try XCTUnwrap(status.challenge)

        let id = requestID(1)
        let other = try XCTUnwrap(PowerBaseBLEEUI64(hex: "6055f9fffe005678"))
        let wrongTarget = try await client.start(target: other, requestID: id, challenge: challenge, pskd: Self.pskd)
        XCTAssertEqual(wrongTarget, .wrongTarget)
        let spent = try await client.start(target: fixture.eui64, requestID: id, challenge: challenge, pskd: Self.pskd)
        XCTAssertEqual(spent, .challengeInvalid, "a challenge is used up by the first new request that carries it")
        try harness.poll()
        XCTAssertEqual(try harness.stats().joinerStarts, 0, "nothing refused reached the Joiner")

        let fresh = try await freshChallenge(client)
        let accepted = try await client.start(target: fixture.eui64, requestID: id, challenge: fresh, pskd: Self.pskd)
        XCTAssertEqual(accepted, .accepted)
        XCTAssertEqual(try harness.stats().joinerStarts, 0, "accepted is queued, not started")
        let again = try await client.start(target: fixture.eui64, requestID: id, challenge: fresh, pskd: Self.pskd)
        XCTAssertEqual(again, .duplicate, "the same request again starts nothing new")

        XCTAssertEqual(try harness.poll(), .open)
        let stats = try harness.stats()
        XCTAssertEqual(stats.joinerStarts, 1, "exactly one Joiner")
        XCTAssertEqual(stats.pskd, Self.pskd, "with the PSKd that travelled encrypted from the Swift client")
        XCTAssertEqual(stats.state, Self.stateJoining)

        let running = try await client.status(requestID: id)
        XCTAssertEqual(running.state, .joining)
        XCTAssertTrue(running.flags.contains(.requestMatch))
        XCTAssertEqual(running.requestPhase, .running)

        let conflict = try await client.start(target: fixture.eui64, requestID: id, challenge: try await freshChallenge(client), pskd: Self.otherPSKd)
        XCTAssertEqual(conflict, .requestConflict, "the same request id with other content")
        let busy = try await client.start(target: fixture.eui64, requestID: requestID(60), challenge: try await freshChallenge(client), pskd: Self.otherPSKd)
        XCTAssertEqual(busy, .busy, "another request while that attempt runs")
        let stranger = try await client.cancel(target: fixture.eui64, requestID: requestID(60))
        XCTAssertEqual(stranger, .noSuchAttempt, "only the attempt's own request id cancels it")

        let cancelled = try await client.cancel(target: fixture.eui64, requestID: id)
        XCTAssertEqual(cancelled, .ok)
        try harness.poll()
        XCTAssertEqual(try harness.stats().joinerStops, 1)
        XCTAssertEqual(try harness.stats().state, Self.stateWaiting)
        let after = try await client.status(requestID: id)
        XCTAssertEqual(after.requestPhase, .cancelled)
        XCTAssertEqual(try harness.stats().joinerStarts, 1, "the refused and repeated requests started nothing")
    }

    func testChallengeExpiresAfterSixtySeconds() async throws {
        let harness = try boot()
        XCTAssertTrue(try harness.connect(1))
        let (client, _) = try await authenticatedClient(harness)
        let challenge = try await freshChallenge(client)
        try harness.advance(milliseconds: 60_000)
        let expired = try await client.start(target: fixture.eui64, requestID: requestID(1), challenge: challenge, pskd: Self.pskd)
        XCTAssertEqual(expired, .challengeExpired)
        try harness.poll()
        XCTAssertEqual(try harness.stats().joinerStarts, 0)
    }

    func testJoiningAttachingAndEnrolledAreProgressAndAClosedBoardStillAnswers() async throws {
        let harness = try boot()
        XCTAssertTrue(try harness.connect(1))
        let (client, _) = try await authenticatedClient(harness)
        let id = requestID(100)
        let challenge = try await freshChallenge(client)
        let accepted = try await client.start(target: fixture.eui64, requestID: id, challenge: challenge, pskd: Self.pskd)
        XCTAssertEqual(accepted, .accepted)
        try harness.poll()
        try harness.joinerDone(outcome: 0)
        XCTAssertEqual(try harness.poll(), .open)
        let attaching = try await client.status(requestID: id)
        XCTAssertEqual(attaching.state, .attaching, "Joiner success is only 'attaching'")
        XCTAssertEqual(attaching.requestPhase, .running)
        try harness.tick(attached: true, datasetComplete: true)
        XCTAssertEqual(try harness.poll(), .enrolled, "the board is told to shut BLE down")
        let enrolled = try await client.status(requestID: id)
        XCTAssertEqual(enrolled.code, .closed)
        XCTAssertEqual(enrolled.state, .enrolled)
        XCTAssertEqual(enrolled.requestPhase, .enrolled)
        let cancel = try await client.cancel(target: fixture.eui64, requestID: id)
        XCTAssertEqual(cancel, .closed, "a cancel after enrollment changes nothing")
        let stats = try harness.stats()
        XCTAssertEqual(stats.state, Self.stateEnrolled)
        XCTAssertTrue(stats.servicesAllowed && stats.threadEnabled && stats.marker == 1, "marker, Thread and services are untouched")
        XCTAssertNil(stats.storedEndpoint, "the first start message delivers no bridge endpoint: a version 1 record")
        XCTAssertNil(stats.activeEndpoint)
    }

    // MARK: - pb-start with the bridge endpoint

    /// A made-up Mesh-Local EID inside the harness's network prefix (fd11:2233:4455:0::/64).
    private func bridgeEndpoint(_ address: String = "fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79", port: Int = 5684) throws -> PowerBaseBLEBridgeEndpoint {
        try PowerBaseBLEBridgeEndpoint(address: address, port: port)
    }

    func testTheEndpointStartReachesTheRealBoardCodeWithTheSameAddressAndPort() async throws {
        let harness = try boot()
        XCTAssertTrue(try harness.connect(1))
        let (client, link) = try await authenticatedClient(harness)
        let capabilities = await client.capabilities()
        XCTAssertEqual(capabilities, [.bridgeEndpointV1], "the real proto-ver answer lists the capability")

        let endpoint = try bridgeEndpoint()
        let id = requestID(30)
        let challenge = try await freshChallenge(client)
        let accepted = try await client.start(target: fixture.eui64, requestID: id, challenge: challenge, pskd: Self.pskd, endpoint: endpoint)
        XCTAssertEqual(accepted, .accepted, "the real admission code takes the Swift codec's message")
        let sent = try XCTUnwrap(link.exchanges.last { $0.endpoint == .start })
        XCTAssertEqual(sent.request.count, 64 + Self.pskd.count + 16, "64 + PSKd bytes of plaintext, plus the AES-GCM tag")
        var stats = try harness.stats()
        XCTAssertEqual(stats.joinerStarts, 0, "accepted is queued, not started")
        XCTAssertNil(stats.pendingEndpoint, "the BLE callback handed nothing to the controller")
        XCTAssertNil(stats.storedEndpoint, "and stored nothing")

        let again = try await client.start(target: fixture.eui64, requestID: id, challenge: challenge, pskd: Self.pskd, endpoint: endpoint)
        XCTAssertEqual(again, .duplicate, "the same request with the same endpoint")
        let otherAddress = try await client.start(
            target: fixture.eui64, requestID: id, challenge: challenge, pskd: Self.pskd, endpoint: try bridgeEndpoint("fd11:2233:4455:0:8c1f:2e3d:4c5b:6a7a")
        )
        XCTAssertEqual(otherAddress, .requestConflict, "the same request id with another address is not a duplicate")
        let otherPort = try await client.start(
            target: fixture.eui64, requestID: id, challenge: challenge, pskd: Self.pskd, endpoint: try bridgeEndpoint(port: 5685)
        )
        XCTAssertEqual(otherPort, .requestConflict, "nor with another port")
        let firstKind = try await client.start(target: fixture.eui64, requestID: id, challenge: challenge, pskd: Self.pskd)
        XCTAssertEqual(firstKind, .requestConflict, "nor as the first start message")

        XCTAssertEqual(try harness.poll(), .open)
        stats = try harness.stats()
        XCTAssertEqual(stats.joinerStarts, 1, "exactly one Joiner")
        XCTAssertEqual(stats.pskd, Self.pskd)
        XCTAssertEqual(stats.pendingEndpoint, Harness.Endpoint(address: endpoint.address, port: 5684),
                       "the controller holds the address and port the Swift client encoded -- byte for byte, port byte order included")
        XCTAssertNil(stats.storedEndpoint, "still only in RAM")
        XCTAssertEqual(stats.marker, 0, "no record yet")

        try harness.joinerDone(outcome: 0)
        try harness.poll()
        try harness.tick(attached: true, datasetComplete: true)
        XCTAssertEqual(try harness.poll(), .enrolled)
        stats = try harness.stats()
        XCTAssertEqual(stats.state, Self.stateEnrolled)
        XCTAssertEqual(stats.marker, 1, "a valid record")
        XCTAssertEqual(stats.storedEndpoint, Harness.Endpoint(address: endpoint.address, port: 5684), "the record holds the delivered endpoint")
        XCTAssertEqual(stats.activeEndpoint, stats.storedEndpoint, "and that is what the exporter is given")
        XCTAssertNil(stats.pendingEndpoint)
        let enrolled = try await client.status(requestID: id)
        XCTAssertEqual(enrolled.requestPhase, .enrolled, "progress on the board -- never the hub's heartbeat_received")
    }

    func testAnEndpointAttemptThatDoesNotEnrollLeavesNoEndpointBehind() async throws {
        let harness = try boot()
        XCTAssertTrue(try harness.connect(1))
        let (client, _) = try await authenticatedClient(harness)

        // Cancelled while the Joiner runs.
        let id = requestID(40)
        let accepted = try await client.start(
            target: fixture.eui64, requestID: id, challenge: try await freshChallenge(client), pskd: Self.pskd, endpoint: try bridgeEndpoint()
        )
        XCTAssertEqual(accepted, .accepted)
        try harness.poll()
        XCTAssertNotNil(try harness.stats().pendingEndpoint)
        let cancelled = try await client.cancel(target: fixture.eui64, requestID: id)
        XCTAssertEqual(cancelled, .ok)
        try harness.poll()
        var stats = try harness.stats()
        XCTAssertEqual(stats.state, Self.stateWaiting)
        XCTAssertNil(stats.pendingEndpoint, "a cancelled attempt's endpoint is dropped")
        XCTAssertNil(stats.storedEndpoint)
        XCTAssertEqual(stats.marker, 0)

        // An endpoint outside the network the board then joins.
        let elsewhere = requestID(41)
        let other = try await client.start(
            target: fixture.eui64, requestID: elsewhere, challenge: try await freshChallenge(client), pskd: Self.otherPSKd,
            endpoint: try bridgeEndpoint("fd99:8877:6655:0:8c1f:2e3d:4c5b:6a79")
        )
        XCTAssertEqual(other, .accepted, "a Mesh-Local EID of some network: the format is fine")
        try harness.poll()
        try harness.joinerDone(outcome: 0)
        try harness.poll()
        try harness.tick(attached: true, datasetComplete: true)
        XCTAssertEqual(try harness.poll(), .open, "not enrolled: BLE enrollment stays open")
        stats = try harness.stats()
        XCTAssertEqual(stats.state, Self.stateWaiting)
        XCTAssertEqual(stats.last, 5, "dataset_mismatch: the joined network is not the endpoint's")
        XCTAssertFalse(stats.servicesAllowed)
        XCTAssertFalse(stats.threadEnabled)
        XCTAssertNil(stats.storedEndpoint)
        XCTAssertNil(stats.pendingEndpoint)
        XCTAssertEqual(stats.marker, 0, "no record")
        let failed = try await client.status(requestID: elsewhere)
        XCTAssertEqual(failed.requestPhase, .failed)
        XCTAssertEqual(failed.requestResult, 5)
        XCTAssertLessThanOrEqual(failed.lastResult, PowerBaseBLEResult.maximumEnrollResult, "still a version 1 result value")
    }

    // MARK: - Wrong credentials

    func testAWrongSetupCodeIsRefusedOnceAndNeverRetried() async throws {
        let harness = try boot()
        XCTAssertTrue(try harness.connect(1))
        let first = fixture.setupCode.first == "A" ? "B" : "A"
        let wrongCode = first + fixture.setupCode.dropFirst()
        let link = HarnessLink(harness: harness, session: 1)
        let client = PowerBaseBLEBoardClient(link: link)
        try await client.checkVersion()
        await assertClientError(.authenticationFailed, "one character off") {
            try await client.authenticate(eui64: self.fixture.eui64, setupCode: wrongCode)
        }
        XCTAssertEqual(link.exchangeCount(.session), 2, "one attempt: Command0 and Command1, nothing more")
        let established = await client.hasSession
        XCTAssertFalse(established)

        // The same client never tries again, and has no session to use.
        await assertClientError(.noSession, "a second attempt needs a new connection and a new decision") {
            try await client.authenticate(eui64: self.fixture.eui64, setupCode: self.fixture.setupCode)
        }
        await assertClientError(.noSession) { _ = try await client.status() }
        XCTAssertEqual(link.exchanges.count, 3, "proto-ver + two handshake messages; nothing after the refusal")

        // The right code with another board's EUI-64 as the user name.
        let other = try XCTUnwrap(PowerBaseBLEEUI64(hex: "6055f9fffe005678"))
        let link2 = HarnessLink(harness: harness, session: 1)
        let client2 = PowerBaseBLEBoardClient(link: link2)
        try await client2.checkVersion()
        await assertClientError(.authenticationFailed, "the verifier is bound to the EUI-64") {
            try await client2.authenticate(eui64: other, setupCode: self.fixture.setupCode)
        }
        XCTAssertEqual(try harness.poll(), .open, "two failures: still open")
        XCTAssertEqual(try harness.stats().joinerStarts, 0)

        // A code that is not a setup code at all is refused before anything is sent.
        let link3 = HarnessLink(harness: harness, session: 1)
        let client3 = PowerBaseBLEBoardClient(link: link3)
        try await client3.checkVersion()
        await assertClientError(.invalidInput("setup_code")) {
            try await client3.authenticate(eui64: self.fixture.eui64, setupCode: self.fixture.setupCode.lowercased())
        }
        XCTAssertEqual(link3.exchangeCount(.session), 0, "no handshake message: the board's failure count is untouched")

        // The right credentials still work on this boot.
        _ = try await authenticatedClient(harness)
    }

    func testALockedBoardRefusesTheHandshakeStart() async throws {
        let harness = try boot()
        XCTAssertTrue(try harness.connect(1))
        let first = fixture.setupCode.first == "A" ? "B" : "A"
        let wrongCode = first + fixture.setupCode.dropFirst()
        for _ in 0..<5 {
            let client = PowerBaseBLEBoardClient(link: HarnessLink(harness: harness, session: 1))
            try await client.checkVersion()
            await assertClientError(.authenticationFailed) { try await client.authenticate(eui64: self.fixture.eui64, setupCode: wrongCode) }
        }
        XCTAssertEqual(try harness.poll(), .authLocked, "five refused handshakes close BLE enrollment for this boot")
        let link = HarnessLink(harness: harness, session: 1)
        let client = PowerBaseBLEBoardClient(link: link)
        try await client.checkVersion()
        await assertClientError(.handshakeRefused, "even the right code: the board answers no handshake message") {
            try await client.authenticate(eui64: self.fixture.eui64, setupCode: self.fixture.setupCode)
        }
        XCTAssertEqual(link.exchangeCount(.session), 1)
    }

    // MARK: - A board that cannot prove itself, and broken ciphertext

    func testABoardProofThatDoesNotMatchIsRefused() async throws {
        let harness = try boot()
        XCTAssertTrue(try harness.connect(1))
        let link = HarnessLink(harness: harness, session: 1)
        var seen = 0
        link.tamperResponses { endpoint, response in
            guard endpoint == .session else { return response }
            seen += 1
            // The second handshake answer carries the board's proof.
            return seen == 2 ? (try? Security2Handshake.tamperingDeviceProof(response)) ?? response : response
        }
        let client = PowerBaseBLEBoardClient(link: link)
        try await client.checkVersion()
        await assertClientError(.boardProofMismatch) {
            try await client.authenticate(eui64: self.fixture.eui64, setupCode: self.fixture.setupCode)
        }
        let established = await client.hasSession
        XCTAssertFalse(established)
        let before = link.exchanges.count
        await assertClientError(.noSession, "nothing is sent to a board that did not prove itself") { _ = try await client.status(issueChallenge: true) }
        XCTAssertEqual(link.exchanges.count, before)
    }

    func testAnAnswerThatFailsItsTagDiscardsTheSession() async throws {
        let harness = try boot()
        XCTAssertTrue(try harness.connect(1))
        let (client, link) = try await authenticatedClient(harness)
        _ = try await client.status()

        link.tamperResponses { endpoint, response in
            guard endpoint == .status else { return response }
            var changed = response
            changed[changed.startIndex] ^= 0x01
            return changed
        }
        await assertClientError(.decryptionFailed, "one flipped bit in the answer") { _ = try await client.status() }
        link.tamperResponses(nil)
        let before = link.exchanges.count
        await assertClientError(.noSession, "the counters are out of step: the session is gone") { _ = try await client.status() }
        await assertClientError(.noSession) { _ = try await client.cancel(target: self.fixture.eui64, requestID: self.requestID(1)) }
        XCTAssertEqual(link.exchanges.count, before, "and nothing more is sent on it")
        let established = await client.hasSession
        XCTAssertFalse(established)
    }

    func testARequestTheBoardCannotDecryptDiscardsTheSessionAndIsNotResent() async throws {
        let harness = try boot()
        XCTAssertTrue(try harness.connect(1))
        let (client, link) = try await authenticatedClient(harness)
        link.tamperRequests { endpoint, request in
            guard endpoint == .status else { return request }
            var changed = request
            changed[changed.startIndex] ^= 0x01
            return changed
        }
        await assertClientError(.requestFailed(.rejected), "the board refuses a ciphertext whose tag fails") { _ = try await client.status() }
        link.tamperRequests(nil)
        let count = link.exchangeCount(.status)
        XCTAssertEqual(count, 1, "sent once")
        await assertClientError(.noSession) { _ = try await client.status() }
        XCTAssertEqual(link.exchangeCount(.status), count, "the same ciphertext is never sent again; nothing new either")

        // A truncated answer (shorter than a tag) is not read either.
        let (client2, link2) = try await authenticatedClient(harness)
        link2.tamperResponses { endpoint, response in endpoint == .status ? Data(response.prefix(8)) : response }
        await assertClientError(.decryptionFailed) { _ = try await client2.status() }
    }

    // MARK: - Counters

    func testConsecutiveRequestsKeepTheCountersInStepAndAReplayIsRefused() async throws {
        let harness = try boot()
        XCTAssertTrue(try harness.connect(1))
        let (client, link) = try await authenticatedClient(harness)
        var ciphertexts = Set<Data>()
        for _ in 0..<12 {
            let status = try await client.status()
            XCTAssertEqual(status.eui64, fixture.eui64)
        }
        for exchange in link.exchanges where exchange.endpoint == .status {
            ciphertexts.insert(exchange.request)
            XCTAssertEqual(exchange.request.count, 20 + 16, "plaintext + 16-byte tag")
            XCTAssertEqual(exchange.response?.count, 40 + 16)
        }
        XCTAssertEqual(ciphertexts.count, 12, "the same request encrypts differently every time: the IV counter moves")

        // What a repeated write of an old ciphertext would do: the real server refuses it.
        let old = try XCTUnwrap(link.exchanges.last { $0.endpoint == .status }?.request)
        XCTAssertNotEqual(try harness.request(session: 1, endpoint: "pb-status", data: old).error, 0, "replay refused")
    }

    // MARK: - Reconnecting

    func testAfterADisconnectTheOldSessionIsUselessAndANewOneFindsTheAttempt() async throws {
        let harness = try boot()
        XCTAssertTrue(try harness.connect(1))
        let (client, _) = try await authenticatedClient(harness)
        let id = requestID(1)
        let challenge = try await freshChallenge(client)
        let accepted = try await client.start(target: fixture.eui64, requestID: id, challenge: challenge, pskd: Self.pskd)
        XCTAssertEqual(accepted, .accepted)
        try harness.poll()
        let unused = try await freshChallenge(client, asking: id)

        XCTAssertTrue(try harness.disconnect(1))
        try harness.advance(milliseconds: 5_000)
        XCTAssertEqual(try harness.poll(), .open)
        XCTAssertEqual(try harness.stats().state, Self.stateJoining, "the accepted attempt runs on without the connection")
        XCTAssertEqual(try harness.stats().joinerStops, 0)

        XCTAssertTrue(try harness.connect(1))
        await assertClientError(.requestFailed(.rejected), "the previous session's keys mean nothing on the new connection") {
            _ = try await client.status(requestID: id)
        }
        await assertClientError(.noSession) { _ = try await client.status(requestID: id) }

        let (client2, _) = try await authenticatedClient(harness)
        let found = try await client2.status(issueChallenge: true, requestID: id)
        XCTAssertTrue(found.flags.contains(.requestMatch), "the original request id still names the attempt")
        XCTAssertEqual(found.requestPhase, .running)
        let stale = try await client2.start(target: fixture.eui64, requestID: requestID(60), challenge: unused, pskd: Self.otherPSKd)
        XCTAssertEqual(stale, .challengeInvalid, "a challenge from the previous session is refused")
        let resent = try await client2.start(target: fixture.eui64, requestID: id, challenge: try XCTUnwrap(found.challenge), pskd: Self.pskd)
        XCTAssertEqual(resent, .requestConflict, "the original id with a new challenge is never a second start")
        try harness.poll()
        let stats = try harness.stats()
        XCTAssertEqual(stats.joinerStarts, 1)
        XCTAssertEqual(stats.joinerStops, 0)
        XCTAssertEqual(stats.pskd, Self.pskd)
    }

    // MARK: - Public key with a leading zero byte

    func testAPublicKeyWithALeadingZeroByteStillAuthenticates() async throws {
        let harness = try boot()
        XCTAssertTrue(try harness.connect(1))
        let link = HarnessLink(harness: harness, session: 1)
        let client = PowerBaseBLEBoardClient(link: link)
        try await client.checkVersion()
        try await client.authenticate(eui64: fixture.eui64, setupCode: fixture.setupCode, srpPrivateKeyForTesting: fixture.leadingZeroKey)
        let command0 = try XCTUnwrap(link.exchanges.first { $0.endpoint == .session }?.request)
        let publicKey = try XCTUnwrap(Security2Handshake.clientPublicKey(inCommand0: command0))
        XCTAssertEqual(publicKey.count, 384, "always the full width")
        XCTAssertEqual(publicKey.first, 0, "this key really starts with a zero byte")
        let status = try await client.status(issueChallenge: true)
        XCTAssertEqual(status.eui64, fixture.eui64, "session key, proofs and counters all agree with the real server")
        XCTAssertNotNil(status.challenge)

        // What upstream ESPProvision (and ESP-IDF's Python client) send for the same key: the
        // leading zero dropped. The real server refuses that -- which is why the copy is patched.
        let harness2 = try boot()
        XCTAssertTrue(try harness2.connect(1))
        let stripped = Data(publicKey.drop { $0 == 0 })
        XCTAssertLessThan(stripped.count, 384)
        let upstream = try Security2Handshake.command0(username: fixture.eui64.hex, publicKey: stripped)
        XCTAssertNotEqual(try harness2.request(session: 1, endpoint: "prov-session", data: upstream).error, 0,
                          "a public key that is not exactly 384 bytes is refused by security2.c")
    }

    // MARK: - Downgrades and unknown versions

    func testAnotherSecuritySchemeOrPatchIsRefusedBeforeAnyHandshake() async throws {
        let harness = try boot()
        XCTAssertTrue(try harness.connect(1))
        let real = #"{"prov":{"ver":"v1.1","sec_ver":2,"sec_patch_ver":1,"cap":[]},"pb_enroll":{"proto":1,"cap":["bridge_endpoint_v1"]}}"#
        let version = try harness.request(session: 1, endpoint: "proto-ver", data: Data("ESP".utf8))
        XCTAssertEqual(version.error, 0)
        XCTAssertEqual(String(decoding: version.response, as: UTF8.self), real, "what the real board answers")

        let cases: [(String, String, PowerBaseBLEVersion.Failure)] = [
            (#""sec_ver":2"#, #""sec_ver":0"#, .securityVersion(0)),
            (#""sec_ver":2"#, #""sec_ver":1"#, .securityVersion(1)),
            (#""sec_patch_ver":1"#, #""sec_patch_ver":2"#, .securityPatchVersion(2)),
            (#""sec_patch_ver":1"#, #""sec_patch_ver":0"#, .securityPatchVersion(0)),
            (#""proto":1"#, #""proto":2"#, .enrollmentProtocol(2)),
            (#""cap":[]"#, #""cap":["no_sec"]"#, .securityVersion(2)),
        ]
        for (from, to, failure) in cases {
            let link = HarnessLink(harness: harness, session: 1)
            link.tamperResponses { endpoint, response in
                endpoint == .version ? Data(String(decoding: response, as: UTF8.self).replacingOccurrences(of: from, with: to).utf8) : response
            }
            let client = PowerBaseBLEBoardClient(link: link)
            await assertClientError(.unsupportedVersion(failure), to) { try await client.checkVersion() }
            await assertClientError(.noSession, "no handshake without an accepted version") {
                try await client.authenticate(eui64: self.fixture.eui64, setupCode: self.fixture.setupCode)
            }
            XCTAssertEqual(link.exchangeCount(.session), 0, "\(to): nothing was sent to prov-session")
        }

        // And the real server refuses Security 0 / 1 session requests and plaintext endpoints.
        XCTAssertNotEqual(try harness.request(session: 1, endpoint: "prov-session", data: GoldenVectors.security0Command).error, 0, "Security 0")
        XCTAssertNotEqual(try harness.request(session: 1, endpoint: "prov-session", data: GoldenVectors.security1Command0).error, 0, "Security 1")
        let plain = PowerBaseBLECodec.statusRequest(issueChallenge: true, requestID: nil)
        XCTAssertNotEqual(try harness.request(session: 1, endpoint: "pb-status", data: plain).error, 0, "no plaintext pb-status")
        try harness.poll()
        XCTAssertEqual(try harness.stats().joinerStarts, 0)
    }

    func testAnAuthenticationIsNeverStartedWithoutTheVersionCheck() async throws {
        let harness = try boot()
        XCTAssertTrue(try harness.connect(1))
        let link = HarnessLink(harness: harness, session: 1)
        let client = PowerBaseBLEBoardClient(link: link)
        await assertClientError(.noSession) { try await client.authenticate(eui64: self.fixture.eui64, setupCode: self.fixture.setupCode) }
        XCTAssertTrue(link.exchanges.isEmpty)
    }

    // MARK: - Closing

    func testClosingDropsTheSessionAndEndsTheLink() async throws {
        let harness = try boot()
        XCTAssertTrue(try harness.connect(1))
        let (client, link) = try await authenticatedClient(harness)
        await client.close()
        XCTAssertTrue(link.closed)
        let before = link.exchanges.count
        await assertClientError(.noSession) { _ = try await client.status() }
        XCTAssertEqual(link.exchanges.count, before)
    }

    // MARK: - Nothing secret is printed

    func testNeitherTheClientNorTheBoardPrintsTheSetupCodeOrThePSKd() async throws {
        // Everything this process writes to stdout and stderr during a complete exchange.
        let capture = FileManager.default.temporaryDirectory.appendingPathComponent("pb-client-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: capture.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: capture) }
        fflush(stdout)
        fflush(stderr)
        let savedOut = dup(STDOUT_FILENO)
        let savedErr = dup(STDERR_FILENO)
        let file = open(capture.path, O_WRONLY | O_APPEND)
        dup2(file, STDOUT_FILENO)
        dup2(file, STDERR_FILENO)
        var failure: Error?
        do {
            let harness = try boot()
            _ = try harness.connect(1)
            let (client, _) = try await authenticatedClient(harness)
            let challenge = try await freshChallenge(client)
            _ = try await client.start(target: fixture.eui64, requestID: requestID(1), challenge: challenge, pskd: Self.pskd)
            try harness.poll()
            _ = try await client.cancel(target: fixture.eui64, requestID: requestID(1))
            let wrong = PowerBaseBLEBoardClient(link: HarnessLink(harness: harness, session: 1))
            try await wrong.checkVersion()
            let first = fixture.setupCode.first == "A" ? "B" : "A"
            try? await wrong.authenticate(eui64: fixture.eui64, setupCode: first + fixture.setupCode.dropFirst())
            await client.close()
            harness.quit()
        } catch {
            failure = error
        }
        fflush(stdout)
        fflush(stderr)
        dup2(savedOut, STDOUT_FILENO)
        dup2(savedErr, STDERR_FILENO)
        close(savedOut)
        close(savedErr)
        close(file)
        if let failure { throw failure }

        let client = try Data(contentsOf: capture)
        let board = try Data(contentsOf: logURL)
        XCTAssertGreaterThan(board.count, 200, "the board side did log (ESP-IDF's and the firmware's INFO output)")
        let salt = fixture.record.subdata(in: 16..<32).map { String(format: "%02x", $0) }.joined()
        let verifier = fixture.record.subdata(in: 32..<64).map { String(format: "%02x", $0) }.joined()
        for (name, secret) in [("setup code", fixture.setupCode), ("PSKd", Self.pskd), ("salt", salt), ("verifier", verifier)] {
            for (side, output) in [("client", client), ("board", board)] {
                let text = String(decoding: output, as: UTF8.self).lowercased()
                XCTAssertFalse(text.contains(secret.lowercased()), "\(name) in the \(side) output")
            }
        }
        XCTAssertTrue(client.isEmpty, "the Swift client and the vendored Security 2 code print nothing at all: \(String(decoding: client.prefix(200), as: UTF8.self))")
    }
}
#endif
