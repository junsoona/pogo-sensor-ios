#if DEBUG
import Foundation
import Security

// The Power Base BLE enrollment wire protocol, version 1. Normative: the firmware repository's
// components/power_base_ble_enroll/include/power_base_ble_enroll/pb_ble_proto.h and
// docs/power-base.md "BLE 등록 전달 경로". Every value below is copied from there; nothing is
// guessed. Every multi-byte integer is big-endian.
//
// Two start messages exist on `pb-start`: the first one (0x02, PSKd only) and the one that also
// carries the Linux bridge endpoint (0x04, capability `bridge_endpoint_v1`). The first keeps its
// bytes; the app's test sends the second and only to a board that lists the capability.

public enum PowerBaseBLEProtocol {
    public static let version: UInt8 = 1

    /// The GATT service a board waiting for enrollment advertises.
    public static let serviceUUID = "2E8A0000-9FFB-4868-BC63-064A14069755"
    /// `POGO-PB-` + the EUI-64 as 16 upper-case hex digits. A hint for a scan list, proving nothing.
    public static let advertisedNamePrefix = "POGO-PB-"
    /// protocomm_nimble refuses a characteristic value longer than this (`BLE_ATT_ATTR_MAX_LEN`).
    public static let maximumAttributeLength = 512

    /// A protocomm endpoint: found through the 0x2901 User Description of its characteristic.
    public enum Endpoint: String, CaseIterable, Sendable {
        case session = "prov-session"
        case version = "proto-ver"
        case status = "pb-status"
        case start = "pb-start"
        case cancel = "pb-cancel"

        var shortID: UInt16 {
            switch self {
            case .session: return 0xFF51
            case .version: return 0xFF53
            case .status: return 0xFF60
            case .start: return 0xFF61
            case .cancel: return 0xFF62
            }
        }

        /// `2e8aXXXX-9ffb-4868-bc63-064a14069755`, upper case as CoreBluetooth prints it.
        public var characteristicUUID: String {
            String(format: "2E8A%04X-9FFB-4868-BC63-064A14069755", shortID)
        }
    }

    /// The EUI-64 in an advertised name, or `nil` when the name isn't `POGO-PB-<16 hex digits>`
    /// (the prefix in any letter case).
    public static func advertisedEUI64(inName name: String) -> PowerBaseBLEEUI64? {
        guard name.count == advertisedNamePrefix.count + 16,
              name.prefix(advertisedNamePrefix.count).uppercased() == advertisedNamePrefix else { return nil }
        return PowerBaseBLEEUI64(hex: String(name.dropFirst(advertisedNamePrefix.count)))
    }
}

/// A board's EUI-64: 8 bytes, not all zero.
public struct PowerBaseBLEEUI64: Hashable, Sendable {
    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count == 8, bytes.contains(where: { $0 != 0 }) else { return nil }
        self.bytes = Data(bytes)
    }

    /// Exactly 16 ASCII hex digits, either case.
    public init?(hex: String) {
        let scalars = Array(hex.unicodeScalars)
        guard scalars.count == 16 else { return nil }
        var bytes = Data(capacity: 8)
        for index in stride(from: 0, to: 16, by: 2) {
            guard let high = Self.nibble(scalars[index]), let low = Self.nibble(scalars[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
        }
        self.init(bytes: bytes)
    }

    /// 16 lower-case hex digits: the Security 2 user name and the hub's form.
    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }

    private static func nibble(_ scalar: Unicode.Scalar) -> UInt8? {
        switch scalar {
        case "0"..."9": return UInt8(scalar.value - 48)
        case "a"..."f": return UInt8(scalar.value - 87)
        case "A"..."F": return UInt8(scalar.value - 55)
        default: return nil
        }
    }
}

