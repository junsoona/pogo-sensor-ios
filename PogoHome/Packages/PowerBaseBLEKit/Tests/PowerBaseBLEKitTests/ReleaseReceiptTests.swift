import XCTest
@testable import PowerBaseBLEKit

/// The release receipt: message 0x07 / 0x87 on `pb-status` (pb_ble_proto.h) and the management
/// message it carries (pb_mgmt_proto.h, `UNENROLL_DONE` with result `ERASED`).
final class ReleaseReceiptTests: XCTestCase {
    private let eui = PowerBaseBLEEUI64(hex: "6055f9fffe001234")!
    private let other = PowerBaseBLEEUI64(hex: "6055f9fffe005678")!

    /// The receipt the firmware, hub and Python tests pin: EUI-64 6055f9fffe001234, hub id 10…1f,
    /// generation 20…2f, command e0…ef, key 30…4f. The MAC was computed with Python's hmac.
    static let goldenReceiptHex =
        "01030000" + "6055f9fffe001234" + "101112131415161718191a1b1c1d1e1f" + "202122232425262728292a2b2c2d2e2f"
        + "e0e1e2e3e4e5e6e7e8e9eaebecedeeef" + "02000000" + "efd7833baf44c006d3f980b77630e2250e2d7f61328cceee83ac30a4a41fe01b"
    /// The same enrollment's "released" notice: a genuine message that is NOT a receipt.
    static let goldenNoticeHex =
        "01030000" + "6055f9fffe001234" + "101112131415161718191a1b1c1d1e1f" + "202122232425262728292a2b2c2d2e2f"
        + "e0e1e2e3e4e5e6e7e8e9eaebecedeeef" + "01000000" + "02f00a8d63fba56ff747911889aae31a29b60d053178db827a8e8730a05b7eba"

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

    /// A response as pb_ble_adm_handle_receipt() builds it.
    private func response(code: UInt8 = 0, eui64: PowerBaseBLEEUI64? = nil, version: UInt8 = 1, present: UInt8 = 1, receipt: Data? = nil) -> Data {
        var out = Data([1, 0x87, code, 0])
        out.append(code == 0 || code == 0x12 ? (eui64 ?? eui).bytes : Data(count: 8))
        out.append(contentsOf: [version, present, 0, 0])
        out.append(receipt ?? (present == 1 ? data(Self.goldenReceiptHex) : Data(count: 96)))
        return out
    }

    func testTheRequestIsTwelveBytes() {
        let request = PowerBaseBLECodec.receiptRequest(target: eui)
        XCTAssertEqual(request, data("01070000" + "6055f9fffe001234"))
        XCTAssertEqual(request.count, PowerBaseBLECodec.receiptRequestLength)
    }

    func testAReceiptIsExactlyTheErasedMessage() throws {
        let receipt = try XCTUnwrap(PowerBaseBLEReleaseReceipt(bytes: data(Self.goldenReceiptHex)))
        XCTAssertEqual(receipt.hex, Self.goldenReceiptHex, "handed to the hub byte for byte")
        XCTAssertEqual(receipt.eui64Hex, "6055f9fffe001234")
        XCTAssertEqual(receipt.hubIDHex, "101112131415161718191a1b1c1d1e1f")
        XCTAssertEqual(receipt.generationHex, "202122232425262728292a2b2c2d2e2f")
        XCTAssertEqual(PowerBaseBLEReleaseReceipt.length, 96)

        XCTAssertNil(PowerBaseBLEReleaseReceipt(bytes: data(Self.goldenNoticeHex)), "the board's 'released' notice is not a receipt")
        for (offset, why) in [(0, "version"), (1, "type"), (2, "flags"), (3, "reserved"), (60, "result"), (61, "pad"), (63, "pad")] {
            var bytes = data(Self.goldenReceiptHex)
            bytes[offset] ^= 0x04
            XCTAssertNil(PowerBaseBLEReleaseReceipt(bytes: bytes), why)
        }
        XCTAssertNil(PowerBaseBLEReleaseReceipt(bytes: data(Self.goldenReceiptHex).dropLast()))
        XCTAssertNil(PowerBaseBLEReleaseReceipt(bytes: data(Self.goldenReceiptHex) + Data([0])))
        XCTAssertNil(PowerBaseBLEReleaseReceipt(bytes: Data()))
    }

    func testTheTwoDocumentedAnswersAreRead() throws {
        let present = try PowerBaseBLECodec.decodeReceiptResponse(response(), target: eui)
        XCTAssertEqual(present?.hex, Self.goldenReceiptHex)
        XCTAssertNil(try PowerBaseBLECodec.decodeReceiptResponse(response(present: 0), target: eui), "a board without a receipt")
        XCTAssertEqual(response().count, PowerBaseBLECodec.receiptResponseLength)
    }

