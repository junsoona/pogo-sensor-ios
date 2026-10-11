import XCTest
@testable import ESPProvisionSecurity2

/// `Security2Messages.swift` against upstream's generated protobuf code: what it writes is byte
/// for byte what SwiftProtobuf writes, it reads what SwiftProtobuf wrote, and no input makes it
/// trap. (That the real ESP-IDF server reads and answers these messages is HarnessInteropTests.)
final class Security2MessageTests: XCTestCase {
    // MARK: - Writing

    func testCommand0IsByteForByteWhatTheGeneratedCodeWrites() throws {
        var message = SessionData()
        message.secVer = .secScheme2
        message.sec2.msg = .s2SessionCommand0
        message.sec2.sc0.clientUsername = Data("6055f9fffe001234".utf8)
        message.sec2.sc0.clientPubkey = Data([0]) + GoldenVectors.pattern(383, 3)
        let bytes = try message.serializedData()
        XCTAssertEqual(bytes, GoldenVectors.command0)
        XCTAssertEqual(bytes.count, 414, "the size docs/power-base.md measured")
        // And the helper the tests use to build a Command0 with any public key.
        XCTAssertEqual(try Security2Handshake.command0(username: "6055f9fffe001234", publicKey: Data([0]) + GoldenVectors.pattern(383, 3)), GoldenVectors.command0)
    }

    func testCommand1IsByteForByteWhatTheGeneratedCodeWrites() throws {
        var message = SessionData()
        message.secVer = .secScheme2
        message.sec2.msg = .s2SessionCommand1
        message.sec2.sc1.clientProof = GoldenVectors.pattern(64, 9)
        let bytes = try message.serializedData()
        XCTAssertEqual(bytes, GoldenVectors.command1)
        XCTAssertEqual(bytes.count, 75)
    }

    func testTheResponsesAreAlsoWrittenTheSameWay() throws {
        var response0 = SessionData()
        response0.secVer = .secScheme2
        response0.sec2.msg = .s2SessionResponse0
        response0.sec2.sr0.devicePubkey = GoldenVectors.pattern(384, 5)
        response0.sec2.sr0.deviceSalt = GoldenVectors.pattern(16, 11)
        XCTAssertEqual(try response0.serializedData(), GoldenVectors.response0)
        response0.sec2.sr0.status = .UNRECOGNIZED(7)
        XCTAssertEqual(try response0.serializedData(), GoldenVectors.response0InvalidSession)

        var response1 = SessionData()
        response1.secVer = .secScheme2
        response1.sec2.msg = .s2SessionResponse1
        response1.sec2.sr1.deviceProof = GoldenVectors.pattern(64, 13)
        response1.sec2.sr1.deviceNonce = GoldenVectors.pattern(12, 17)
        XCTAssertEqual(try response1.serializedData(), GoldenVectors.response1)
    }

    func testASecurity0Or1RequestCannotBeWritten() {
        var security0 = SessionData()
        security0.secVer = .secScheme0
        security0.proto = .sec0
        XCTAssertThrowsError(try security0.serializedData())
        var security1 = SessionData()
        security1.secVer = .secScheme1
        security1.proto = .sec1
        XCTAssertThrowsError(try security1.serializedData())
    }

    // MARK: - Reading

    func testTheGeneratedCodesMessagesAreReadFieldForField() throws {
        let command0 = try SessionData(serializedData: GoldenVectors.command0)
        XCTAssertEqual(command0.secVer, .secScheme2)
        XCTAssertEqual(command0.sec2.msg, .s2SessionCommand0)
        XCTAssertEqual(command0.sec2.sc0.clientUsername, Data("6055f9fffe001234".utf8))
        XCTAssertEqual(command0.sec2.sc0.clientPubkey, Data([0]) + GoldenVectors.pattern(383, 3))
        XCTAssertEqual(command0.sec2.sc0.clientPubkey.count, 384)

        let command1 = try SessionData(serializedData: GoldenVectors.command1)
        XCTAssertEqual(command1.sec2.msg, .s2SessionCommand1)
        XCTAssertEqual(command1.sec2.sc1.clientProof, GoldenVectors.pattern(64, 9))

        let response0 = try SessionData(serializedData: GoldenVectors.response0)
        XCTAssertEqual(response0.secVer, .secScheme2)
        XCTAssertEqual(response0.sec2.msg, .s2SessionResponse0)
        guard case .sr0? = response0.sec2.payload else { return XCTFail("payload") }
        XCTAssertEqual(response0.sec2.sr0.status, .success)
        XCTAssertEqual(response0.sec2.sr0.devicePubkey, GoldenVectors.pattern(384, 5))
        XCTAssertEqual(response0.sec2.sr0.deviceSalt, GoldenVectors.pattern(16, 11))
        XCTAssertEqual(try SessionData(serializedData: GoldenVectors.response0ShortKey).sec2.sr0.devicePubkey.count, 383)
        XCTAssertEqual(try SessionData(serializedData: GoldenVectors.response0InvalidSession).sec2.sr0.status, .UNRECOGNIZED(7))

        let response1 = try SessionData(serializedData: GoldenVectors.response1)
        XCTAssertEqual(response1.sec2.msg, .s2SessionResponse1)
        guard case .sr1? = response1.sec2.payload else { return XCTFail("payload") }
        XCTAssertEqual(response1.sec2.sr1.status, .success)
        XCTAssertEqual(response1.sec2.sr1.deviceProof, GoldenVectors.pattern(64, 13))
        XCTAssertEqual(response1.sec2.sr1.deviceNonce, GoldenVectors.pattern(12, 17))
        XCTAssertEqual(try SessionData(serializedData: GoldenVectors.response1CryptoError).sec2.sr1.status, .UNRECOGNIZED(6))
    }