/// The client's name for one `pb-start`: 16 bytes from the system's secure random generator,
/// never all zero.
public struct PowerBaseBLERequestID: Hashable, Sendable {
    public static let length = 16
    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count == Self.length, bytes.contains(where: { $0 != 0 }) else { return nil }
        self.bytes = Data(bytes)
    }

    /// A new id, or `nil` when there is no secure randomness (then nothing may be sent).
    public static func random(_ randomBytes: (Int) -> [UInt8]? = PowerBaseBLERandom.system) -> PowerBaseBLERequestID? {
        guard let bytes = randomBytes(length), bytes.count == length else { return nil }
        return PowerBaseBLERequestID(bytes: Data(bytes))
    }
}

public enum PowerBaseBLERandom {
    /// `SecRandomCopyBytes`.
    public static func system(_ count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return status == errSecSuccess ? bytes : nil
    }
}

/// A challenge `pb-status` issued: valid for `lifetimeSeconds` in the Security 2 session it came
/// from, and used up by the first `pb-start` that carries a new request id.
public struct PowerBaseBLEChallenge: Equatable, Sendable {
    public static let length = 16
    public let bytes: Data
    public let lifetimeSeconds: Int

    public init?(bytes: Data, lifetimeSeconds: Int) {
        guard bytes.count == Self.length, bytes.contains(where: { $0 != 0 }), lifetimeSeconds > 0 else { return nil }
        self.bytes = Data(bytes)
        self.lifetimeSeconds = lifetimeSeconds
    }
}

/// Where a board must send its bridge traffic: the hub's OTBR Mesh-Local EID and the Linux bridge's
/// CoAP ingest port, as the hub's enrollment session reported them. Carried by `pb-start` message
/// 0x04 (pb_ble_proto.h `PB_BLE_MSG_START_EP_REQ`, capability `bridge_endpoint_v1`).
///
/// Only ever built from a value that passed every check below -- the same ones the firmware's
/// `pb_enroll_bridge_endpoint_check()` and the hub's `ParseMeshLocalEid()` apply -- so nothing
/// else can be encoded into a request. It is not a secret.
public struct PowerBaseBLEBridgeEndpoint: Hashable, Sendable {
    /// Byte [44] of the request: the endpoint format this type is.
    public static let formatVersion: UInt8 = 1
    public static let addressLength = 16

    public enum Rejection: Error, Equatable, Sendable {
        /// Not an IPv6 literal of `0-9 a-f :`: an IPv4 address, a dotted tail, a zone id, brackets,
        /// a port, a URL, a host name, upper case, whitespace, or a malformed literal.
        case notAnIPv6Literal
        case unspecified
        case loopback
        /// `::ffff:a.b.c.d` (mapped) or `::a.b.c.d` (compatible).
        case ipv4Embedded
        case multicast
        case linkLocal
        /// Not inside fd00::/8, where Thread Mesh-Local Prefixes live.
        case notMeshLocal
        /// Interface id `0000:00ff:fe00:xxxx`: a Thread RLOC or ALOC, not the EID.
        case locator
        /// Not 1…65535.
        case port
    }

    /// 16 bytes, network byte order.
    public let address: Data
    public let port: UInt16

    public init(addressBytes: Data, port: Int) throws {
        guard addressBytes.count == Self.addressLength else { throw Rejection.notAnIPv6Literal }
        let a = [UInt8](addressBytes)
        if a[0..<10].allSatisfy({ $0 == 0 }) {
            if a[10...].allSatisfy({ $0 == 0 }) { throw Rejection.unspecified }
            if a[10..<15].allSatisfy({ $0 == 0 }), a[15] == 1 { throw Rejection.loopback }
            if (a[10] == 0xff && a[11] == 0xff) || (a[10] == 0 && a[11] == 0) { throw Rejection.ipv4Embedded }
        }
        if a[0] == 0xff { throw Rejection.multicast }
        if a[0] == 0xfe, a[1] & 0xc0 == 0x80 { throw Rejection.linkLocal }
        guard a[0] == 0xfd else { throw Rejection.notMeshLocal }
        if a[8] == 0, a[9] == 0, a[10] == 0, a[11] == 0xff, a[12] == 0xfe, a[13] == 0 { throw Rejection.locator }
        guard (1...65535).contains(port) else { throw Rejection.port }
        self.address = Data(a)
        self.port = UInt16(port)
    }

