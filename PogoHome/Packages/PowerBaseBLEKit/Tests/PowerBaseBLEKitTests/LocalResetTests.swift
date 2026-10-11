import XCTest
@testable import PowerBaseBLEKit

/// The local reset: the command (message 0x09 / 0x89 on `pb-start`) and its status (0x08 / 0x88 on
/// `pb-status`) of pb_ble_proto.h, capability `local_reset_v1` (firmware repository,
/// docs/power-base.md "BOOT 버튼 로컬 재등록"). The same two requests are built by the firmware
/// repository's tools/test_power_base_reenroll.c; `LocalResetInteropTests` sends them to the real
/// C implementation.
final class LocalResetTests: XCTestCase {
    private let eui = PowerBaseBLEEUI64(hex: "6055f9fffe001234")!
    private let other = PowerBaseBLEEUI64(hex: "6055f9fffe005678")!
    private let operation = PowerBaseBLEOperationID(bytes: Data((0..<16).map { 0x81 + UInt8($0) }))!
    private let challenge = PowerBaseBLEChallenge(bytes: Data((0..<16).map { 0xc0 + UInt8($0) }), lifetimeSeconds: 60)!

    private func data(_ hex: String) -> Data {
        var out = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    /// A status response as pb_ble_adm_handle_local_reset_status() builds it.
    private func response(
        code: UInt8 = 0, eui64: PowerBaseBLEEUI64? = nil, version: UInt8 = 1, condition: UInt8 = 1, flags: UInt8 = 0, phase: UInt8 = 0,
        reason: UInt8 = 0, seconds: UInt16 = 0
    ) -> Data {
        var out = Data([1, 0x88, code, 0])
        out.append((eui64 ?? eui).bytes)
        out.append(contentsOf: [version, condition, flags, phase, reason, 0, UInt8(seconds >> 8), UInt8(seconds & 0xff)])
        out.append(Data(count: 12))
        return out
    }

    // MARK: Requests

    func testTheStatusRequestIsTwentyEightBytes() {
        XCTAssertEqual(
            PowerBaseBLECodec.localResetStatusRequest(target: eui, operationID: operation),
            data("01080000" + "6055f9fffe001234" + "8182838485868788898a8b8c8d8e8f90")
        )
        XCTAssertEqual(
            PowerBaseBLECodec.localResetStatusRequest(target: eui, operationID: nil),
            data("01080000" + "6055f9fffe001234" + "00000000000000000000000000000000"), "asking about no operation"
        )
        XCTAssertEqual(PowerBaseBLECodec.localResetStatusRequest(target: eui, operationID: nil).count, PowerBaseBLECodec.localResetStatusRequestLength)
    }

    func testTheCommandIsFortyEightBytesAndCarriesTheConfirmation() {
        let request = PowerBaseBLECodec.localResetRequest(
            target: eui, operationID: operation, challenge: challenge, confirmation: .userConfirmedErasingRegistration
        )
        XCTAssertEqual(
            request,
            data("01090100" + "6055f9fffe001234" + "8182838485868788898a8b8c8d8e8f90" + "c0c1c2c3c4c5c6c7c8c9cacbcccdcecf" + "01000000")
        )
        XCTAssertEqual(request.count, PowerBaseBLECodec.localResetRequestLength)
        XCTAssertEqual(request[44], 0x01, "the confirmation byte: there is no way to build the command without it")
    }

    func testAnOperationIDIsSixteenBytesAndNeverAllZero() {
        XCTAssertNil(PowerBaseBLEOperationID(bytes: Data(count: 16)))
        XCTAssertNil(PowerBaseBLEOperationID(bytes: Data(repeating: 1, count: 15)))
        XCTAssertNil(PowerBaseBLEOperationID(bytes: Data(repeating: 1, count: 17)))
        XCTAssertNotNil(PowerBaseBLEOperationID(bytes: Data(repeating: 1, count: 16)))
        XCTAssertNil(PowerBaseBLEOperationID.random { _ in nil }, "no randomness: no id, so nothing can be sent")
        XCTAssertNil(PowerBaseBLEOperationID.random { _ in [UInt8](repeating: 0, count: 16) })
        let first = PowerBaseBLEOperationID.random()
        let second = PowerBaseBLEOperationID.random()
        XCTAssertNotNil(first)
        XCTAssertNotEqual(first, second, "the system generator")
    }

    // MARK: The status response

    func testTheDocumentedAnswersAreRead() throws {
        let idle = try PowerBaseBLECodec.decodeLocalResetStatusResponse(response(flags: 0x01, seconds: 120), target: eui)
        XCTAssertEqual(idle, PowerBaseBLELocalResetStatus(eui64: eui, condition: .enrolled, isWindowOpen: true, windowSecondsLeft: 120))
        XCTAssertNil(idle.operationPhase)

        let queued = try PowerBaseBLECodec.decodeLocalResetStatusResponse(response(condition: 3, flags: 0x03, phase: 1, seconds: 7), target: eui)
        XCTAssertEqual(queued.condition, .resetPending)
        XCTAssertEqual(queued.operationPhase, .queued)

        let failing = try PowerBaseBLECodec.decodeLocalResetStatusResponse(response(condition: 3, flags: 0x02, phase: 2, reason: 7), target: eui)
        XCTAssertEqual(failing.operationPhase, .inProgress)
        XCTAssertEqual(failing.operationReason, 7)
        XCTAssertEqual(PowerBaseBLELocalResetStatus.reasonName(7), "network_erase_failed")
        XCTAssertFalse(failing.isWindowOpen)

        let verified = try PowerBaseBLECodec.decodeLocalResetStatusResponse(response(condition: 0, flags: 0x02, phase: 3), target: eui)
        XCTAssertEqual(verified.condition, .notEnrolled)
        XCTAssertEqual(verified.operationPhase, .verified)

        let notStarted = try PowerBaseBLECodec.decodeLocalResetStatusResponse(response(flags: 0x03, phase: 4, reason: 1, seconds: 1), target: eui)
        XCTAssertEqual(notStarted.operationPhase, .notStarted)
        XCTAssertEqual(notStarted.windowSecondsLeft, 1)

        for (raw, condition) in [(0, PowerBaseBLELocalResetStatus.Condition.notEnrolled), (1, .enrolled), (2, .remoteReleasePending), (3, .resetPending), (4, .unreadable)] {
            XCTAssertEqual(try PowerBaseBLECodec.decodeLocalResetStatusResponse(response(condition: UInt8(raw)), target: eui).condition, condition)
        }
        XCTAssertEqual(response().count, PowerBaseBLECodec.localResetStatusResponseLength)
    }

    func testAnythingElseIsNotAnAnswer() {
        func refused(_ response: Data, _ expected: PowerBaseBLECodecError, _ why: String, line: UInt = #line) {
            XCTAssertThrowsError(try PowerBaseBLECodec.decodeLocalResetStatusResponse(response, target: eui), why, line: line) {
                XCTAssertEqual($0 as? PowerBaseBLECodecError, expected, why, line: line)
            }
        }
        refused(response().dropLast(), .length(31), "one byte short")
        refused(response() + Data([0]), .length(33), "one byte long")
        var bad = response()
        bad[0] = 2
        refused(bad, .version(2), "another protocol version")
        bad = response()
        bad[1] = 0x81
        refused(bad, .type(0x81), "a pb-status response where this response belongs")
        for offset in [3, 17, 20, 25, 31] {
            bad = response()
            bad[offset] = 1
            refused(bad, .reserved, "reserved byte \(offset)")
        }
        // Refusals, exactly as the board writes them.
        refused(Data([1, 0x88, 0x11, 0]) + Data(count: 28), .refused(.malformed), "MALFORMED")
        refused(Data([1, 0x88, 0x10, 0]) + Data(count: 28), .refused(.unsupportedVersion), "UNSUPPORTED_VERSION")
        refused(Data([1, 0x88, 0x12, 0]) + eui.bytes + Data(count: 20), .refused(.wrongTarget), "WRONG_TARGET")
        refused(response(code: 0x12), .field("refusal"), "a refusal that carries state is not that refusal")
        refused(Data([1, 0x88, 0x11, 0]) + eui.bytes + Data(count: 20), .field("refusal"), "MALFORMED with an EUI-64 behind it")
        refused(response(code: 0x16), .code(0x16), "a code this message never answers with")
        refused(response(code: 0x7f), .code(0x7f), "a code that does not exist")
        refused(response(eui64: other), .field("eui64"), "the answer of another board")
        refused(response(version: 2), .field("local reset version"), "another local reset format")
        refused(response(condition: 5), .field("condition"), "a condition outside the protocol")
        refused(response(flags: 0x04), .field("flags"), "an unknown flag")
        refused(response(flags: 0x02, phase: 0), .field("phase"), "'operation known' without a phase")
        refused(response(flags: 0x02, phase: 5), .field("phase"), "a phase outside the protocol")
        refused(response(flags: 0x00, phase: 3), .field("phase"), "a phase without 'operation known'")
        refused(response(flags: 0x00, reason: 2), .field("phase"), "a reason without 'operation known'")
        refused(response(flags: 0x02, phase: 2, reason: 10), .field("reason"), "a reason outside the protocol")
        refused(response(flags: 0x01, seconds: 0), .field("window"), "an open window with no time left")
        refused(response(flags: 0x01, seconds: 121), .field("window"), "more time than a window has")
        refused(response(flags: 0x00, seconds: 5), .field("window"), "time left in a window that is not open")
        // What a board without the capability answers on pb-status: 40 bytes, MALFORMED.
        refused(Data([1, 0x81, 0x11, 0]) + Data(count: 36), .length(40), "firmware before the capability")
    }

    // MARK: The command's response

    func testTheCommandsAnswersAreRead() throws {
        for (raw, code) in [
            (0x01, PowerBaseBLECode.accepted), (0x02, .duplicate), (0x11, .malformed), (0x12, .wrongTarget), (0x13, .challengeInvalid),
            (0x14, .challengeExpired), (0x16, .busy), (0x17, .requestConflict), (0x1a, .closed), (0x1f, .windowClosed), (0x20, .notEnrolled),
        ] {
            XCTAssertEqual(try PowerBaseBLECodec.decodeLocalResetResponse(Data([1, 0x89, UInt8(raw), 0])), code)
        }
        XCTAssertEqual(PowerBaseBLECode.windowClosed.name, "WINDOW_CLOSED")
        XCTAssertEqual(PowerBaseBLECode.notEnrolled.name, "NOT_ENROLLED")

        func refused(_ response: Data, _ expected: PowerBaseBLECodecError, _ why: String, line: UInt = #line) {
            XCTAssertThrowsError(try PowerBaseBLECodec.decodeLocalResetResponse(response), why, line: line) {
                XCTAssertEqual($0 as? PowerBaseBLECodecError, expected, why, line: line)
            }
        }
        refused(Data([1, 0x82, 0x11, 0]), .type(0x82), "a board without the capability answers as pb-start: nothing of it is used")
        refused(Data([1, 0x89, 0x00, 0]), .code(0x00), "OK is not an answer to a reset")
        refused(Data([1, 0x89, 0x15, 0]), .code(0x15), "a pb-start code this message never answers with")
        refused(Data([1, 0x89, 0x18, 0]), .code(0x18), "NOT_WAITING belongs to the starts")
        refused(Data([1, 0x89, 0x01, 1]), .reserved, "reserved byte")
        refused(Data([1, 0x89, 0x01]), .length(3), "too short")
        refused(Data([2, 0x89, 0x01, 0]), .version(2), "another version")
    }

    /// The two new codes are not answers of any older message: an old response type that carried
    /// one would not be a version 1 answer.
    func testTheNewCodesBelongToTheNewMessageOnly() {
        for code in [UInt8(0x1f), 0x20] {
            XCTAssertThrowsError(try PowerBaseBLECodec.decodeStartResponse(Data([1, 0x82, code, 0])))
            XCTAssertThrowsError(try PowerBaseBLECodec.decodeStartWithEndpointResponse(Data([1, 0x84, code, 0])))
            XCTAssertThrowsError(try PowerBaseBLECodec.decodeStartWithManagementResponse(Data([1, 0x86, code, 0])))
            XCTAssertThrowsError(try PowerBaseBLECodec.decodeCancelResponse(Data([1, 0x83, code, 0])))
        }
    }

    // MARK: The capability

    private func version(_ cap: String) -> String {
        #"{"prov":{"ver":"v1.1","sec_ver":2,"sec_patch_ver":1,"cap":[]},"pb_enroll":{"proto":1,"cap":["# + cap + "]}}"
    }

    func testTheCapabilityIsItsOwnName() throws {
        func capabilities(_ cap: String) throws -> PowerBaseBLECapabilities { try PowerBaseBLEVersion.validate(Data(version(cap).utf8)) }
        XCTAssertEqual(
            try capabilities(#""bridge_endpoint_v1","mgmt_v1","release_receipt_v1","local_reset_v1""#),
            [.bridgeEndpointV1, .managementV1, .releaseReceiptV1, .localResetV1], "what a board with the re-enrollment button answers"
        )
        XCTAssertEqual(
            try capabilities(#""bridge_endpoint_v1","mgmt_v1","release_receipt_v1""#), [.bridgeEndpointV1, .managementV1, .releaseReceiptV1],
            "a board without the button: unchanged"
        )
        XCTAssertEqual(try capabilities(#""local_reset_v1""#), [.localResetV1])
        XCTAssertEqual(try capabilities(#""local_reset_v2","LOCAL_RESET_V1","local_reset""#), [], "the name is exact")
    }

    private final class VersionOnlyLink: PowerBaseBLELink, @unchecked Sendable {
        let version: String
        private let lock = NSLock()
        private var seen: [PowerBaseBLEProtocol.Endpoint] = []
        init(version: String) { self.version = version }
        var endpoints: [PowerBaseBLEProtocol.Endpoint] { lock.withLock { seen } }
        func exchange(endpoint: PowerBaseBLEProtocol.Endpoint, payload: Data) async throws -> Data {
            lock.withLock { seen.append(endpoint) }
            guard endpoint == .version else { throw PowerBaseBLELinkError.rejected }
            return Data(version.utf8)
        }
        func close() async {}
    }

    /// A board that does not list the capability is sent neither message -- and nothing else in
    /// their place (no start, no cancel, no receipt request).
    func testABoardWithoutTheCapabilityIsNeverAsked() async throws {
        let old = VersionOnlyLink(version: version(#""bridge_endpoint_v1","mgmt_v1","release_receipt_v1""#))
        let client = PowerBaseBLEBoardClient(link: old)
        try await client.checkVersion()
        do {
            _ = try await client.localResetStatus(target: eui, operationID: operation)
            XCTFail("nothing may be sent")
        } catch {
            XCTAssertEqual(error as? PowerBaseBLEClientError, .invalidInput("capability"))
        }
        do {
            _ = try await client.localReset(target: eui, operationID: operation, challenge: challenge, confirmation: .userConfirmedErasingRegistration)
            XCTFail("nothing may be sent")
        } catch {
            XCTAssertEqual(error as? PowerBaseBLEClientError, .invalidInput("capability"))
        }
        XCTAssertEqual(old.endpoints, [.version], "nothing was written to pb-status, pb-start or pb-cancel")

        let capable = VersionOnlyLink(version: version(#""bridge_endpoint_v1","mgmt_v1","release_receipt_v1","local_reset_v1""#))
        let asking = PowerBaseBLEBoardClient(link: capable)
        try await asking.checkVersion()
        do {
            _ = try await asking.localReset(target: eui, operationID: operation, challenge: challenge, confirmation: .userConfirmedErasingRegistration)
            XCTFail("no session exists")
        } catch {
            XCTAssertEqual(error as? PowerBaseBLEClientError, .noSession, "with the capability it is attempted -- and needs the Security 2 session")
        }
        XCTAssertEqual(capable.endpoints, [.version], "without a session nothing is written either")
    }
}