    func testOtherSecuritySchemesAreRecognisedAndNotRead() throws {
        let security0 = try SessionData(serializedData: GoldenVectors.security0Response)
        XCTAssertEqual(security0.secVer, .secScheme0)
        XCTAssertEqual(security0.proto, .sec0)
        let security1 = try SessionData(serializedData: GoldenVectors.security1Response0)
        XCTAssertEqual(security1.secVer, .secScheme1)
        XCTAssertEqual(security1.proto, .sec1)
        XCTAssertEqual(security1.sec2, Sec2Payload(), "no Security 2 payload is made up from it")
        XCTAssertEqual(try SessionData(serializedData: GoldenVectors.response0AnnouncedAsSecurity1).secVer, .secScheme1)
        XCTAssertEqual(try SessionData(serializedData: Data([0x10, 0x07])).secVer, .UNRECOGNIZED(7), "a scheme that does not exist yet")
    }

    func testUnknownFieldsAreSkippedAndKnownFieldsWithAnotherWireTypeAreRefused() throws {
        // Unknown field 15 of each wire type in front of the real content (proto3 forward compatibility).
        let unknown: [Data] = [
            Data([0x78, 0x05]),                                         // varint
            Data([0x79, 1, 2, 3, 4, 5, 6, 7, 8]),                       // fixed64
            Data([0x7a, 0x03, 0xaa, 0xbb, 0xcc]),                       // length-delimited
            Data([0x7d, 1, 2, 3, 4]),                                   // fixed32
        ]
        for prefix in unknown {
            let message = try SessionData(serializedData: prefix + GoldenVectors.response1)
            XCTAssertEqual(message.sec2.sr1.deviceNonce, GoldenVectors.pattern(12, 17))
        }
        // sec_ver (field 2) as a length-delimited field; sec2 (field 12) as a varint; groups.
        for bad in [Data([0x12, 0x01, 0x02]), Data([0x60, 0x01]), Data([0x7b]), Data([0x7c])] {
            XCTAssertThrowsError(try SessionData(serializedData: bad + GoldenVectors.response1), "\(Array(bad))")
        }
        XCTAssertEqual(try SessionData(serializedData: Data()), SessionData(), "an empty message is all defaults")
    }