    /// From the hub's JSON: `address` an IPv6 literal exactly as the hub prints it, `port` a number.
    public init(address text: String, port: Int) throws {
        guard let bytes = Self.parseIPv6Literal(text) else { throw Rejection.notAnIPv6Literal }
        try self.init(addressBytes: bytes, port: port)
    }

    /// The address as eight groups of lower-case hex, without compression -- for a developer-facing
    /// display only.
    public var addressText: String {
        stride(from: 0, to: Self.addressLength, by: 2)
            .map { String(UInt16(address[address.startIndex + $0]) << 8 | UInt16(address[address.startIndex + $0 + 1]), radix: 16) }
            .joined(separator: ":")
    }

    /// The first 8 bytes: the Mesh-Local Prefix the address lies in.
    public var meshLocalPrefix: Data { address.prefix(8) }

    /// A strict IPv6 literal reader: `0-9 a-f :` only, at most 39 characters, groups of one to
    /// four digits, at most one `::`. No zone id, no dotted IPv4 tail, no brackets, no upper case,
    /// no surrounding whitespace -- so no URL, host name or IPv4 address gets through either.
    static func parseIPv6Literal(_ text: String) -> Data? {
        let scalars = Array(text.unicodeScalars)
        guard (2...39).contains(scalars.count) else { return nil }
        for scalar in scalars {
            switch scalar {
            case "0"..."9", "a"..."f", ":": continue
            default: return nil
            }
        }
        let halves = text.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        func groups(_ part: String) -> [UInt16]? {
            if part.isEmpty { return [] }
            var out: [UInt16] = []
            for piece in part.components(separatedBy: ":") {
                guard (1...4).contains(piece.count), let value = UInt16(piece, radix: 16) else { return nil }
                out.append(value)
            }
            return out
        }
        guard let head = groups(halves[0]) else { return nil }
        var all: [UInt16]
        if halves.count == 2 {
            guard let tail = groups(halves[1]), head.count + tail.count <= 7 else { return nil }
            all = head + [UInt16](repeating: 0, count: 8 - head.count - tail.count) + tail
        } else {
            guard head.count == 8 else { return nil }
            all = head
        }
        var bytes = Data(capacity: 16)
        for group in all {
            bytes.append(UInt8(group >> 8))
            bytes.append(UInt8(group & 0xff))
        }
        return bytes
    }
}

/// What a board says it can do beyond the first version 1 messages: `pb_enroll.cap` in
/// `proto-ver`. Read before authentication, so it only decides which message this client sends --
/// a board that does not list a capability is never sent the message that needs it.
public struct PowerBaseBLECapabilities: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// `"bridge_endpoint_v1"`: the board takes `pb-start` with the bridge endpoint (message 0x04).
    public static let bridgeEndpointV1 = PowerBaseBLECapabilities(rawValue: 0x01)

    static let bridgeEndpointV1Name = "bridge_endpoint_v1"
}

/// `pb_ble_code_t`. 0x00…0x0f mean the request was honoured.
public enum PowerBaseBLECode: UInt8, Equatable, Sendable, CaseIterable {
    case ok = 0x00
    /// `pb-start` admitted and queued. Not a Joiner result, not enrollment.
    case accepted = 0x01
    /// `pb-start`: this exact request was already accepted; nothing new started.
    case duplicate = 0x02
    case unsupportedVersion = 0x10
    case malformed = 0x11
    case wrongTarget = 0x12
    case challengeInvalid = 0x13
    case challengeExpired = 0x14
    case invalidPSKd = 0x15
    case busy = 0x16
    case requestConflict = 0x17
    case notWaiting = 0x18
    case noSuchAttempt = 0x19
    case closed = 0x1a
    case unavailable = 0x1b
    case internalError = 0x1c
    /// `pb-start` with the bridge endpoint only: unknown endpoint format, port 0, or an address
    /// that is not a Thread Mesh-Local EID. Nothing started.
    case invalidEndpoint = 0x1d

