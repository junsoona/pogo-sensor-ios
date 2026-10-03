#if DEBUG
// PogoHome addition -- not part of ESPProvision. It stands in for upstream's generated protobuf
// code (Proto/session.pb.swift, sec2.pb.swift, constants.pb.swift and the SwiftProtobuf runtime
// they need), for exactly the four Security 2 handshake messages, with the same type and property
// names so that the vendored ESPSecurity2.swift compiles against it unchanged.
//
// Why: SwiftProtobuf would be linked into every build of the app, Release included (about 2 MB of
// code nothing uses), and Xcode cannot leave a package out of one configuration. See VENDORED.md.
//
// The definitions are ESP-IDF v6.1 components/protocomm/proto/session.proto, sec2.proto and
// constants.proto (proto3). This is message framing only: no key, proof or nonce is computed here.
// The encoder's output is compared byte for byte with what upstream's generated code produces
// (Security2MessageTests), and the decoder reads what the real ESP-IDF server sends
// (HarnessInteropTests).
//
// It cannot build a Security 0 or Security 1 request: those payloads are recognised when received
// (to refuse them) and have no encoder.
import Foundation

enum Security2MessageError: Error, Equatable {
    case malformed
}

/// `SecSchemeVersion` (session.proto).
enum SecSchemeVersion: Equatable {
    case secScheme0
    case secScheme1
    case secScheme2
    case UNRECOGNIZED(Int)

    init(rawValue: Int) {
        switch rawValue {
        case 0: self = .secScheme0
        case 1: self = .secScheme1
        case 2: self = .secScheme2
        default: self = .UNRECOGNIZED(rawValue)
        }
    }

    var rawValue: Int {
        switch self {
        case .secScheme0: return 0
        case .secScheme1: return 1
        case .secScheme2: return 2
        case let .UNRECOGNIZED(value): return value
        }
    }
}

/// `Sec2MsgType` (sec2.proto).
enum Sec2MsgType: Equatable {
    case s2SessionCommand0
    case s2SessionResponse0
    case s2SessionCommand1
    case s2SessionResponse1
    case UNRECOGNIZED(Int)

    init(rawValue: Int) {
        switch rawValue {
        case 0: self = .s2SessionCommand0
        case 1: self = .s2SessionResponse0
        case 2: self = .s2SessionCommand1
        case 3: self = .s2SessionResponse1
        default: self = .UNRECOGNIZED(rawValue)
        }
    }

    var rawValue: Int {
        switch self {
        case .s2SessionCommand0: return 0
        case .s2SessionResponse0: return 1
        case .s2SessionCommand1: return 2
        case .s2SessionResponse1: return 3
        case let .UNRECOGNIZED(value): return value
        }
    }
}

/// `Status` (constants.proto). Only `success` is ever accepted.
enum Status: Equatable {
    case success
    case UNRECOGNIZED(Int)

    init(rawValue: Int) {
        self = rawValue == 0 ? .success : .UNRECOGNIZED(rawValue)
    }

    var rawValue: Int {
        switch self {
        case .success: return 0
        case let .UNRECOGNIZED(value): return value
        }
    }
}

/// `S2SessionCmd0`: `bytes client_username = 1; bytes client_pubkey = 2;`
struct S2SessionCmd0: Equatable {
    var clientUsername = Data()
    var clientPubkey = Data()
}

/// `S2SessionResp0`: `Status status = 1; bytes device_pubkey = 2; bytes device_salt = 3;`
struct S2SessionResp0: Equatable {
    var status = Status.success
    var devicePubkey = Data()
    var deviceSalt = Data()
}

/// `S2SessionCmd1`: `bytes client_proof = 1;`
struct S2SessionCmd1: Equatable {
    var clientProof = Data()
}

/// `S2SessionResp1`: `Status status = 1; bytes device_proof = 2; bytes device_nonce = 3;`
struct S2SessionResp1: Equatable {
    var status = Status.success
    var deviceProof = Data()
    var deviceNonce = Data()
}

/// `Sec2Payload`: `Sec2MsgType msg = 1; oneof payload { sc0 = 20; sr0 = 21; sc1 = 22; sr1 = 23; }`
struct Sec2Payload: Equatable {
    enum OneOf_Payload: Equatable {
        case sc0(S2SessionCmd0)
        case sr0(S2SessionResp0)
        case sc1(S2SessionCmd1)
        case sr1(S2SessionResp1)
    }

    var msg = Sec2MsgType.s2SessionCommand0
    var payload: OneOf_Payload?

    var sc0: S2SessionCmd0 {
        get { if case let .sc0(value)? = payload { return value } else { return S2SessionCmd0() } }
        set { payload = .sc0(newValue) }
    }

    var sr0: S2SessionResp0 {
        get { if case let .sr0(value)? = payload { return value } else { return S2SessionResp0() } }
        set { payload = .sr0(newValue) }
    }