    func testTruncatedOrOverlongInputIsRefusedWithoutTrapping() {
        for vector in [GoldenVectors.command0, GoldenVectors.response0, GoldenVectors.response1] {
            for length in 1..<vector.count {
                // Whatever a prefix is -- a valid shorter message or garbage -- reading it must not trap.
                _ = try? SessionData(serializedData: vector.prefix(length))
            }
            // Cutting inside the sec2 payload always breaks its declared length.
            XCTAssertThrowsError(try SessionData(serializedData: vector.dropLast()))
            XCTAssertThrowsError(try SessionData(serializedData: vector.dropLast(20)))
        }
        // A length that reaches past the end; a varint that never ends; one longer than 64 bits;
        // field number 0; a huge declared length.
        let bad: [[UInt8]] = [
            [0x62, 0x05, 0x08, 0x01],
            [0x62, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
            [0x10, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02],
            [0x00, 0x01],
            [0x62, 0xff, 0xff, 0xff, 0xff, 0x0f],
            [0x10],
            [0x62],
        ]
        for bytes in bad {
            XCTAssertThrowsError(try SessionData(serializedData: Data(bytes)), "\(bytes)")
        }
        XCTAssertThrowsError(try SessionData(serializedData: Data(count: 5000)), "far longer than any handshake message")
    }

    func testRandomAndMutatedInputNeverTraps() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<5000 {
            let length = Int.random(in: 0...96, using: &generator)
            let bytes = Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) })
            _ = try? SessionData(serializedData: bytes)
        }
        for vector in [GoldenVectors.response0, GoldenVectors.response1] {
            for _ in 0..<3000 {
                var mutated = vector
                for _ in 0..<Int.random(in: 1...4, using: &generator) {
                    mutated[Int.random(in: 0..<mutated.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
                }
                _ = try? SessionData(serializedData: mutated)
            }
        }
    }

    // MARK: - The handshake wrapper's checks

    func testTheHandshakeRefusesMessagesOfTheWrongShapeBeforeAnyArithmetic() throws {
        func failure(response0: Data) -> Security2Handshake.Failure? {
            let handshake = Security2Handshake(username: "6055f9fffe001234", password: "MFRGGZDFMZTWQ2LKNNWG23TPOA")
            guard (try? handshake.command0()) != nil else { return nil }
            do {
                _ = try handshake.command1(response0: response0)
                return nil
            } catch {
                return error as? Security2Handshake.Failure
            }
        }
        XCTAssertEqual(failure(response0: GoldenVectors.security1Response0), .securityVersionMismatch, "a Security 1 answer")
        XCTAssertEqual(failure(response0: GoldenVectors.security0Response), .securityVersionMismatch, "a Security 0 answer")
        XCTAssertEqual(failure(response0: GoldenVectors.response0AnnouncedAsSecurity1), .securityVersionMismatch)
        XCTAssertEqual(failure(response0: GoldenVectors.response1), .malformed("response0"), "the other step's message")
        XCTAssertEqual(failure(response0: GoldenVectors.command0), .malformed("response0"), "its own request echoed back")
        XCTAssertEqual(failure(response0: GoldenVectors.response0InvalidSession), .deviceStatus)
        XCTAssertEqual(failure(response0: Data([0xff, 0xff])), .malformed("protobuf"))
        XCTAssertEqual(failure(response0: Data()), .securityVersionMismatch, "an empty answer is not Security 2")

        var noKey = try SessionData(serializedData: GoldenVectors.response0)
        noKey.sec2.sr0.devicePubkey = Data()
        XCTAssertEqual(failure(response0: try noKey.serializedData()), .malformed("device_pubkey"))
        var longKey = noKey
        longKey.sec2.sr0.devicePubkey = Data(repeating: 1, count: 385)
        XCTAssertEqual(failure(response0: try longKey.serializedData()), .malformed("device_pubkey"))
        var noSalt = try SessionData(serializedData: GoldenVectors.response0)
        noSalt.sec2.sr0.deviceSalt = Data()
        XCTAssertEqual(failure(response0: try noSalt.serializedData()), .malformed("device_salt"))
        var zeroKey = try SessionData(serializedData: GoldenVectors.response0)
        zeroKey.sec2.sr0.devicePubkey = Data(count: 384)
        XCTAssertEqual(failure(response0: try zeroKey.serializedData()), .invalidDevicePublicKey, "B mod N == 0")

        // A well-formed Response0 is accepted, and then a Response1 of the wrong shape is not.
        func failure(response1: Data) -> Security2Handshake.Failure? {
            let handshake = Security2Handshake(username: "6055f9fffe001234", password: "MFRGGZDFMZTWQ2LKNNWG23TPOA")
            do {
                _ = try handshake.command0()
                _ = try handshake.command1(response0: GoldenVectors.response0)
                try handshake.finish(response1: response1)
                return nil
            } catch {
                return error as? Security2Handshake.Failure
            }
        }
        XCTAssertEqual(failure(response1: GoldenVectors.response0), .malformed("response1"))
        XCTAssertEqual(failure(response1: GoldenVectors.response1CryptoError), .deviceStatus)
        XCTAssertEqual(failure(response1: GoldenVectors.response1), .deviceProofMismatch, "a proof that is just a byte pattern")
        var shortProof = try SessionData(serializedData: GoldenVectors.response1)
        shortProof.sec2.sr1.deviceProof = Data(repeating: 1, count: 63)
        XCTAssertEqual(failure(response1: try shortProof.serializedData()), .malformed("device_proof"))
        var shortNonce = try SessionData(serializedData: GoldenVectors.response1)
        shortNonce.sec2.sr1.deviceNonce = Data(repeating: 1, count: 8)
        XCTAssertEqual(failure(response1: try shortNonce.serializedData()), .malformed("device_nonce"))
    }

    func testAHandshakeIsSingleUseAndNeverEncryptsBeforeItIsEstablished() throws {
        let handshake = Security2Handshake(username: "6055f9fffe001234", password: "MFRGGZDFMZTWQ2LKNNWG23TPOA")
        XCTAssertNil(handshake.encrypt(Data([1, 2, 3])), "no session, no ciphertext")
        XCTAssertNil(handshake.decrypt(Data(count: 32)))
        let command0 = try handshake.command0()
        XCTAssertEqual(Security2Handshake.clientPublicKey(inCommand0: command0)?.count, 384)
        XCTAssertThrowsError(try handshake.command0(), "not twice")
        XCTAssertThrowsError(try handshake.finish(response1: GoldenVectors.response1), "not out of order")
        XCTAssertThrowsError(try handshake.command1(response0: GoldenVectors.response1), "a wrong answer ends it")
        XCTAssertThrowsError(try handshake.command1(response0: GoldenVectors.response0), "and a right one afterwards does not revive it") {
            XCTAssertEqual($0 as? Security2Handshake.Failure, .wrongState)
        }
        XCTAssertFalse(handshake.isEstablished)
        XCTAssertNil(handshake.encrypt(Data([1, 2, 3])))
    }
}