    /// The name in pb_ble_proto.h, for a developer-facing display.
    public var name: String {
        switch self {
        case .ok: return "OK"
        case .accepted: return "ACCEPTED"
        case .duplicate: return "DUPLICATE"
        case .unsupportedVersion: return "UNSUPPORTED_VERSION"
        case .malformed: return "MALFORMED"
        case .wrongTarget: return "WRONG_TARGET"
        case .challengeInvalid: return "CHALLENGE_INVALID"
        case .challengeExpired: return "CHALLENGE_EXPIRED"
        case .invalidPSKd: return "INVALID_PSKD"
        case .busy: return "BUSY"
        case .requestConflict: return "REQUEST_CONFLICT"
        case .notWaiting: return "NOT_WAITING"
        case .noSuchAttempt: return "NO_SUCH_ATTEMPT"
        case .closed: return "CLOSED"
        case .unavailable: return "UNAVAILABLE"
        case .internalError: return "INTERNAL"
        case .invalidEndpoint: return "INVALID_ENDPOINT"
        }
    }
}

/// `pb_enroll_state_t`: what the board's enrollment controller is doing. None of these is the
/// hub's `heartbeat_received`.
public enum PowerBaseBLEEnrollState: UInt8, Equatable, Sendable {
    case waiting = 0
    case joining = 1
    case attaching = 2
    case enrolled = 3
}

/// `pb_ble_phase_t`: the one BLE-started attempt the board remembers, as seen by its request id.
public enum PowerBaseBLEAttemptPhase: UInt8, Equatable, Sendable {
    case none = 0
    case queued = 1
    case running = 2
    case failed = 3
    case enrolled = 4
    case cancelled = 5
}

/// `pb_enroll_result_t` (0…18), or for a request's own result also 0x80/0x81.
public enum PowerBaseBLEResult {
    public static let maximumEnrollResult: UInt8 = 18
    public static let startRefused: UInt8 = 0x80
    public static let superseded: UInt8 = 0x81

    static let names = [
        "none", "marker_corrupt", "marker_foreign", "marker_read_error", "dataset_missing", "dataset_mismatch",
        "marker_clear_failed", "joiner_start_failed", "joiner_security", "joiner_not_found", "joiner_timeout",
        "joiner_failed", "joiner_guard_expired", "cancelled", "thread_start_failed", "attach_timeout",
        "marker_write_failed", "enrolled", "resumed",
    ]

    /// The documented name of a result value this codec accepted.
    public static func name(_ value: UInt8) -> String {
        switch value {
        case startRefused: return "start_refused"
        case superseded: return "superseded"
        default: return Int(value) < names.count ? names[Int(value)] : "0x" + String(value, radix: 16)
        }
    }
}

/// A `pb-status` answer the board gave with code `OK`, `CLOSED` or `INTERNAL` -- the ones that
/// carry the board's state. Only ever built from a response that passed every check.
public struct PowerBaseBLEStatus: Equatable, Sendable {
    public struct Flags: OptionSet, Equatable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        /// A BLE-started attempt is queued or running (whoever started it).
        public static let attemptActive = Flags(rawValue: 0x01)
        /// The asked request id is that attempt, current or last.
        public static let requestMatch = Flags(rawValue: 0x02)
        public static let challengeIssued = Flags(rawValue: 0x04)
        /// This board cannot run a Joiner.
        public static let joinerUnavailable = Flags(rawValue: 0x08)
        static let known: UInt8 = 0x0f
    }

    public var code: PowerBaseBLECode
    /// The board's real EUI-64 -- authenticated, unlike the advertised name.
    public var eui64: PowerBaseBLEEUI64
    public var state: PowerBaseBLEEnrollState
    public var lastResult: UInt8
    public var flags: Flags
    /// `.none` unless `flags` has `.requestMatch`.
    public var requestPhase: PowerBaseBLEAttemptPhase
    public var requestResult: UInt8
    public var attempt: UInt32
    /// Present exactly when `flags` has `.challengeIssued`.
    public var challenge: PowerBaseBLEChallenge?

    public init(
        code: PowerBaseBLECode = .ok, eui64: PowerBaseBLEEUI64, state: PowerBaseBLEEnrollState = .waiting, lastResult: UInt8 = 0,
        flags: Flags = [], requestPhase: PowerBaseBLEAttemptPhase = .none, requestResult: UInt8 = 0, attempt: UInt32 = 0,
        challenge: PowerBaseBLEChallenge? = nil
    ) {
        self.code = code
        self.eui64 = eui64
        self.state = state
        self.lastResult = lastResult
        self.flags = flags
        self.requestPhase = requestPhase
        self.requestResult = requestResult
        self.attempt = attempt
        self.challenge = challenge
    }
}