    var sc1: S2SessionCmd1 {
        get { if case let .sc1(value)? = payload { return value } else { return S2SessionCmd1() } }
        set { payload = .sc1(newValue) }
    }

    var sr1: S2SessionResp1 {
        get { if case let .sr1(value)? = payload { return value } else { return S2SessionResp1() } }
        set { payload = .sr1(newValue) }
    }
}

/// `SessionData`: `SecSchemeVersion sec_ver = 2; oneof proto { sec0 = 10; sec1 = 11; sec2 = 12; }`
struct SessionData: Equatable {
    enum OneOf_Proto: Equatable {
        /// A Security 0 payload was present. Its content is not read.
        case sec0
        /// A Security 1 payload was present. Its content is not read.
        case sec1
        case sec2(Sec2Payload)
    }

    var secVer = SecSchemeVersion.secScheme0
    var proto: OneOf_Proto?

    var sec2: Sec2Payload {
        get { if case let .sec2(value)? = proto { return value } else { return Sec2Payload() } }
        set { proto = .sec2(newValue) }
    }

    init() {}

    /// Reads a serialized `SessionData`. Unknown fields are skipped, as proto3 asks; anything that
    /// is not well-formed protobuf, or a known field with another wire type, throws.
    init(serializedData data: Data) throws {
        // A handshake message is one characteristic value: at most 512 bytes.
        guard data.count <= 4096 else { throw Security2MessageError.malformed }
        var reader = Security2WireReader(data)
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (2, .varint):
                secVer = SecSchemeVersion(rawValue: try reader.enumValue())
            case (10, .lengthDelimited):
                _ = try reader.lengthDelimited()
                proto = .sec0
            case (11, .lengthDelimited):
                _ = try reader.lengthDelimited()
                proto = .sec1
            case (12, .lengthDelimited):
                proto = .sec2(try Sec2Payload(serialized: try reader.lengthDelimited()))
            case (2, _), (10, _), (11, _), (12, _):
                throw Security2MessageError.malformed
            default:
                try reader.skip(field.wireType)
            }
        }
    }

    /// proto3: fields in number order, default values left out.
    func serializedData() throws -> Data {
        var writer = Security2WireWriter()
        if secVer.rawValue != 0 { writer.enumField(2, secVer.rawValue) }
        switch proto {
        case let .sec2(payload)?:
            writer.bytesField(12, payload.serialized())
        case .sec0?, .sec1?:
            // Never sent by this client.
            throw Security2MessageError.malformed
        case nil:
            break
        }
        return writer.data
    }
}

extension Sec2Payload {
    fileprivate init(serialized data: Data) throws {
        var reader = Security2WireReader(data)
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .varint):
                msg = Sec2MsgType(rawValue: try reader.enumValue())
            case (20, .lengthDelimited):
                payload = .sc0(try S2SessionCmd0(serialized: try reader.lengthDelimited()))
            case (21, .lengthDelimited):
                payload = .sr0(try S2SessionResp0(serialized: try reader.lengthDelimited()))
            case (22, .lengthDelimited):
                payload = .sc1(try S2SessionCmd1(serialized: try reader.lengthDelimited()))
            case (23, .lengthDelimited):
                payload = .sr1(try S2SessionResp1(serialized: try reader.lengthDelimited()))
            case (1, _), (20, _), (21, _), (22, _), (23, _):
                throw Security2MessageError.malformed
            default:
                try reader.skip(field.wireType)
            }
        }
    }

    fileprivate func serialized() -> Data {
        var writer = Security2WireWriter()
        if msg.rawValue != 0 { writer.enumField(1, msg.rawValue) }
        switch payload {
        case let .sc0(command)?:
            var inner = Security2WireWriter()
            if !command.clientUsername.isEmpty { inner.bytesField(1, command.clientUsername) }
            if !command.clientPubkey.isEmpty { inner.bytesField(2, command.clientPubkey) }
            writer.bytesField(20, inner.data)
        case let .sr0(response)?:
            var inner = Security2WireWriter()
            if response.status.rawValue != 0 { inner.enumField(1, response.status.rawValue) }
            if !response.devicePubkey.isEmpty { inner.bytesField(2, response.devicePubkey) }
            if !response.deviceSalt.isEmpty { inner.bytesField(3, response.deviceSalt) }
            writer.bytesField(21, inner.data)
        case let .sc1(command)?:
            var inner = Security2WireWriter()
            if !command.clientProof.isEmpty { inner.bytesField(1, command.clientProof) }
            writer.bytesField(22, inner.data)
        case let .sr1(response)?:
            var inner = Security2WireWriter()
            if response.status.rawValue != 0 { inner.enumField(1, response.status.rawValue) }
            if !response.deviceProof.isEmpty { inner.bytesField(2, response.deviceProof) }
            if !response.deviceNonce.isEmpty { inner.bytesField(3, response.deviceNonce) }
            writer.bytesField(23, inner.data)
        case nil:
            break
        }
        return writer.data
    }
}