    func testAnythingElseIsNotAnAnswer() {
        func refused(_ response: Data, _ expected: PowerBaseBLECodecError, _ why: String, line: UInt = #line) {
            XCTAssertThrowsError(try PowerBaseBLECodec.decodeReceiptResponse(response, target: eui), why, line: line) {
                XCTAssertEqual($0 as? PowerBaseBLECodecError, expected, why, line: line)
            }
        }
        refused(response().dropLast(), .length(111), "one byte short")
        refused(response() + Data([0]), .length(113), "one byte long")
        var bad = response()
        bad[0] = 2
        refused(bad, .version(2), "another protocol version")
        bad = response()
        bad[1] = 0x81
        refused(bad, .type(0x81), "a pb-status response where the receipt response belongs")
        for offset in [3, 14, 15] {
            bad = response()
            bad[offset] = 1
            refused(bad, .reserved, "reserved byte \(offset)")
        }
        refused(response(code: 0x12, eui64: eui, present: 0), .refused(.wrongTarget), "WRONG_TARGET")
        refused(response(code: 0x11, present: 0), .refused(.malformed), "MALFORMED")
        refused(response(code: 0x10, present: 0), .refused(.unsupportedVersion), "UNSUPPORTED_VERSION")
        refused(response(code: 0x16, present: 0), .code(0x16), "a code this message never answers with")
        refused(response(code: 0x7f, present: 0), .code(0x7f), "a code that does not exist")
        refused(response(version: 2), .field("receipt version"), "another receipt format")
        refused(response(eui64: other), .field("eui64"), "the answer of another board")
        refused(response(present: 2), .field("receipt present"), "a 'present' value outside the protocol")
        refused(response(present: 0, receipt: data(Self.goldenReceiptHex)), .field("receipt"), "'none' with bytes behind it")
        refused(response(present: 1, receipt: Data(count: 96)), .field("receipt"), "'present' with zeros")
        refused(response(present: 1, receipt: data(Self.goldenNoticeHex)), .field("receipt"), "'present' with the released notice")
        var foreign = data(Self.goldenReceiptHex)
        foreign[11] ^= 0x01
        refused(response(present: 1, receipt: foreign), .field("receipt"), "a receipt that names another board than the one that answered")
        // What a board without the capability answers on pb-status: 40 bytes, MALFORMED.
        refused(Data([1, 0x81, 0x11, 0]) + Data(count: 36), .length(40), "firmware before the capability")
    }

    func testTheCapabilityIsItsOwnName() throws {
        func capabilities(_ cap: String) throws -> PowerBaseBLECapabilities {
            try PowerBaseBLEVersion.validate(Data((#"{"prov":{"ver":"v1.1","sec_ver":2,"sec_patch_ver":1,"cap":[]},"pb_enroll":{"proto":1,"cap":["# + cap + "]}}").utf8))
        }
        XCTAssertEqual(try capabilities(#""bridge_endpoint_v1","mgmt_v1","release_receipt_v1""#), [.bridgeEndpointV1, .managementV1, .releaseReceiptV1],
                       "exactly what pb_ble_service.h answers now")
        XCTAssertEqual(try capabilities(#""release_receipt_v1""#), [.releaseReceiptV1])
        XCTAssertEqual(try capabilities(#""bridge_endpoint_v1","mgmt_v1""#), [.bridgeEndpointV1, .managementV1], "firmware before the receipt")
        XCTAssertEqual(try capabilities(#""release_receipt_v2","RELEASE_RECEIPT_V1","receipt""#), [], "the name is exact")
    }

    func testABoardWithoutTheCapabilityIsNeverAsked() async throws {
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
        func version(_ cap: String) -> String { #"{"prov":{"ver":"v1.1","sec_ver":2,"sec_patch_ver":1,"cap":[]},"pb_enroll":{"proto":1,"cap":["# + cap + "]}}" }
        let old = VersionOnlyLink(version: version(#""bridge_endpoint_v1","mgmt_v1""#))
        let client = PowerBaseBLEBoardClient(link: old)
        try await client.checkVersion()
        do {
            _ = try await client.releaseReceipt(target: eui)
            XCTFail("nothing may be sent")
        } catch {
            XCTAssertEqual(error as? PowerBaseBLEClientError, .invalidInput("capability"))
        }
        XCTAssertEqual(old.endpoints, [.version], "nothing was written to pb-status")

        let capable = VersionOnlyLink(version: version(#""bridge_endpoint_v1","mgmt_v1","release_receipt_v1""#))
        let asking = PowerBaseBLEBoardClient(link: capable)
        try await asking.checkVersion()
        do {
            _ = try await asking.releaseReceipt(target: eui)
            XCTFail("no session exists")
        } catch {
            XCTAssertEqual(error as? PowerBaseBLEClientError, .noSession, "with the capability it is attempted (and needs the Security 2 session)")
        }
    }
}