public enum PowerBaseBLECodecError: Error, Equatable, Sendable {
    case length(Int)
    case version(UInt8)
    case type(UInt8)
    case reserved
    /// A code this protocol version doesn't define, or one this endpoint never answers with.
    case code(UInt8)
    /// A field outside its documented range, or fields that contradict each other.
    case field(String)
    /// A well-formed `pb-status` refusal (`MALFORMED` or `UNSUPPORTED_VERSION`). It carries no
    /// state: nothing else in that response is read.
    case refused(PowerBaseBLECode)
}

/// Builds the three requests and reads the two kinds of response. A response that fails any check
/// throws; no field of it is used.
public enum PowerBaseBLECodec {
    static let statusRequestType: UInt8 = 0x01
    static let startRequestType: UInt8 = 0x02
    static let cancelRequestType: UInt8 = 0x03
    /// `pb-start` with the bridge endpoint: a message of its own on the same endpoint.
    static let startWithEndpointRequestType: UInt8 = 0x04
    static let statusResponseType: UInt8 = 0x81
    static let startResponseType: UInt8 = 0x82
    static let cancelResponseType: UInt8 = 0x83
    static let startWithEndpointResponseType: UInt8 = 0x84

    public static let statusRequestLength = 20
    public static let statusResponseLength = 40
    public static let startRequestFixedLength = 44
    public static let startWithEndpointRequestFixedLength = 64
    public static let cancelRequestLength = 28
    public static let shortResponseLength = 4

    static let statusIssueChallenge: UInt8 = 0x01

    /// The Thread PSKd alphabet: `0-9 A-Z` without `I O Q Z`.
    static let pskdAlphabet = Set("0123456789ABCDEFGHJKLMNPRSTUVWXY".utf8)

    public static func isValidPSKd(_ pskd: String) -> Bool {
        let bytes = Array(pskd.utf8)
        return (6...32).contains(bytes.count) && bytes.allSatisfy(pskdAlphabet.contains)
    }

    // MARK: Requests

    /// `[0]` version `[1]` 0x01 `[2]` flags `[3]` 0 `[4..19]` request id to ask about (zero: none).
    public static func statusRequest(issueChallenge: Bool, requestID: PowerBaseBLERequestID?) -> Data {
        var data = Data([PowerBaseBLEProtocol.version, statusRequestType, issueChallenge ? statusIssueChallenge : 0, 0])
        data.append(requestID?.bytes ?? Data(count: PowerBaseBLERequestID.length))
        return data
    }

    /// `[0]` version `[1]` 0x02 `[2]` pskd_len `[3]` 0 `[4..11]` target `[12..27]` request id
    /// `[28..43]` challenge `[44..]` PSKd. `nil` for a PSKd outside the Thread alphabet or 6…32.
    public static func startRequest(
        target: PowerBaseBLEEUI64, requestID: PowerBaseBLERequestID, challenge: PowerBaseBLEChallenge, pskd: String
    ) -> Data? {
        guard isValidPSKd(pskd) else { return nil }
        let code = Data(pskd.utf8)
        var data = Data([PowerBaseBLEProtocol.version, startRequestType, UInt8(code.count), 0])
        data.append(target.bytes)
        data.append(requestID.bytes)
        data.append(challenge.bytes)
        data.append(code)
        return data
    }