extension S2SessionCmd0 {
    fileprivate init(serialized data: Data) throws {
        var reader = Security2WireReader(data)
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .lengthDelimited): clientUsername = try reader.lengthDelimited()
            case (2, .lengthDelimited): clientPubkey = try reader.lengthDelimited()
            case (1, _), (2, _): throw Security2MessageError.malformed
            default: try reader.skip(field.wireType)
            }
        }
    }
}

extension S2SessionResp0 {
    fileprivate init(serialized data: Data) throws {
        var reader = Security2WireReader(data)
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .varint): status = Status(rawValue: try reader.enumValue())
            case (2, .lengthDelimited): devicePubkey = try reader.lengthDelimited()
            case (3, .lengthDelimited): deviceSalt = try reader.lengthDelimited()
            case (1, _), (2, _), (3, _): throw Security2MessageError.malformed
            default: try reader.skip(field.wireType)
            }
        }
    }
}

extension S2SessionCmd1 {
    fileprivate init(serialized data: Data) throws {
        var reader = Security2WireReader(data)
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .lengthDelimited): clientProof = try reader.lengthDelimited()
            case (1, _): throw Security2MessageError.malformed
            default: try reader.skip(field.wireType)
            }
        }
    }
}

extension S2SessionResp1 {
    fileprivate init(serialized data: Data) throws {
        var reader = Security2WireReader(data)
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .varint): status = Status(rawValue: try reader.enumValue())
            case (2, .lengthDelimited): deviceProof = try reader.lengthDelimited()
            case (3, .lengthDelimited): deviceNonce = try reader.lengthDelimited()
            case (1, _), (2, _), (3, _): throw Security2MessageError.malformed
            default: try reader.skip(field.wireType)
            }
        }
    }
}

// MARK: - Protobuf wire format (the part of it these messages use)

enum Security2WireType: Equatable {
    case varint
    case fixed64
    case lengthDelimited
    case fixed32
}

/// Reads protobuf fields from a byte buffer. Every read is bounds-checked and throws; nothing here
/// can trap on input from the device.
struct Security2WireReader {
    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    /// The next field's number and wire type; `nil` at the end of the buffer.
    mutating func nextField() throws -> (number: Int, wireType: Security2WireType)? {
        guard index < bytes.count else { return nil }
        let key = try varint()
        let number = key >> 3
        guard number >= 1, number <= 536_870_911 else { throw Security2MessageError.malformed }
        let wireType: Security2WireType
        switch key & 7 {
        case 0: wireType = .varint
        case 1: wireType = .fixed64
        case 2: wireType = .lengthDelimited
        case 5: wireType = .fixed32
        default: throw Security2MessageError.malformed   // groups (3, 4) and the unused 6, 7
        }
        return (Int(number), wireType)
    }

    /// At most ten bytes; the tenth may only carry the top bit of a 64-bit value.
    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        for position in 0..<10 {
            guard index < bytes.count else { throw Security2MessageError.malformed }
            let byte = bytes[index]
            index += 1
            if position == 9, byte > 1 { throw Security2MessageError.malformed }
            result |= UInt64(byte & 0x7f) << UInt64(position * 7)
            if byte & 0x80 == 0 { return result }
        }
        throw Security2MessageError.malformed
    }

    /// An enum value: a varint read as a 32-bit integer, as protobuf does.
    mutating func enumValue() throws -> Int {
        Int(Int32(truncatingIfNeeded: try varint()))
    }

    mutating func lengthDelimited() throws -> Data {
        let length = try varint()
        guard length <= UInt64(bytes.count - index) else { throw Security2MessageError.malformed }
        let end = index + Int(length)
        defer { index = end }
        return Data(bytes[index..<end])
    }

    mutating func skip(_ wireType: Security2WireType) throws {
        switch wireType {
        case .varint:
            _ = try varint()
        case .lengthDelimited:
            _ = try lengthDelimited()
        case .fixed64:
            guard bytes.count - index >= 8 else { throw Security2MessageError.malformed }
            index += 8
        case .fixed32:
            guard bytes.count - index >= 4 else { throw Security2MessageError.malformed }
            index += 4
        }
    }
}

struct Security2WireWriter {
    private(set) var data = Data()

    private mutating func varint(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            data.append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
    }

    /// An enum value: a varint of the value sign-extended to 64 bits, as protobuf writes it.
    mutating func enumField(_ number: Int, _ value: Int) {
        varint(UInt64(number) << 3)
        varint(UInt64(bitPattern: Int64(value)))
    }

    mutating func bytesField(_ number: Int, _ bytes: Data) {
        varint(UInt64(number) << 3 | 2)
        varint(UInt64(bytes.count))
        data.append(bytes)
    }
}
#endif
