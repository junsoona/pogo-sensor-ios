import XCTest
@testable import PowerBaseBLEKit

/// The Power Base setup QR code (firmware repository, docs/power-base.md "QR 설정 코드"), read
/// against the vector file the firmware repository's generator is tested with
/// (`Support/power-base-setup-qr-vectors.json`, a byte-for-byte copy of its
/// `tools/power_base_setup_qr_vectors.json`). The vectors were written by neither implementation:
/// the codes come from Python's base64 and every refusal is spelled out with its reason.
///
/// Every EUI-64 and setup code here is made up.
final class SetupQRPayloadTests: XCTestCase {
    private typealias Payload = PowerBaseSetupQRPayload

    private static let eui64 = "00124b0001a2b3c4"
    /// base32 of the 16 bytes "abcdefghijklmnop" (RFC 4648's own vectors continue the same string).
    private static let setupCode = "MFRGGZDFMZTWQ2LKNNWG23TPOA"
    private static let text = "POGO-PB:1:" + eui64 + ":" + setupCode

    private func error(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> PowerBaseSetupQRError? {
        do {
            _ = try Payload(parsing: text)
            return nil
        } catch let error as PowerBaseSetupQRError {
            return error
        } catch {
            XCTFail("another error type", file: file, line: line)
            return nil
        }
    }

    func testACodeIsReadAsItsTwoFields() throws {
        XCTAssertEqual(Self.text.utf8.count, Payload.encodedLength)
        let payload = try Payload(parsing: Self.text)
        XCTAssertEqual(payload.eui64.hex, Self.eui64)
        XCTAssertEqual(payload.setupCode, Self.setupCode)
        // What the screens type and what the board is authenticated with is this same string.
        XCTAssertEqual(PowerBaseSetupCode.normalized(payload.setupCode), payload.setupCode)
    }

    /// RFC 4648: 26 characters carry 130 bits, a setup code has 128. Known encodings, by hand.
    func testTheSetupCodeIsCanonicalBase32OfSixteenBytes() throws {
        let known = [
            String(repeating: "A", count: 26),                  // sixteen 0x00
            String(repeating: "7", count: 25) + "4",            // sixteen 0xff: 11111 … 111|00
        ]
        for code in known {
            XCTAssertEqual(try Payload(parsing: "POGO-PB:1:" + Self.eui64 + ":" + code).setupCode, code)
        }
        // The last character has two bits that belong to no byte. Only the eight characters whose
        // two low bits are zero can end a code.
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var accepted = ""
        for last in alphabet {
            let code = String(Self.setupCode.dropLast()) + String(last)
            if error("POGO-PB:1:" + Self.eui64 + ":" + code) == nil {
                accepted.append(last)
            } else {
                XCTAssertEqual(error("POGO-PB:1:" + Self.eui64 + ":" + code), .invalidSetupCode, String(last))
                // Typing is a different rule, and stays as it was.
                XCTAssertNotNil(PowerBaseSetupCode.normalized(code))
            }
        }
        XCTAssertEqual(accepted, "AEIMQUY4")
    }

    /// Every single-byte change of a valid code, with every ASCII byte: accepted only when the
    /// result is itself a code of this format, and then read as exactly what it says.
    func testEverySingleByteChangeIsRefusedOrIsAnotherCode() throws {
        let original = Array(Self.text.utf8)
        let hex = Set("0123456789abcdef".utf8)
        let base32 = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
        let lastCharacters = Set("AEIMQUY4".utf8)
        var acceptedChanges = 0
        for position in original.indices {
            for byte in UInt8(0)...UInt8(127) where byte != original[position] {
                var changed = original
                changed[position] = byte
                let text = String(decoding: changed, as: UTF8.self)
                let mayBeValid: Bool
                switch position {
                case 10..<26: mayBeValid = hex.contains(byte)
                case 27..<52: mayBeValid = base32.contains(byte)
                case 52: mayBeValid = lastCharacters.contains(byte)
                default: mayBeValid = false
                }
                if mayBeValid {
                    let payload = try Payload(parsing: text)
                    XCTAssertEqual(Array(payload.eui64.hex.utf8), Array(changed[10..<26]))
                    XCTAssertEqual(Array(payload.setupCode.utf8), Array(changed[27..<53]))
                    acceptedChanges += 1
                } else {
                    XCTAssertNotNil(error(text), "position \(position), byte \(byte)")
                }
            }
        }
        XCTAssertEqual(acceptedChanges, 16 * 15 + 25 * 31 + 7)
        // Shorter and longer by any one byte.
        for position in original.indices {
            var shorter = original
            shorter.remove(at: position)
            XCTAssertNotNil(error(String(decoding: shorter, as: UTF8.self)), "without byte \(position)")
        }
        for position in 0...original.count {
            for byte in [UInt8(ascii: "A"), UInt8(ascii: "0"), UInt8(ascii: ":"), UInt8(ascii: " "), 0x0A, 0x00] {
                var longer = original
                longer.insert(byte, at: position)
                XCTAssertNotNil(error(String(decoding: longer, as: UTF8.self)), "byte \(byte) inserted at \(position)")
            }
        }
    }

    /// Swift compares strings by canonical equivalence: U+212A KELVIN SIGN equals "K". The parser
    /// compares bytes, so a look-alike is another string.
    func testAStringThatSwiftCallsEqualIsStillRefused() throws {
        let lookAlike = Self.text.replacingOccurrences(of: "K", with: "\u{212A}")
        XCTAssertTrue(Self.setupCode.contains("K"))
        XCTAssertEqual(lookAlike, Self.text, "equal as Swift strings")
        XCTAssertNotEqual(Array(lookAlike.utf8), Array(Self.text.utf8))
        XCTAssertNotNil(error(lookAlike))
        XCTAssertNil(error(Self.text))
    }

    /// The EUI-64 of all ones is no board's either, but the format refuses only all zero; the
    /// generator refuses to make a code for it, like the tool that prepares a board.
    func testOnlyTheAllZeroEUI64IsRefusedByTheFormat() {
        XCTAssertEqual(error("POGO-PB:1:" + String(repeating: "0", count: 16) + ":" + Self.setupCode), .invalidEUI64)
        XCTAssertNil(error("POGO-PB:1:" + String(repeating: "0", count: 15) + "1:" + Self.setupCode))
    }

    func testNothingThatPrintsAPayloadOrAnErrorShowsTheCode() throws {
        let payload = try Payload(parsing: Self.text)
        var dumped = ""
        dump(payload, to: &dumped)
        let shown = ["\(payload)", String(describing: payload), String(reflecting: payload), dumped, "\([payload])", "\(Optional(payload) as Any)"]
        for text in shown {
            XCTAssertFalse(text.contains(Self.setupCode), text)
            XCTAssertFalse(text.contains(Self.eui64), text)
            XCTAssertFalse(text.contains("MFRG"), text)
        }
        // An error has no room for the text it refused.
        for refused in PowerBaseSetupQRError.allCases {
            XCTAssertNil(Mirror(reflecting: refused).children.first)
        }
        let secretLooking = "POGO-PB:1:" + Self.eui64 + ":" + Self.setupCode.lowercased()
        let refusal = try XCTUnwrap(error(secretLooking))
        for text in [String(describing: refusal), String(reflecting: refusal), (refusal as NSError).description, refusal.localizedDescription] {
            XCTAssertFalse(text.lowercased().contains(Self.setupCode.lowercased()), text)
            XCTAssertFalse(text.contains(Self.eui64), text)
        }
    }
}

#if os(macOS)
/// The shared vector file.
final class SetupQRVectorTests: XCTestCase {
    private struct Vectors: Decodable {
        struct Valid: Decodable {
            let name: String
            let eui64: String
            let setup_code_hex: String
            let setup_code: String
            let payload: String
        }
        struct Invalid: Decodable {
            let name: String
            let payload: String
            let error: String
        }
        let format: String
        let format_version: Int
        let payload_bytes: Int
        let valid: [Valid]
        let invalid_payloads: [Invalid]
    }