    /// The start that also delivers the bridge endpoint (64 + PSKd bytes):
    /// `[0]` version `[1]` 0x04 `[2]` pskd_len `[3]` 0 `[4..11]` target `[12..27]` request id
    /// `[28..43]` challenge `[44]` endpoint format (1) `[45]` 0 `[46..47]` port, big-endian
    /// `[48..63]` IPv6 address `[64..]` PSKd. `nil` for a PSKd outside the Thread alphabet or 6…32.
    /// The version 1 request above is unchanged; this is another message, not an extension of it.
    public static func startRequest(
        target: PowerBaseBLEEUI64, requestID: PowerBaseBLERequestID, challenge: PowerBaseBLEChallenge, pskd: String,
        endpoint: PowerBaseBLEBridgeEndpoint
    ) -> Data? {
        guard isValidPSKd(pskd) else { return nil }
        let code = Data(pskd.utf8)
        var data = Data([PowerBaseBLEProtocol.version, startWithEndpointRequestType, UInt8(code.count), 0])
        data.append(target.bytes)
        data.append(requestID.bytes)
        data.append(challenge.bytes)
        data.append(contentsOf: [PowerBaseBLEBridgeEndpoint.formatVersion, 0, UInt8(endpoint.port >> 8), UInt8(endpoint.port & 0xff)])
        data.append(endpoint.address)
        data.append(code)
        return data
    }

    /// `[0]` version `[1]` 0x03 `[2..3]` 0 `[4..11]` target `[12..27]` request id.
    public static func cancelRequest(target: PowerBaseBLEEUI64, requestID: PowerBaseBLERequestID) -> Data {
        var data = Data([PowerBaseBLEProtocol.version, cancelRequestType, 0, 0])
        data.append(target.bytes)
        data.append(requestID.bytes)
        return data
    }

    // MARK: Responses

    /// The codes each endpoint can answer with (pb_ble_admission.c). Anything else is not a
    /// version 1 answer.
    static let statusCodes: Set<PowerBaseBLECode> = [.ok, .closed, .internalError, .malformed, .unsupportedVersion]
    static let startCodes: Set<PowerBaseBLECode> = [
        .accepted, .duplicate, .unsupportedVersion, .malformed, .wrongTarget, .challengeInvalid, .challengeExpired,
        .invalidPSKd, .busy, .requestConflict, .notWaiting, .closed, .unavailable, .internalError,
    ]
    /// The start with the bridge endpoint answers with the same codes, and with `INVALID_ENDPOINT`.
    static let startWithEndpointCodes: Set<PowerBaseBLECode> = startCodes.union([.invalidEndpoint])
    static let cancelCodes: Set<PowerBaseBLECode> = [.ok, .unsupportedVersion, .malformed, .wrongTarget, .noSuchAttempt, .busy, .closed]

