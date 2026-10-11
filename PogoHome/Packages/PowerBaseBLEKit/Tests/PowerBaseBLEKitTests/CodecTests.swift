import XCTest
@testable import PowerBaseBLEKit

/// The byte layouts of pb_ble_proto.h, and that nothing but a correct version 1 message is read.
final class CodecTests: XCTestCase {
    private let eui = PowerBaseBLEEUI64(hex: "6055f9fffe001234")!
    private let requestID = PowerBaseBLERequestID(bytes: Data(1...16))!
    private let challenge = PowerBaseBLEChallenge(bytes: Data(0xA0...0xAF), lifetimeSeconds: 60)!

    /// A `pb-status` response as pb_ble_adm_handle_status() builds it.
    private func statusResponse(
        code: UInt8 = 0x00, eui64: [UInt8]? = nil, state: UInt8 = 0, last: UInt8 = 0, flags: UInt8 = 0, phase: UInt8 = 0,
        result: UInt8 = 0, lifetime: UInt16 = 0, attempt: UInt32 = 0, challenge: [UInt8] = [UInt8](repeating: 0, count: 16)
    ) -> Data {
        var bytes: [UInt8] = [1, 0x81, code, 0]
        bytes += eui64 ?? [UInt8](eui.bytes)
        bytes += [state, last, flags, phase, result, 0, UInt8(lifetime >> 8), UInt8(lifetime & 0xff)]
        bytes += [UInt8(attempt >> 24), UInt8(attempt >> 16 & 0xff), UInt8(attempt >> 8 & 0xff), UInt8(attempt & 0xff)]
        bytes += challenge
        return Data(bytes)
    }

    // MARK: - Identifiers

    func testEUI64IsSixteenHexDigitsAndNotZero() {
        XCTAssertEqual(PowerBaseBLEEUI64(hex: "6055F9FFFE001234")?.hex, "6055f9fffe001234")
        XCTAssertEqual(PowerBaseBLEEUI64(hex: "6055f9fffe001234")?.bytes, Data([0x60, 0x55, 0xf9, 0xff, 0xfe, 0x00, 0x12, 0x34]))
        for bad in ["", "6055f9fffe00123", "6055f9fffe0012345", "60:55:f9:ff:fe:00:12:34", "0000000000000000", "6055f9fffe00123g", "６０５５f9fffe001234"] {
            XCTAssertNil(PowerBaseBLEEUI64(hex: bad), bad)
        }
        XCTAssertNil(PowerBaseBLEEUI64(bytes: Data(count: 8)))
        XCTAssertNil(PowerBaseBLEEUI64(bytes: Data(count: 7)))
    }

    func testAdvertisedNameGivesOnlyAHint() {
        XCTAssertEqual(PowerBaseBLEProtocol.advertisedEUI64(inName: "POGO-PB-6055F9FFFE001234")?.hex, "6055f9fffe001234")
        XCTAssertEqual(PowerBaseBLEProtocol.advertisedEUI64(inName: "pogo-pb-6055f9fffe001234")?.hex, "6055f9fffe001234", "prefix in any case")
        for bad in ["POGO-PB-", "POGO-PB-6055F9FFFE00123", "POGO-PB-6055F9FFFE0012345", "POGO-XX-6055F9FFFE001234", "6055F9FFFE001234", "POGO-PB-0000000000000000", "POGO-PB-6055F9FFFE00123Z"] {
            XCTAssertNil(PowerBaseBLEProtocol.advertisedEUI64(inName: bad), bad)
        }
    }

    func testRequestIDIsSixteenRandomBytesAndNeverZero() throws {
        XCTAssertNil(PowerBaseBLERequestID(bytes: Data(count: 16)), "all zero means 'none' on the wire")
        XCTAssertNil(PowerBaseBLERequestID(bytes: Data(count: 15)))
        XCTAssertNil(PowerBaseBLERequestID.random { _ in [UInt8](repeating: 0, count: 16) }, "a zero id is never used")
        XCTAssertNil(PowerBaseBLERequestID.random { _ in nil }, "no secure randomness, no id")
        XCTAssertNil(PowerBaseBLERequestID.random { _ in [1, 2, 3] })
        var seen = Set<Data>()
        for _ in 0..<200 {
            let id = try XCTUnwrap(PowerBaseBLERequestID.random())
            XCTAssertEqual(id.bytes.count, 16)
            seen.insert(id.bytes)
        }
        XCTAssertEqual(seen.count, 200)
    }

    func testEndpointsAndCharacteristicUUIDs() {
        XCTAssertEqual(PowerBaseBLEProtocol.serviceUUID.lowercased(), "2e8a0000-9ffb-4868-bc63-064a14069755")
        let expected: [PowerBaseBLEProtocol.Endpoint: String] = [
            .session: "2e8aff51-9ffb-4868-bc63-064a14069755", .version: "2e8aff53-9ffb-4868-bc63-064a14069755",
            .status: "2e8aff60-9ffb-4868-bc63-064a14069755", .start: "2e8aff61-9ffb-4868-bc63-064a14069755",
            .cancel: "2e8aff62-9ffb-4868-bc63-064a14069755",
        ]
        XCTAssertEqual(Set(PowerBaseBLEProtocol.Endpoint.allCases), Set(expected.keys))
        for (endpoint, uuid) in expected {
            XCTAssertEqual(endpoint.characteristicUUID.lowercased(), uuid)
        }
        XCTAssertEqual(PowerBaseBLEProtocol.Endpoint.allCases.map(\.rawValue).sorted(), ["pb-cancel", "pb-start", "pb-status", "proto-ver", "prov-session"])
    }

    // MARK: - Requests

    func testStatusRequestIsTwentyBytes() {
        XCTAssertEqual([UInt8](PowerBaseBLECodec.statusRequest(issueChallenge: false, requestID: nil)), [1, 0x01, 0, 0] + [UInt8](repeating: 0, count: 16))
        XCTAssertEqual([UInt8](PowerBaseBLECodec.statusRequest(issueChallenge: true, requestID: requestID)), [1, 0x01, 1, 0] + Array(1...16))
    }