    private static let errorNames: [String: PowerBaseSetupQRError] = [
        "not_power_base_code": .notPowerBaseCode, "unsupported_version": .unsupportedVersion, "malformed": .malformed,
        "invalid_eui64": .invalidEUI64, "invalid_setup_code": .invalidSetupCode,
    ]

    private var vectorsURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Support/power-base-setup-qr-vectors.json")
    }

    private func vectors() throws -> Vectors {
        try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: vectorsURL))
    }

    func testTheVectorsAreOfThisFormat() throws {
        let vectors = try vectors()
        XCTAssertEqual(vectors.format, "POGO-PB")
        XCTAssertEqual(vectors.format_version, PowerBaseSetupQRPayload.formatVersion)
        XCTAssertEqual(vectors.payload_bytes, PowerBaseSetupQRPayload.encodedLength)
        XCTAssertGreaterThanOrEqual(vectors.valid.count, 5)
        XCTAssertGreaterThanOrEqual(vectors.invalid_payloads.count, 60)
    }

    func testEveryValidVectorIsReadAsItsFields() throws {
        for vector in try vectors().valid {
            let payload = try PowerBaseSetupQRPayload(parsing: vector.payload)
            XCTAssertEqual(payload.eui64.hex, vector.eui64, vector.name)
            XCTAssertEqual(payload.setupCode, vector.setup_code, vector.name)
            XCTAssertEqual(vector.setup_code_hex.count, 32, vector.name)
            XCTAssertEqual(PowerBaseSetupCode.normalized(payload.setupCode), vector.setup_code, vector.name)
        }
    }

    func testEveryInvalidVectorIsRefusedForItsReason() throws {
        var seen = Set<PowerBaseSetupQRError>()
        for vector in try vectors().invalid_payloads {
            let expected = try XCTUnwrap(Self.errorNames[vector.error], "unknown error name \(vector.error)")
            do {
                _ = try PowerBaseSetupQRPayload(parsing: vector.payload)
                XCTFail("accepted: \(vector.name)")
            } catch let error as PowerBaseSetupQRError {
                XCTAssertEqual(error, expected, vector.name)
                seen.insert(error)
            }
        }
        XCTAssertEqual(seen, Set(PowerBaseSetupQRError.allCases), "every reason has a vector")
    }

    /// With `POGO_FIRMWARE_REPO` set: this copy of the vectors is the generator's file, byte for byte.
    func testTheVectorsAreTheFirmwareRepositorysFile() throws {
        guard let repository = ProcessInfo.processInfo.environment["POGO_FIRMWARE_REPO"] else {
            throw XCTSkip("Set POGO_FIRMWARE_REPO to compare the vector file with the firmware repository's")
        }
        let theirs = URL(fileURLWithPath: repository).appendingPathComponent("tools/power_base_setup_qr_vectors.json")
        XCTAssertEqual(try Data(contentsOf: vectorsURL), try Data(contentsOf: theirs))
    }
}
#endif