    public static func decodeStatusResponse(_ response: Data) throws -> PowerBaseBLEStatus {
        let bytes = [UInt8](response)
        guard bytes.count == statusResponseLength else { throw PowerBaseBLECodecError.length(bytes.count) }
        guard bytes[0] == PowerBaseBLEProtocol.version else { throw PowerBaseBLECodecError.version(bytes[0]) }
        guard bytes[1] == statusResponseType else { throw PowerBaseBLECodecError.type(bytes[1]) }
        guard bytes[3] == 0, bytes[17] == 0 else { throw PowerBaseBLECodecError.reserved }
        guard let code = PowerBaseBLECode(rawValue: bytes[2]), statusCodes.contains(code) else {
            throw PowerBaseBLECodecError.code(bytes[2])
        }
        if code == .malformed || code == .unsupportedVersion {
            // "offset 4 이후는 모두 0이다": anything else is not that refusal.
            guard bytes[4...].allSatisfy({ $0 == 0 }) else { throw PowerBaseBLECodecError.field("refusal") }
            throw PowerBaseBLECodecError.refused(code)
        }

        guard let eui64 = PowerBaseBLEEUI64(bytes: Data(bytes[4..<12])) else { throw PowerBaseBLECodecError.field("eui64") }
        guard let state = PowerBaseBLEEnrollState(rawValue: bytes[12]) else { throw PowerBaseBLECodecError.field("state") }
        guard bytes[13] <= PowerBaseBLEResult.maximumEnrollResult else { throw PowerBaseBLECodecError.field("last_result") }
        guard bytes[14] & ~PowerBaseBLEStatus.Flags.known == 0 else { throw PowerBaseBLECodecError.field("flags") }
        let flags = PowerBaseBLEStatus.Flags(rawValue: bytes[14])
        guard let phase = PowerBaseBLEAttemptPhase(rawValue: bytes[15]) else { throw PowerBaseBLECodecError.field("phase") }
        let requestResult = bytes[16]
        guard requestResult <= PowerBaseBLEResult.maximumEnrollResult || requestResult == PowerBaseBLEResult.startRefused
                || requestResult == PowerBaseBLEResult.superseded else {
            throw PowerBaseBLECodecError.field("request_result")
        }
        if flags.contains(.requestMatch) {
            guard phase != .none else { throw PowerBaseBLECodecError.field("phase") }
        } else {
            guard phase == .none, requestResult == 0 else { throw PowerBaseBLECodecError.field("phase") }
        }

        let lifetime = Int(bytes[18]) << 8 | Int(bytes[19])
        let challengeBytes = Data(bytes[24..<40])
        var challenge: PowerBaseBLEChallenge?
        if flags.contains(.challengeIssued) {
            // Only an open board issues one (a closed one answers CLOSED without it).
            guard code == .ok, let issued = PowerBaseBLEChallenge(bytes: challengeBytes, lifetimeSeconds: lifetime) else {
                throw PowerBaseBLECodecError.field("challenge")
            }
            challenge = issued
        } else {
            guard lifetime == 0, challengeBytes.allSatisfy({ $0 == 0 }) else { throw PowerBaseBLECodecError.field("challenge") }
        }
        let attempt = UInt32(bytes[20]) << 24 | UInt32(bytes[21]) << 16 | UInt32(bytes[22]) << 8 | UInt32(bytes[23])

        return PowerBaseBLEStatus(
            code: code, eui64: eui64, state: state, lastResult: bytes[13], flags: flags, requestPhase: phase,
            requestResult: requestResult, attempt: attempt, challenge: challenge
        )
    }

    public static func decodeStartResponse(_ response: Data) throws -> PowerBaseBLECode {
        try decodeShortResponse(response, type: startResponseType, codes: startCodes)
    }

    /// The answer to the start with the bridge endpoint: its own response type (0x84). A board
    /// that does not know the message answers with the version 1 type (0x82, `MALFORMED`), which
    /// this refuses as `.type` -- nothing in it is used.
    public static func decodeStartWithEndpointResponse(_ response: Data) throws -> PowerBaseBLECode {
        try decodeShortResponse(response, type: startWithEndpointResponseType, codes: startWithEndpointCodes)
    }

    public static func decodeCancelResponse(_ response: Data) throws -> PowerBaseBLECode {
        try decodeShortResponse(response, type: cancelResponseType, codes: cancelCodes)
    }

    /// `[0]` version `[1]` type `[2]` code `[3]` 0.
    private static func decodeShortResponse(_ response: Data, type: UInt8, codes: Set<PowerBaseBLECode>) throws -> PowerBaseBLECode {
        let bytes = [UInt8](response)
        guard bytes.count == shortResponseLength else { throw PowerBaseBLECodecError.length(bytes.count) }
        guard bytes[0] == PowerBaseBLEProtocol.version else { throw PowerBaseBLECodecError.version(bytes[0]) }
        guard bytes[1] == type else { throw PowerBaseBLECodecError.type(bytes[1]) }
        guard bytes[3] == 0 else { throw PowerBaseBLECodecError.reserved }
        guard let code = PowerBaseBLECode(rawValue: bytes[2]), codes.contains(code) else { throw PowerBaseBLECodecError.code(bytes[2]) }
        return code
    }
}