    func testStartRequestIsFortyFourBytesPlusThePSKd() throws {
        let request = try XCTUnwrap(PowerBaseBLECodec.startRequest(target: eui, requestID: requestID, challenge: challenge, pskd: "J01NME7K"))
        let bytes = [UInt8](request)
        XCTAssertEqual(bytes.count, 44 + 8)
        XCTAssertEqual(Array(bytes[0..<4]), [1, 0x02, 8, 0])
        XCTAssertEqual(Array(bytes[4..<12]), [0x60, 0x55, 0xf9, 0xff, 0xfe, 0x00, 0x12, 0x34])
        XCTAssertEqual(Array(bytes[12..<28]), Array(1...16))
        XCTAssertEqual(Array(bytes[28..<44]), Array(0xA0...0xAF))
        XCTAssertEqual(Array(bytes[44...]), Array("J01NME7K".utf8))

        XCTAssertEqual(PowerBaseBLECodec.startRequest(target: eui, requestID: requestID, challenge: challenge, pskd: "J01NME")?.count, 50)
        XCTAssertEqual(PowerBaseBLECodec.startRequest(target: eui, requestID: requestID, challenge: challenge, pskd: String(repeating: "A", count: 32))?.count, 76)
        for bad in ["J01NM", String(repeating: "A", count: 33), "j01nme7k", "J01NMEI", "J01NMEO", "J01NMEQ", "J01NMEZ", "J01 NME", "J01NMÉ7"] {
            XCTAssertNil(PowerBaseBLECodec.startRequest(target: eui, requestID: requestID, challenge: challenge, pskd: bad), bad)
        }
    }

    func testCancelRequestIsTwentyEightBytes() {
        XCTAssertEqual([UInt8](PowerBaseBLECodec.cancelRequest(target: eui, requestID: requestID)),
                       [1, 0x03, 0, 0, 0x60, 0x55, 0xf9, 0xff, 0xfe, 0x00, 0x12, 0x34] + Array(1...16))
    }

    // MARK: - pb-status responses

    func testStatusResponseFieldsAreReadAtTheirOffsets() throws {
        let response = statusResponse(state: 2, last: 9, flags: 0x01 | 0x02 | 0x04, phase: 2, result: 0, lifetime: 60, attempt: 0x01020304,
                                      challenge: Array(0xA0...0xAF))
        let status = try PowerBaseBLECodec.decodeStatusResponse(response)
        XCTAssertEqual(status.code, .ok)
        XCTAssertEqual(status.eui64, eui)
        XCTAssertEqual(status.state, .attaching)
        XCTAssertEqual(status.lastResult, 9)
        XCTAssertEqual(status.flags, [.attemptActive, .requestMatch, .challengeIssued])
        XCTAssertEqual(status.requestPhase, .running)
        XCTAssertEqual(status.attempt, 0x01020304, "big-endian")
        XCTAssertEqual(status.challenge, challenge)
        XCTAssertEqual(status.challenge?.lifetimeSeconds, 60, "big-endian")

        let waiting = try PowerBaseBLECodec.decodeStatusResponse(statusResponse())
        XCTAssertEqual(waiting.state, .waiting)
        XCTAssertNil(waiting.challenge)
        XCTAssertEqual(waiting.requestPhase, .none)

        let closed = try PowerBaseBLECodec.decodeStatusResponse(statusResponse(code: 0x1a, state: 3, last: 17, flags: 0x02, phase: 4, result: 17))
        XCTAssertEqual(closed.code, .closed)
        XCTAssertEqual(closed.requestPhase, .enrolled)

        let refusedStart = try PowerBaseBLECodec.decodeStatusResponse(statusResponse(flags: 0x02, phase: 3, result: 0x80))
        XCTAssertEqual(refusedStart.requestResult, PowerBaseBLEResult.startRefused)
        XCTAssertEqual(PowerBaseBLEResult.name(8), "joiner_security")
        XCTAssertEqual(PowerBaseBLEResult.name(0x81), "superseded")
    }

    func testStatusResponseOfAnotherLengthVersionOrTypeIsRefused() {
        for length in [0, 1, 4, 39, 41, 56] {
            XCTAssertThrowsError(try PowerBaseBLECodec.decodeStatusResponse(Data(statusResponse().prefix(length) + Data(count: max(0, length - 40))))) {
                XCTAssertEqual($0 as? PowerBaseBLECodecError, .length(length))
            }
        }
        var response = statusResponse()
        response[0] = 2
        XCTAssertThrowsError(try PowerBaseBLECodec.decodeStatusResponse(response)) { XCTAssertEqual($0 as? PowerBaseBLECodecError, .version(2)) }
        response = statusResponse()
        response[1] = 0x82
        XCTAssertThrowsError(try PowerBaseBLECodec.decodeStatusResponse(response)) { XCTAssertEqual($0 as? PowerBaseBLECodecError, .type(0x82)) }
        for offset in [3, 17] {
            response = statusResponse()
            response[offset] = 1
            XCTAssertThrowsError(try PowerBaseBLECodec.decodeStatusResponse(response), "reserved byte \(offset)") {
                XCTAssertEqual($0 as? PowerBaseBLECodecError, .reserved)
            }
        }
    }

    func testStatusResponseWithValuesOutsideTheProtocolIsRefused() {
        func refused(_ response: Data, _ expected: PowerBaseBLECodecError, _ message: String, line: UInt = #line) {
            XCTAssertThrowsError(try PowerBaseBLECodec.decodeStatusResponse(response), message, line: line) {
                XCTAssertEqual($0 as? PowerBaseBLECodecError, expected, message, line: line)
            }
        }
        refused(statusResponse(code: 0x01), .code(0x01), "ACCEPTED is not a pb-status code")
        refused(statusResponse(code: 0x16), .code(0x16), "BUSY is not a pb-status code")
        refused(statusResponse(code: 0x1d), .code(0x1d), "unknown code")
        refused(statusResponse(code: 0xff), .code(0xff), "unknown code")
        refused(statusResponse(eui64: [UInt8](repeating: 0, count: 8)), .field("eui64"), "an all-zero EUI-64 is nobody's")
        refused(statusResponse(state: 4), .field("state"), "unknown state")
        refused(statusResponse(last: 19), .field("last_result"), "unknown result")
        refused(statusResponse(flags: 0x10), .field("flags"), "unknown flag")
        refused(statusResponse(flags: 0x02, phase: 6), .field("phase"), "unknown phase")
        refused(statusResponse(flags: 0x02, phase: 0), .field("phase"), "a matched request has a phase")
        refused(statusResponse(flags: 0x00, phase: 2), .field("phase"), "a phase without a matched request")
        refused(statusResponse(flags: 0x00, result: 8), .field("phase"), "a result without a matched request")
        refused(statusResponse(flags: 0x02, phase: 3, result: 19), .field("request_result"), "unknown request result")
        refused(statusResponse(flags: 0x02, phase: 3, result: 0x82), .field("request_result"), "unknown request result")
        refused(statusResponse(flags: 0x04, lifetime: 60), .field("challenge"), "a challenge flag with a zero challenge")
        refused(statusResponse(flags: 0x04, lifetime: 0, challenge: Array(0xA0...0xAF)), .field("challenge"), "a challenge that is never valid")
        refused(statusResponse(flags: 0x00, lifetime: 60), .field("challenge"), "a lifetime without a challenge")
        refused(statusResponse(flags: 0x00, challenge: Array(0xA0...0xAF)), .field("challenge"), "challenge bytes without the flag are not used")
        refused(statusResponse(code: 0x1a, flags: 0x04, lifetime: 60, challenge: Array(0xA0...0xAF)), .field("challenge"), "a closed board issues none")
    }

