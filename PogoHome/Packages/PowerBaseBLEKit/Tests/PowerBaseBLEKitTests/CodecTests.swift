#if DEBUG
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
        ]
        XCTAssertEqual(PowerBaseBLECode.allCases.count, header.count)
        for (value, name) in header {
            XCTAssertEqual(PowerBaseBLECode(rawValue: value)?.name, name)
        }
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
#endif