/// What `proto-ver` must say before any handshake is attempted:
/// `{"prov":{"ver":"v1.1","sec_ver":2,"sec_patch_ver":1,"cap":[]},"pb_enroll":{"proto":1}}`, with
/// an optional `"cap":[…]` list inside `pb_enroll` (firmware that takes the start with the bridge
/// endpoint lists `"bridge_endpoint_v1"` there; older firmware has no list).
public enum PowerBaseBLEVersion {
    public enum Failure: Error, Equatable, Sendable {
        case malformed
        /// Not Security 2 (`sec_ver` 0 or 1, or the `no_sec` capability).
        case securityVersion(Int)
        /// A Security 2 patch level this client does not implement (only 1: the counter IV).
        case securityPatchVersion(Int)
        /// Another enrollment protocol than version 1.
        case enrollmentProtocol(Int)
    }

    private struct Document: Decodable {
        struct Prov: Decodable {
            let sec_ver: Int
            let sec_patch_ver: Int?
            let cap: [String]?
        }
        struct Enroll: Decodable {
            let proto: Int
            /// Absent on firmware older than the capability list. A `cap` that is not a list of
            /// strings makes the whole document malformed.
            let cap: [String]?
        }
        let prov: Prov
        let pb_enroll: Enroll
    }

    /// Checks the security scheme and the protocol version exactly as before, and returns what
    /// the board lists in `pb_enroll.cap`. Names this client does not know are ignored.
    @discardableResult
    public static func validate(_ response: Data) throws -> PowerBaseBLECapabilities {
        guard response.count <= PowerBaseBLEProtocol.maximumAttributeLength,
              let document = try? JSONDecoder().decode(Document.self, from: response) else { throw Failure.malformed }
        guard document.prov.sec_ver == 2, !(document.prov.cap ?? []).contains("no_sec") else {
            throw Failure.securityVersion(document.prov.sec_ver)
        }
        // Absent means patch 0 (a fixed IV): not what this client implements either.
        guard document.prov.sec_patch_ver == 1 else { throw Failure.securityPatchVersion(document.prov.sec_patch_ver ?? 0) }
        guard document.pb_enroll.proto == Int(PowerBaseBLEProtocol.version) else {
            throw Failure.enrollmentProtocol(document.pb_enroll.proto)
        }
        var capabilities: PowerBaseBLECapabilities = []
        if (document.pb_enroll.cap ?? []).contains(PowerBaseBLECapabilities.bridgeEndpointV1Name) {
            capabilities.insert(.bridgeEndpointV1)
        }
        return capabilities
    }
}

/// A board's setup code as the prepare tool (tools/gen_power_base_ble_config.py) writes it: 26
/// characters of RFC 4648 base32, upper case (`A-Z`, `2-7`). It is the Security 2 password and has
/// nothing to do with the Thread PSKd.
public enum PowerBaseSetupCode {
    public static let length = 26

    /// `input` as it must be sent, or `nil` when it isn't a setup code. Only surrounding
    /// whitespace is dropped and ASCII lower-case letters are raised; no character inside is
    /// removed or replaced, so a mistyped code stays wrong instead of becoming another code.
    public static func normalized(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = String.UnicodeScalarView()
        for scalar in trimmed.unicodeScalars {
            switch scalar {
            case "A"..."Z", "2"..."7": result.append(scalar)
            case "a"..."z": result.append(Unicode.Scalar(scalar.value - 32)!)
            default: return nil
            }
        }
        guard result.count == length else { return nil }
        return String(result)
    }
}
#endif