    func testAStatusRefusalCarriesNothing() {
        for code: UInt8 in [0x10, 0x11] {
            var response = Data(count: 40)
            response[0] = 1
            response[1] = 0x81
            response[2] = code
            XCTAssertThrowsError(try PowerBaseBLECodec.decodeStatusResponse(response)) {
                XCTAssertEqual($0 as? PowerBaseBLECodecError, .refused(PowerBaseBLECode(rawValue: code)!))
            }
            // The same code with an EUI-64 and a challenge in it is not that refusal, and neither is read.
            XCTAssertThrowsError(try PowerBaseBLECodec.decodeStatusResponse(statusResponse(code: code, flags: 0x04, lifetime: 60, challenge: Array(0xA0...0xAF)))) {
                XCTAssertEqual($0 as? PowerBaseBLECodecError, .field("refusal"))
            }
        }
    }

    // MARK: - pb-start / pb-cancel responses

    func testShortResponsesGiveOnlyTheCodesOfTheirEndpoint() throws {
        XCTAssertEqual(try PowerBaseBLECodec.decodeStartResponse(Data([1, 0x82, 0x01, 0])), .accepted)
        XCTAssertEqual(try PowerBaseBLECodec.decodeStartResponse(Data([1, 0x82, 0x02, 0])), .duplicate)
        XCTAssertEqual(try PowerBaseBLECodec.decodeStartResponse(Data([1, 0x82, 0x16, 0])), .busy)
        XCTAssertEqual(try PowerBaseBLECodec.decodeStartResponse(Data([1, 0x82, 0x17, 0])), .requestConflict)
        XCTAssertEqual(try PowerBaseBLECodec.decodeStartResponse(Data([1, 0x82, 0x14, 0])), .challengeExpired)
        XCTAssertEqual(try PowerBaseBLECodec.decodeCancelResponse(Data([1, 0x83, 0x00, 0])), .ok)
        XCTAssertEqual(try PowerBaseBLECodec.decodeCancelResponse(Data([1, 0x83, 0x19, 0])), .noSuchAttempt)
        XCTAssertEqual(try PowerBaseBLECodec.decodeCancelResponse(Data([1, 0x83, 0x1a, 0])), .closed)

        let badStart: [([UInt8], PowerBaseBLECodecError)] = [
            ([1, 0x82, 0x01], .length(3)), ([1, 0x82, 0x01, 0, 0], .length(5)), ([], .length(0)),
            ([2, 0x82, 0x01, 0], .version(2)), ([1, 0x83, 0x01, 0], .type(0x83)), ([1, 0x81, 0x01, 0], .type(0x81)),
            ([1, 0x82, 0x01, 1], .reserved),
            ([1, 0x82, 0x00, 0], .code(0x00)),   // OK is not a pb-start answer: never read as "accepted"
            ([1, 0x82, 0x19, 0], .code(0x19)), ([1, 0x82, 0x03, 0], .code(0x03)), ([1, 0x82, 0x1d, 0], .code(0x1d)),
        ]
        for (bytes, expected) in badStart {
            XCTAssertThrowsError(try PowerBaseBLECodec.decodeStartResponse(Data(bytes)), "\(bytes)") {
                XCTAssertEqual($0 as? PowerBaseBLECodecError, expected, "\(bytes)")
            }
        }
        let badCancel: [([UInt8], PowerBaseBLECodecError)] = [
            ([1, 0x82, 0x00, 0], .type(0x82)), ([1, 0x83, 0x01, 0], .code(0x01)), ([1, 0x83, 0x13, 0], .code(0x13)),
            ([1, 0x83, 0x00, 7], .reserved), ([0, 0x83, 0x00, 0], .version(0)),
        ]
        for (bytes, expected) in badCancel {
            XCTAssertThrowsError(try PowerBaseBLECodec.decodeCancelResponse(Data(bytes)), "\(bytes)") {
                XCTAssertEqual($0 as? PowerBaseBLECodecError, expected, "\(bytes)")
            }
        }
    }

    func testEveryCodeOfTheHeaderIsKnown() {
        let header: [UInt8: String] = [
            0x00: "OK", 0x01: "ACCEPTED", 0x02: "DUPLICATE", 0x10: "UNSUPPORTED_VERSION", 0x11: "MALFORMED", 0x12: "WRONG_TARGET",
            0x13: "CHALLENGE_INVALID", 0x14: "CHALLENGE_EXPIRED", 0x15: "INVALID_PSKD", 0x16: "BUSY", 0x17: "REQUEST_CONFLICT",
            0x18: "NOT_WAITING", 0x19: "NO_SUCH_ATTEMPT", 0x1a: "CLOSED", 0x1b: "UNAVAILABLE", 0x1c: "INTERNAL",
            0x1d: "INVALID_ENDPOINT", 0x1e: "INVALID_MANAGEMENT", 0x1f: "WINDOW_CLOSED", 0x20: "NOT_ENROLLED",
        ]
        XCTAssertEqual(PowerBaseBLECode.allCases.count, header.count)
        for (value, name) in header {
            XCTAssertEqual(PowerBaseBLECode(rawValue: value)?.name, name)
        }
    }

    // MARK: - pb-start with the bridge endpoint (message 0x04)

    /// The same bytes are in the firmware repository's tools/test_power_base_ble_admission.c
    /// (`GOLDEN_START_EP_HEX`), where the real admission code is fed exactly them. Both sides must
    /// produce and accept these.
    ///   target 6055f9fffe001234, request id a0..af, challenge c0..cf, endpoint format 1,
    ///   port 5684 (0x1634), address fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79, PSKd "J01NME7K"
    private enum BridgeEndpointGolden {
        static let request = "01040800" + "6055f9fffe001234" + "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf" + "c0c1c2c3c4c5c6c7c8c9cacbcccdcecf"
            + "0100" + "1634" + "fd112233445500008c1f2e3d4c5b6a79" + "4a30314e4d45374b"
        static let responseAccepted = "01840100"
        static let responseInvalidEndpoint = "01841d00"
        static let addressText = "fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79"
        static let addressBytes: [UInt8] = [0xfd, 0x11, 0x22, 0x33, 0x44, 0x55, 0x00, 0x00, 0x8c, 0x1f, 0x2e, 0x3d, 0x4c, 0x5b, 0x6a, 0x79]
        static let port = 5684
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    private func bytes(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    func testStartWithEndpointIsByteForByteTheGoldenVectorSharedWithTheFirmware() throws {
        let endpoint = try PowerBaseBLEBridgeEndpoint(address: BridgeEndpointGolden.addressText, port: BridgeEndpointGolden.port)
        XCTAssertEqual([UInt8](endpoint.address), BridgeEndpointGolden.addressBytes, "the hub's text gives the address bytes in network order")
        let id = try XCTUnwrap(PowerBaseBLERequestID(bytes: Data(0xA0...0xAF)))
        let golden = try XCTUnwrap(PowerBaseBLEChallenge(bytes: Data(0xC0...0xCF), lifetimeSeconds: 60))
        let request = try XCTUnwrap(PowerBaseBLECodec.startRequest(target: eui, requestID: id, challenge: golden, pskd: "J01NME7K", endpoint: endpoint))
        XCTAssertEqual(hex(request), BridgeEndpointGolden.request, "the same bytes the firmware's admission test feeds to the real board code")

        let wire = [UInt8](request)
        XCTAssertEqual(wire.count, 64 + 8)
        XCTAssertEqual(Array(wire[0..<4]), [1, 0x04, 8, 0], "version 1, its own message type, pskd_len, reserved 0")
        XCTAssertEqual(Array(wire[4..<12]), [0x60, 0x55, 0xf9, 0xff, 0xfe, 0x00, 0x12, 0x34])
        XCTAssertEqual(Array(wire[12..<28]), Array(0xA0...0xAF))
        XCTAssertEqual(Array(wire[28..<44]), Array(0xC0...0xCF))
        XCTAssertEqual(wire[44], 1, "endpoint format version")
        XCTAssertEqual(wire[45], 0, "reserved")
        XCTAssertEqual(Array(wire[46..<48]), [0x16, 0x34], "the port is big-endian")
        XCTAssertEqual(Array(wire[48..<64]), BridgeEndpointGolden.addressBytes)
        XCTAssertEqual(Array(wire[64...]), Array("J01NME7K".utf8))

        // The board's two answers to it, as bytes.
        XCTAssertEqual(try PowerBaseBLECodec.decodeStartWithEndpointResponse(bytes(BridgeEndpointGolden.responseAccepted)), .accepted)
        XCTAssertEqual(try PowerBaseBLECodec.decodeStartWithEndpointResponse(bytes(BridgeEndpointGolden.responseInvalidEndpoint)), .invalidEndpoint)
    }

    /// The same bytes are in the firmware repository's tools/test_power_base_ble_admission.c
    /// (`GOLDEN_START_MGMT_HEX`) and in its docs/power-base-management.md, section 5: the endpoint
    /// vector above, then management format 1, hub id 10..1f, generation 20..2f, key 30..4f.
    private enum ManagementGolden {
        static let request = "01060800" + "6055f9fffe001234" + "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf" + "c0c1c2c3c4c5c6c7c8c9cacbcccdcecf"
            + "0100" + "1634" + "fd112233445500008c1f2e3d4c5b6a79"
            + "0100" + "101112131415161718191a1b1c1d1e1f" + "202122232425262728292a2b2c2d2e2f"
            + "303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f" + "4a30314e4d45374b"
        static let responseAccepted = "01860100"
        static let responseInvalidManagement = "01861e00"
        static let hubID = "101112131415161718191a1b1c1d1e1f"
        static let generation = "202122232425262728292a2b2c2d2e2f"
        static let key = "303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f"
    }

    func testStartWithManagementIsByteForByteTheGoldenVectorSharedWithTheFirmware() throws {
        let endpoint = try PowerBaseBLEBridgeEndpoint(address: BridgeEndpointGolden.addressText, port: BridgeEndpointGolden.port)
        let credential = try XCTUnwrap(PowerBaseBLEManagementCredential(
            hubIDHex: ManagementGolden.hubID, generationHex: ManagementGolden.generation, keyHex: ManagementGolden.key
        ))
        let id = try XCTUnwrap(PowerBaseBLERequestID(bytes: Data(0xA0...0xAF)))
        let golden = try XCTUnwrap(PowerBaseBLEChallenge(bytes: Data(0xC0...0xCF), lifetimeSeconds: 60))
        let request = try XCTUnwrap(PowerBaseBLECodec.startRequest(
            target: eui, requestID: id, challenge: golden, pskd: "J01NME7K", endpoint: endpoint, management: credential
        ))
        XCTAssertEqual(hex(request), ManagementGolden.request, "the same bytes the firmware's admission test feeds to the real board code")

        let wire = [UInt8](request)
        XCTAssertEqual(wire.count, 130 + 8)
        XCTAssertEqual(Array(wire[0..<4]), [1, 0x06, 8, 0], "version 1, its own message type, pskd_len, reserved 0")
        XCTAssertEqual(Array(wire[4..<64]), Array([UInt8](bytes(BridgeEndpointGolden.request))[4..<64]),
                       "target, request id, challenge and the endpoint block sit exactly where message 0x04 has them")
        XCTAssertEqual(wire[64], 1, "management format version")
        XCTAssertEqual(wire[65], 0, "reserved")
        XCTAssertEqual(Array(wire[66..<82]), Array(0x10...0x1F), "hub id")
        XCTAssertEqual(Array(wire[82..<98]), Array(0x20...0x2F), "enrollment generation")
        XCTAssertEqual(Array(wire[98..<130]), Array(0x30...0x4F), "management key")
        XCTAssertEqual(Array(wire[130...]), Array("J01NME7K".utf8))
        XCTAssertEqual(PowerBaseBLECodec.startWithManagementRequestFixedLength, 130)
        XCTAssertLessThanOrEqual(130 + 32 + 16, PowerBaseBLEProtocol.maximumAttributeLength, "the longest request and its AES-GCM tag fit one characteristic value")

        // The board's two answers to it, as bytes; and only with this message's own type.
        XCTAssertEqual(try PowerBaseBLECodec.decodeStartWithManagementResponse(bytes(ManagementGolden.responseAccepted)), .accepted)
        XCTAssertEqual(try PowerBaseBLECodec.decodeStartWithManagementResponse(bytes(ManagementGolden.responseInvalidManagement)), .invalidManagement)
        for other in ["01820100", "01840100", "01830000"] {
            XCTAssertThrowsError(try PowerBaseBLECodec.decodeStartWithManagementResponse(bytes(other)), other) {
                XCTAssertEqual($0 as? PowerBaseBLECodecError, .type(bytes(other)[1]))
            }
        }
        XCTAssertThrowsError(try PowerBaseBLECodec.decodeStartResponse(bytes(ManagementGolden.responseAccepted)), "0x86 is not an answer to the first start")
        XCTAssertThrowsError(try PowerBaseBLECodec.decodeStartWithEndpointResponse(bytes("01841e00")), "INVALID_MANAGEMENT is not a code of message 0x04") {
            XCTAssertEqual($0 as? PowerBaseBLECodecError, .code(0x1e))
        }
        XCTAssertEqual(PowerBaseBLECode.invalidManagement.rawValue, 0x1e)
        XCTAssertEqual(PowerBaseBLECode.invalidManagement.name, "INVALID_MANAGEMENT")

        // The two earlier start messages are byte for byte what they were.
        XCTAssertEqual(hex(try XCTUnwrap(PowerBaseBLECodec.startRequest(target: eui, requestID: id, challenge: golden, pskd: "J01NME7K", endpoint: endpoint))),
                       BridgeEndpointGolden.request)
    }

    func testAManagementCredentialIsExactAndHasNoTextualForm() throws {
        let hub = ManagementGolden.hubID, generation = ManagementGolden.generation, key = ManagementGolden.key
        let credential = try XCTUnwrap(PowerBaseBLEManagementCredential(hubIDHex: hub, generationHex: generation, keyHex: key))
        XCTAssertEqual(credential.generationHex, generation)
        XCTAssertEqual(credential.hubID, Data(0x10...0x1F))

        // Exactly 32, 32 and 64 lower-case hex digits; nothing is trimmed, padded or repaired.
        XCTAssertNil(PowerBaseBLEManagementCredential(hubIDHex: String(hub.dropLast()), generationHex: generation, keyHex: key))
        XCTAssertNil(PowerBaseBLEManagementCredential(hubIDHex: hub + "00", generationHex: generation, keyHex: key))
        XCTAssertNil(PowerBaseBLEManagementCredential(hubIDHex: hub, generationHex: generation.uppercased(), keyHex: key))
        XCTAssertNil(PowerBaseBLEManagementCredential(hubIDHex: hub, generationHex: generation, keyHex: String(key.dropLast(2))))
        XCTAssertNil(PowerBaseBLEManagementCredential(hubIDHex: hub, generationHex: generation, keyHex: " " + key.dropFirst()))
        XCTAssertNil(PowerBaseBLEManagementCredential(hubIDHex: hub, generationHex: generation, keyHex: String(repeating: "g", count: 64)))
        // A part made of zeros names nothing.
        XCTAssertNil(PowerBaseBLEManagementCredential(hubIDHex: String(repeating: "0", count: 32), generationHex: generation, keyHex: key))
        XCTAssertNil(PowerBaseBLEManagementCredential(hubIDHex: hub, generationHex: String(repeating: "0", count: 32), keyHex: key))
        XCTAssertNil(PowerBaseBLEManagementCredential(hubIDHex: hub, generationHex: generation, keyHex: String(repeating: "0", count: 64)))
        XCTAssertNil(PowerBaseBLEManagementCredential(hubID: Data(count: 15), generation: Data(0x20...0x2F), key: Data(0x30...0x4F)))

        // Nothing that turns a value into text shows the key (or any other part).
        var dumped = ""
        dump(credential, to: &dumped)
        for text in ["\(credential)", String(describing: credential), String(reflecting: credential), dumped] {
            XCTAssertFalse(text.contains("3031"), text)
            XCTAssertFalse(text.contains("48, 49"), text)
            XCTAssertFalse(text.lowercased().contains("key"), text)
            XCTAssertTrue(text.contains("redacted"), text)
        }
        XCTAssertTrue(Mirror(reflecting: credential).children.isEmpty, "reflection finds no stored value")
    }

    func testStartWithManagementHasEveryLengthAndNeverAnInvalidPSKd() throws {
        let endpoint = try PowerBaseBLEBridgeEndpoint(addressBytes: Data(BridgeEndpointGolden.addressBytes), port: 5684)
        let credential = try XCTUnwrap(PowerBaseBLEManagementCredential(hubID: Data(0x10...0x1F), generation: Data(0x20...0x2F), key: Data(0x30...0x4F)))
        for length in 6...32 {
            let pskd = String(repeating: "A", count: length)
            let request = try XCTUnwrap(PowerBaseBLECodec.startRequest(
                target: eui, requestID: requestID, challenge: challenge, pskd: pskd, endpoint: endpoint, management: credential
            ))
            XCTAssertEqual(request.count, 130 + length)
            XCTAssertEqual(request[2], UInt8(length))
        }
        for bad in ["", "ABCDE", String(repeating: "A", count: 33), "J01NMEI", "j01nme7k"] {
            XCTAssertNil(PowerBaseBLECodec.startRequest(
                target: eui, requestID: requestID, challenge: challenge, pskd: bad, endpoint: endpoint, management: credential
            ), bad)
        }
    }

    func testTheManagementCapabilityIsItsOwnName() throws {
        func capabilities(_ enroll: String) throws -> PowerBaseBLECapabilities {
            try PowerBaseBLEVersion.validate(Data((#"{"prov":{"ver":"v1.1","sec_ver":2,"sec_patch_ver":1,"cap":[]},"pb_enroll":"# + enroll + "}").utf8))
        }
        let real = #"{"prov":{"ver":"v1.1","sec_ver":2,"sec_patch_ver":1,"cap":[]},"pb_enroll":{"proto":1,"cap":["bridge_endpoint_v1","mgmt_v1"]}}"#
        XCTAssertEqual(try PowerBaseBLEVersion.validate(Data(real.utf8)), [.bridgeEndpointV1, .managementV1], "what pb_ble_service.h answered before the release receipt")
        XCTAssertEqual(try capabilities(#"{"proto":1,"cap":["mgmt_v1"]}"#), [.managementV1])
        XCTAssertEqual(try capabilities(#"{"proto":1,"cap":["bridge_endpoint_v1"]}"#), [.bridgeEndpointV1], "firmware before management")
        XCTAssertEqual(try capabilities(#"{"proto":1,"cap":["mgmt_v2","MGMT_V1","mgmt"]}"#), [], "the name is exact")
        let misplaced = #"{"prov":{"ver":"v1.1","sec_ver":2,"sec_patch_ver":1,"cap":["mgmt_v1"]},"pb_enroll":{"proto":1}}"#
        XCTAssertEqual(try PowerBaseBLEVersion.validate(Data(misplaced.utf8)), [], "not among Espressif's own capabilities")
    }

    func testABoardWithoutTheManagementCapabilityIsNeverSentThatStart() async throws {
        final class VersionOnlyLink: PowerBaseBLELink, @unchecked Sendable {
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
        let endpoint = try PowerBaseBLEBridgeEndpoint(addressBytes: Data(BridgeEndpointGolden.addressBytes), port: 5684)
        let credential = try XCTUnwrap(PowerBaseBLEManagementCredential(hubID: Data(0x10...0x1F), generation: Data(0x20...0x2F), key: Data(0x30...0x4F)))
        func version(_ cap: String) -> String { #"{"prov":{"ver":"v1.1","sec_ver":2,"sec_patch_ver":1,"cap":[]},"pb_enroll":{"proto":1"# + cap + "}}" }

        // Neither capability, or only one of the two: nothing is sent -- not this message and not an older one in its place.
        for cap in ["", #","cap":["bridge_endpoint_v1"]"#, #","cap":["mgmt_v1"]"#] {
            let link = VersionOnlyLink(version: version(cap))
            let client = PowerBaseBLEBoardClient(link: link)
            try await client.checkVersion()
            do {
                _ = try await client.start(target: eui, requestID: requestID, challenge: challenge, pskd: "J01NME7K", endpoint: endpoint, management: credential)
                XCTFail("the management start must not be sent (\(cap))")
            } catch {
                XCTAssertEqual(error as? PowerBaseBLEClientError, .invalidInput("capability"), cap)
            }
            XCTAssertEqual(link.endpoints, [.version], cap)
        }
        // With both the request is attempted (and fails here only for want of a session).
        let link = VersionOnlyLink(version: version(#","cap":["bridge_endpoint_v1","mgmt_v1"]"#))
        let capable = PowerBaseBLEBoardClient(link: link)
        try await capable.checkVersion()
        do {
            _ = try await capable.start(target: eui, requestID: requestID, challenge: challenge, pskd: "J01NME7K", endpoint: endpoint, management: credential)
            XCTFail("no session exists")
        } catch {
            XCTAssertEqual(error as? PowerBaseBLEClientError, .noSession)
        }
    }

    func testTheFirstStartMessageIsUnchangedByTheNewOne() throws {
        // Byte for byte what version 1 always sent: nothing was appended to it.
        let id = try XCTUnwrap(PowerBaseBLERequestID(bytes: Data(0xA0...0xAF)))
        let golden = try XCTUnwrap(PowerBaseBLEChallenge(bytes: Data(0xC0...0xCF), lifetimeSeconds: 60))
        let request = try XCTUnwrap(PowerBaseBLECodec.startRequest(target: eui, requestID: id, challenge: golden, pskd: "J01NME7K"))
        XCTAssertEqual(hex(request), "01020800" + "6055f9fffe001234" + "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf" + "c0c1c2c3c4c5c6c7c8c9cacbcccdcecf" + "4a30314e4d45374b")
        XCTAssertEqual(request.count, 52)
    }

    func testStartWithEndpointHasEveryLengthFromSeventyToNinetySix() throws {
        let endpoint = try PowerBaseBLEBridgeEndpoint(addressBytes: Data(BridgeEndpointGolden.addressBytes), port: 1)
        let alphabet = Array("0123456789ABCDEFGHJKLMNPRSTUVWXY")
        for length in 6...32 {
            let pskd = String((0..<length).map { alphabet[$0 % alphabet.count] })
            let request = try XCTUnwrap(PowerBaseBLECodec.startRequest(target: eui, requestID: requestID, challenge: challenge, pskd: pskd, endpoint: endpoint), "\(length)")
            XCTAssertEqual(request.count, 64 + length)
            XCTAssertEqual(request[2], UInt8(length), "pskd_len")
            XCTAssertEqual(Array(request[46..<48]), [0, 1])
            XCTAssertLessThanOrEqual(request.count + 16, PowerBaseBLEProtocol.maximumAttributeLength, "fits one characteristic value with its tag")
        }
        for bad in ["J01NM", String(repeating: "A", count: 33), "j01nme7k", "J01NMEI", "J01 NME", ""] {
            XCTAssertNil(PowerBaseBLECodec.startRequest(target: eui, requestID: requestID, challenge: challenge, pskd: bad, endpoint: endpoint), bad)
        }
        let highest = try PowerBaseBLEBridgeEndpoint(addressBytes: Data(BridgeEndpointGolden.addressBytes), port: 65535)
        let request = try XCTUnwrap(PowerBaseBLECodec.startRequest(target: eui, requestID: requestID, challenge: challenge, pskd: "J01NME", endpoint: highest))
        XCTAssertEqual(Array(request[46..<48]), [0xff, 0xff])
    }

    func testStartWithEndpointAnswersAreReadOnlyWithTheirOwnType() {
        XCTAssertEqual(try PowerBaseBLECodec.decodeStartWithEndpointResponse(Data([1, 0x84, 0x01, 0])), .accepted)
        XCTAssertEqual(try PowerBaseBLECodec.decodeStartWithEndpointResponse(Data([1, 0x84, 0x02, 0])), .duplicate)
        XCTAssertEqual(try PowerBaseBLECodec.decodeStartWithEndpointResponse(Data([1, 0x84, 0x17, 0])), .requestConflict)
        XCTAssertEqual(try PowerBaseBLECodec.decodeStartWithEndpointResponse(Data([1, 0x84, 0x1d, 0])), .invalidEndpoint)
        let bad: [([UInt8], PowerBaseBLECodecError)] = [
            // What a board without the capability answers (it knows only the first start): not an answer to this message.
            ([1, 0x82, 0x11, 0], .type(0x82)), ([1, 0x82, 0x01, 0], .type(0x82)),
            ([1, 0x84, 0x00, 0], .code(0x00)), ([1, 0x84, 0x19, 0], .code(0x19)), ([1, 0x84, 0x1e, 0], .code(0x1e)),
            ([1, 0x84, 0x01, 1], .reserved), ([2, 0x84, 0x01, 0], .version(2)), ([1, 0x84, 0x01], .length(3)), ([1, 0x84, 0x01, 0, 0], .length(5)),
        ]
        for (wire, expected) in bad {
            XCTAssertThrowsError(try PowerBaseBLECodec.decodeStartWithEndpointResponse(Data(wire)), "\(wire)") {
                XCTAssertEqual($0 as? PowerBaseBLECodecError, expected, "\(wire)")
            }
        }
        // And the first start's answer never accepts the new type or the new code.
        XCTAssertThrowsError(try PowerBaseBLECodec.decodeStartResponse(Data([1, 0x84, 0x01, 0])))
        XCTAssertThrowsError(try PowerBaseBLECodec.decodeStartResponse(Data([1, 0x82, 0x1d, 0])))
    }

    func testABridgeEndpointIsOnlyAThreadMeshLocalEID() throws {
        typealias Rejection = PowerBaseBLEBridgeEndpoint.Rejection
        func rejection(_ text: String, port: Int = 5684) -> Rejection? {
            do {
                _ = try PowerBaseBLEBridgeEndpoint(address: text, port: port)
                return nil
            } catch {
                return error as? Rejection
            }
        }
        XCTAssertNil(rejection("fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79"))
        XCTAssertNil(rejection("fd11:2233:4455:0000:8c1f:2e3d:4c5b:6a79"), "leading zeros")
        XCTAssertNil(rejection("fdde:ad00:beef::1"), "compressed")
        XCTAssertEqual(try PowerBaseBLEBridgeEndpoint(address: "fdde:ad00:beef::1", port: 1).address,
                       Data([0xfd, 0xde, 0xad, 0x00, 0xbe, 0xef, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]))
        XCTAssertEqual(try PowerBaseBLEBridgeEndpoint(address: "fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79", port: 5684).addressText,
                       "fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79")
        XCTAssertEqual(try PowerBaseBLEBridgeEndpoint(address: "fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79", port: 5684).meshLocalPrefix,
                       Data([0xfd, 0x11, 0x22, 0x33, 0x44, 0x55, 0x00, 0x00]))

        XCTAssertEqual(rejection("::"), .unspecified)
        XCTAssertEqual(rejection("::1"), .loopback)
        XCTAssertEqual(rejection("::ffff:c0a8:10a"), .ipv4Embedded, "IPv4-mapped")
        XCTAssertEqual(rejection("::c0a8:10a"), .ipv4Embedded, "IPv4-compatible")
        XCTAssertEqual(rejection("ff03::1"), .multicast)
        XCTAssertEqual(rejection("fe80::8c1f:2e3d:4c5b:6a79"), .linkLocal)
        XCTAssertEqual(rejection("febf::1"), .linkLocal)
        XCTAssertEqual(rejection("2001:db8::1"), .notMeshLocal)
        XCTAssertEqual(rejection("fc11:2233:4455:0:8c1f:2e3d:4c5b:6a79"), .notMeshLocal, "fc00::/8 is not where a Mesh-Local Prefix is")
        XCTAssertEqual(rejection("fd11:2233:4455:0:0:ff:fe00:4c00"), .locator, "an RLOC")
        XCTAssertEqual(rejection("fd11:2233:4455::ff:fe00:fc38"), .locator, "an ALOC")
        XCTAssertNil(rejection("fd11:2233:4455:0:0:ff:fe01:4c00"), "only the exact locator form is one")
        XCTAssertEqual(rejection("fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79", port: 0), .port)
        XCTAssertEqual(rejection("fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79", port: 65536), .port)
        XCTAssertEqual(rejection("fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79", port: -1), .port)
        XCTAssertNil(rejection("fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79", port: 1))
        XCTAssertNil(rejection("fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79", port: 65535))

        // Not an IPv6 literal at all: never "repaired" into one.
        let notLiterals = [
            "", ":", "192.168.1.10", "::ffff:192.168.1.10", "::192.168.1.10", "fd11:2233:4455::192.168.1.10",
            "fe80::1%wpan0", "fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79%wpan0", "fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79%25wpan0",
            "[fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79]", "[fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79]:5684",
            "coap://[fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79]:5684", "http://192.168.1.10:8787", "https://hub.local",
            "hub.local", "jogakbo-hub", "localhost", "FD11:2233:4455:0:8C1F:2E3D:4C5B:6A79",
            " fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79", "fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79 ", "fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79\n",
            "fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79:1", "fd11:2233:4455:0:8c1f:2e3d:4c5b", "fd11::8c1f::1", "fd11:22333::1",
            "fd11:2233:4455:0:8c1f:2e3d:4c5b:", ":fd11:2233:4455:0:8c1f:2e3d:4c5b", "fd11:::1", "fd11:2233:4455:0:8c1f:2e3d:4c5b:6a79::",
            "fd11:2233:4455:0:8c1f:2e3d:4c5b:6a7g", "ｆｄ11::1",
        ]
        for text in notLiterals {
            XCTAssertEqual(rejection(text), .notAnIPv6Literal, text)
        }

        // The byte form is checked the same way.
        XCTAssertThrowsError(try PowerBaseBLEBridgeEndpoint(addressBytes: Data(count: 16), port: 5684)) { XCTAssertEqual($0 as? Rejection, .unspecified) }
        XCTAssertThrowsError(try PowerBaseBLEBridgeEndpoint(addressBytes: Data(count: 15), port: 5684)) { XCTAssertEqual($0 as? Rejection, .notAnIPv6Literal) }
        XCTAssertThrowsError(try PowerBaseBLEBridgeEndpoint(addressBytes: Data(BridgeEndpointGolden.addressBytes) + Data([0]), port: 5684))
    }

    // MARK: - proto-ver

    func testOnlySecurity2Patch1WithEnrollmentProtocol1IsAccepted() {
        let real = #"{"prov":{"ver":"v1.1","sec_ver":2,"sec_patch_ver":1,"cap":[]},"pb_enroll":{"proto":1}}"#
        XCTAssertNoThrow(try PowerBaseBLEVersion.validate(Data(real.utf8)))

        func failure(_ json: String) -> PowerBaseBLEVersion.Failure? {
            do {
                try PowerBaseBLEVersion.validate(Data(json.utf8))
                return nil
            } catch {
                return error as? PowerBaseBLEVersion.Failure
            }
        }
        XCTAssertEqual(failure(real.replacingOccurrences(of: #""sec_ver":2"#, with: #""sec_ver":0"#)), .securityVersion(0), "Security 0")
        XCTAssertEqual(failure(real.replacingOccurrences(of: #""sec_ver":2"#, with: #""sec_ver":1"#)), .securityVersion(1), "Security 1")
        XCTAssertEqual(failure(real.replacingOccurrences(of: #""sec_ver":2"#, with: #""sec_ver":3"#)), .securityVersion(3), "unknown scheme")
        XCTAssertEqual(failure(real.replacingOccurrences(of: #""cap":[]"#, with: #""cap":["no_sec"]"#)), .securityVersion(2), "an unsecured mode on offer")
        XCTAssertEqual(failure(real.replacingOccurrences(of: #""sec_patch_ver":1"#, with: #""sec_patch_ver":0"#)), .securityPatchVersion(0))
        XCTAssertEqual(failure(real.replacingOccurrences(of: #""sec_patch_ver":1"#, with: #""sec_patch_ver":2"#)), .securityPatchVersion(2), "unknown patch")
        XCTAssertEqual(failure(real.replacingOccurrences(of: #","sec_patch_ver":1"#, with: "")), .securityPatchVersion(0), "absent = patch 0")
        XCTAssertEqual(failure(real.replacingOccurrences(of: #""proto":1"#, with: #""proto":2"#)), .enrollmentProtocol(2))
        XCTAssertEqual(failure(#"{"prov":{"ver":"v1.1","sec_ver":2,"sec_patch_ver":1,"cap":[]}}"#), .malformed, "not a Power Base")
        XCTAssertEqual(failure(#"{"prov":{"ver":"v1.1","sec_ver":"2","sec_patch_ver":1},"pb_enroll":{"proto":1}}"#), .malformed)
        XCTAssertEqual(failure("ESP"), .malformed)
        XCTAssertEqual(failure(""), .malformed)
    }

    func testTheBridgeEndpointCapabilityIsReadFromTheEnrollmentBlockOnly() throws {
        let old = #"{"prov":{"ver":"v1.1","sec_ver":2,"sec_patch_ver":1,"cap":[]},"pb_enroll":{"proto":1}}"#
        let new = #"{"prov":{"ver":"v1.1","sec_ver":2,"sec_patch_ver":1,"cap":[]},"pb_enroll":{"proto":1,"cap":["bridge_endpoint_v1"]}}"#
        XCTAssertEqual(try PowerBaseBLEVersion.validate(Data(old.utf8)), [], "firmware before the capability list")
        XCTAssertEqual(try PowerBaseBLEVersion.validate(Data(new.utf8)), [.bridgeEndpointV1], "what pb_ble_service.h answered before management was added")

        func capabilities(_ enroll: String) throws -> PowerBaseBLECapabilities {
            try PowerBaseBLEVersion.validate(Data((#"{"prov":{"ver":"v1.1","sec_ver":2,"sec_patch_ver":1,"cap":[]},"pb_enroll":"# + enroll + "}").utf8))
        }
        XCTAssertEqual(try capabilities(#"{"proto":1,"cap":[]}"#), [])
        XCTAssertEqual(try capabilities(#"{"proto":1,"cap":["something_newer","bridge_endpoint_v1"]}"#), [.bridgeEndpointV1], "unknown names are ignored")
        XCTAssertEqual(try capabilities(#"{"proto":1,"cap":["bridge_endpoint_v2"]}"#), [], "another endpoint format is not this capability")
        XCTAssertEqual(try capabilities(#"{"proto":1,"cap":["BRIDGE_ENDPOINT_V1"]}"#), [], "the name is exact")
        // A capability named among Espressif's own (`prov.cap`) is not the board's enrollment capability.
        let misplaced = #"{"prov":{"ver":"v1.1","sec_ver":2,"sec_patch_ver":1,"cap":["bridge_endpoint_v1"]},"pb_enroll":{"proto":1}}"#
        XCTAssertEqual(try PowerBaseBLEVersion.validate(Data(misplaced.utf8)), [])
        for malformed in [#"{"proto":1,"cap":"bridge_endpoint_v1"}"#, #"{"proto":1,"cap":[1]}"#, #"{"proto":1,"cap":{"bridge_endpoint_v1":true}}"#] {
            XCTAssertThrowsError(try capabilities(malformed), malformed) { XCTAssertEqual($0 as? PowerBaseBLEVersion.Failure, .malformed) }
        }
        // The capability never stands in for the security checks.
        XCTAssertThrowsError(try PowerBaseBLEVersion.validate(Data(new.replacingOccurrences(of: #""sec_ver":2"#, with: #""sec_ver":1"#).utf8))) {
            XCTAssertEqual($0 as? PowerBaseBLEVersion.Failure, .securityVersion(1))
        }
        XCTAssertThrowsError(try PowerBaseBLEVersion.validate(Data(new.replacingOccurrences(of: #""sec_patch_ver":1"#, with: #""sec_patch_ver":0"#).utf8))) {
            XCTAssertEqual($0 as? PowerBaseBLEVersion.Failure, .securityPatchVersion(0))
        }
        XCTAssertThrowsError(try PowerBaseBLEVersion.validate(Data(new.replacingOccurrences(of: #""proto":1"#, with: #""proto":2"#).utf8))) {
            XCTAssertEqual($0 as? PowerBaseBLEVersion.Failure, .enrollmentProtocol(2))
        }
    }

    func testABoardWithoutTheCapabilityIsNeverSentTheEndpointStart() async throws {
        /// A link that answers `proto-ver` and records every exchange.
        final class VersionOnlyLink: PowerBaseBLELink, @unchecked Sendable {
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
        let endpoint = try PowerBaseBLEBridgeEndpoint(addressBytes: Data(BridgeEndpointGolden.addressBytes), port: 5684)

        let oldBoard = VersionOnlyLink(version: #"{"prov":{"ver":"v1.1","sec_ver":2,"sec_patch_ver":1,"cap":[]},"pb_enroll":{"proto":1}}"#)
        let client = PowerBaseBLEBoardClient(link: oldBoard)
        try await client.checkVersion()
        let none = await client.capabilities()
        XCTAssertEqual(none, [], "an older board lists no capability")
        do {
            _ = try await client.start(target: eui, requestID: requestID, challenge: challenge, pskd: "J01NME7K", endpoint: endpoint)
            XCTFail("the endpoint start must not be sent")
        } catch {
            XCTAssertEqual(error as? PowerBaseBLEClientError, .invalidInput("capability"))
        }
        XCTAssertEqual(oldBoard.endpoints, [.version], "nothing was written to pb-start -- neither the new message nor the old one in its place")

        // With the capability the request is attempted (and fails here only for want of a session).
        let newBoard = VersionOnlyLink(version: #"{"prov":{"ver":"v1.1","sec_ver":2,"sec_patch_ver":1,"cap":[]},"pb_enroll":{"proto":1,"cap":["bridge_endpoint_v1"]}}"#)
        let capable = PowerBaseBLEBoardClient(link: newBoard)
        let before = await capable.capabilities()
        XCTAssertEqual(before, [], "nothing is assumed before proto-ver was read")
        try await capable.checkVersion()
        let listed = await capable.capabilities()
        XCTAssertEqual(listed, [.bridgeEndpointV1])
        do {
            _ = try await capable.start(target: eui, requestID: requestID, challenge: challenge, pskd: "J01NME7K", endpoint: endpoint)
            XCTFail("no session exists")
        } catch {
            XCTAssertEqual(error as? PowerBaseBLEClientError, .noSession)
        }
    }

    // MARK: - Setup code

    func testSetupCodeIsTwentySixBase32CharactersAndIsNeverRepaired() {
        let code = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        XCTAssertEqual(PowerBaseSetupCode.normalized(code), code)
        XCTAssertEqual(PowerBaseSetupCode.normalized("  " + code + "\n"), code, "surrounding whitespace only")
        XCTAssertEqual(PowerBaseSetupCode.normalized("abcdefghijklmnopqrstuvwxyz"), code, "ASCII lower case is raised")
        XCTAssertEqual(PowerBaseSetupCode.normalized("234567ABCDEFGHIJKLMNOPQRST"), "234567ABCDEFGHIJKLMNOPQRST")
        for bad in [
            "", String(code.dropLast()), code + "A",       // length
            "ABCDE FGHIJKLMNOPQRSTUVWXYZ",                 // a space inside is not removed
            "ABCDE-FGHIJKLMNOPQRSTUVWXY",                  // nor a separator
            "0BCDEFGHIJKLMNOPQRSTUVWXYZ", "1BCDEFGHIJKLMNOPQRSTUVWXYZ", "8BCDEFGHIJKLMNOPQRSTUVWXYZ", "9BCDEFGHIJKLMNOPQRSTUVWXYZ", // not base32
            "ÀBCDEFGHIJKLMNOPQRSTUVWXYZ", "ＡBCDEFGHIJKLMNOPQRSTUVWXYZ",   // not ASCII
            "ABCDEFGHIJKLMNOPQRSTUVWXY=",
        ] {
            XCTAssertNil(PowerBaseSetupCode.normalized(bad), bad)
        }
    }
}
