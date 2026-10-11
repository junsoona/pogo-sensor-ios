import Foundation
import Security

// The Power Base BLE enrollment wire protocol, version 1. Normative: the firmware repository's
// components/power_base_ble_enroll/include/power_base_ble_enroll/pb_ble_proto.h and
// docs/power-base.md "BLE 등록 전달 경로". Every value below is copied from there; nothing is
// guessed. Every multi-byte integer is big-endian.
//
// Three start messages exist on `pb-start`: the first one (0x02, PSKd only), the one that also
// carries the Linux bridge endpoint (0x04, capability `bridge_endpoint_v1`), and the one that
// carries the endpoint and the hub's management credential (0x06, capability `mgmt_v1`, firmware
// repository docs/power-base-management.md). Each keeps its own bytes; a message is only ever sent
// to a board that lists its capability, and never replaced by an older one.
//
// Two more messages belong to the local reset of an enrolled board (capability `local_reset_v1`,
// firmware repository docs/power-base.md "BOOT 버튼 로컬 재등록"): the reset command on `pb-start`
// (0x09) and "what became of it" on `pb-status` (0x08). They follow the same rule.

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

/// The client's name for one local reset: 16 bytes from the system's secure random generator,
/// never all zero. It names the operation for as long as its outcome is asked about -- across a
/// lost answer, a new connection and a restart of the board -- so that asking never becomes a
/// second reset.
public struct PowerBaseBLEOperationID: Hashable, Sendable {
    public static let length = 16
    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count == Self.length, bytes.contains(where: { $0 != 0 }) else { return nil }
        self.bytes = Data(bytes)
    }

    /// A new id, or `nil` when there is no secure randomness (then nothing may be sent).
    public static func random(_ randomBytes: (Int) -> [UInt8]? = PowerBaseBLERandom.system) -> PowerBaseBLEOperationID? {
        guard let bytes = randomBytes(length), bytes.count == length else { return nil }
        return PowerBaseBLEOperationID(bytes: Data(bytes))
    }
}

/// What the user must have said before a local reset command is built: that the board's existing
/// registration is to be erased. There is exactly one value, and no command can be encoded without
/// it -- so a reset is never sent by a code path that did not go through the confirmation.
public struct PowerBaseBLELocalResetConfirmation: Equatable, Sendable {
    /// Byte [44] of the request (`PB_BLE_LOCAL_RESET_CONFIRM_ERASE`).
    let wireValue: UInt8
    private init(wireValue: UInt8) { self.wireValue = wireValue }

    /// The user explicitly confirmed erasing the board's existing network registration.
    public static let userConfirmedErasingRegistration = PowerBaseBLELocalResetConfirmation(wireValue: 0x01)
}

/// What a board says about a local reset (`pb-status` message 0x08 / 0x88). Only ever built from a
/// response that passed every check.
///
/// Four things are kept apart and none is taken for another: the command being *accepted* (the
/// answer to the command itself), the reset being *in progress* (journaled on the board: it never
/// resumes its old registration again), the reset being *verified* (`phase == .verified` with
/// `condition == .notEnrolled`), and a new registration -- which is not reported here at all.
public struct PowerBaseBLELocalResetStatus: Equatable, Sendable {
    /// What the board holds now (`PB_BLE_LR_COND_*`).
    public enum Condition: UInt8, Equatable, Sendable {
        /// Nothing it would resume: nothing to reset; register it the usual way.
        case notEnrolled = 0
        /// A registration it resumes from.
        case enrolled = 1
        /// Its hub is unenrolling it: that comes first.
        case remoteReleasePending = 2
        /// A journaled local reset is not finished.
        case resetPending = 3
        /// Its reset journal or registration record cannot be read.
        case unreadable = 4
    }

    /// How far the asked operation got (`PB_BLE_LR_PHASE_*`).
    public enum Phase: UInt8, Equatable, Sendable {
        /// Accepted; the board's worker has not journaled it yet.
        case queued = 1
        /// Journaled; the erase is not verified (yet).
        case inProgress = 2
        /// The registration record and the stored network were read back empty.
        case verified = 3
        /// Ended before anything was changed.
        case notStarted = 4
    }

    public static let formatVersion: UInt8 = 1
    public static let maximumReason: UInt8 = 9
    public static let maximumWindowSeconds = 120

    public var eui64: PowerBaseBLEEUI64
    public var condition: Condition
    /// The board's physical re-enrollment window (opened with its button) is open now.
    public var isWindowOpen: Bool
    /// Seconds left in that window; 0 unless it is open.
    public var windowSecondsLeft: Int
    /// `nil` unless the board knows the operation that was asked about.
    public var operationPhase: Phase?
    /// `PB_BLE_LR_REASON_*` of that operation (0: none).
    public var operationReason: UInt8

    public init(
        eui64: PowerBaseBLEEUI64, condition: Condition, isWindowOpen: Bool = false, windowSecondsLeft: Int = 0,
        operationPhase: Phase? = nil, operationReason: UInt8 = 0
    ) {
        self.eui64 = eui64
        self.condition = condition
        self.isWindowOpen = isWindowOpen
        self.windowSecondsLeft = windowSecondsLeft
        self.operationPhase = operationPhase
        self.operationReason = operationReason
    }

    static let reasonNames = [
        "none", "journal_store_failed", "not_enrolled", "remote_release_pending", "other_reset_pending",
        "record_clear_failed", "record_still_present", "network_erase_failed", "network_not_empty", "journal_final_failed",
    ]

    /// The documented name of a reason value this codec accepted, for a developer-facing display.
    public static func reasonName(_ value: UInt8) -> String {
        Int(value) < reasonNames.count ? reasonNames[Int(value)] : "0x" + String(value, radix: 16)
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

/// The hub's management credential for one enrollment: its id, the enrollment generation and the
/// 32-byte management key -- what later authenticates a remote "unenroll" between that hub and that
/// board (firmware repository, docs/power-base-management.md). Carried by `pb-start` message 0x06
/// (pb_ble_proto.h `PB_BLE_MSG_START_MGMT_REQ`, capability `mgmt_v1`).
///
/// The key is a secret. This type is how it travels from the hub's answer to the one encrypted
/// request that hands it to the board; nothing here stores it, and it has no textual form: every
/// description of a value of this type is the same fixed word.
public struct PowerBaseBLEManagementCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Byte [64] of the request: the management format this type is.
    public static let formatVersion: UInt8 = 1
    public static let hubIDLength = 16
    public static let generationLength = 16
    public static let keyLength = 32

    public let hubID: Data
    public let generation: Data
    let key: Data

    /// `nil` unless each part has its exact length and is not all zero.
    public init?(hubID: Data, generation: Data, key: Data) {
        guard hubID.count == Self.hubIDLength, generation.count == Self.generationLength, key.count == Self.keyLength,
              hubID.contains(where: { $0 != 0 }), generation.contains(where: { $0 != 0 }), key.contains(where: { $0 != 0 }) else { return nil }
        self.hubID = Data(hubID)
        self.generation = Data(generation)
        self.key = Data(key)
    }

    /// From the hub's JSON: 32, 32 and 64 lower-case hex digits. Anything else is not a credential.
    public init?(hubIDHex: String, generationHex: String, keyHex: String) {
        guard let hubID = Self.bytes(hubIDHex, count: Self.hubIDLength), let generation = Self.bytes(generationHex, count: Self.generationLength),
              let key = Self.bytes(keyHex, count: Self.keyLength) else { return nil }
        self.init(hubID: hubID, generation: generation, key: key)
    }

    /// The generation as the hub prints it (32 lower-case hex digits). Not a secret.
    public var generationHex: String { generation.map { String(format: "%02x", $0) }.joined() }

    public var description: String { "PowerBaseBLEManagementCredential(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    private static func bytes(_ hex: String, count: Int) -> Data? {
        let scalars = Array(hex.unicodeScalars)
        guard scalars.count == count * 2 else { return nil }
        var out = Data(capacity: count)
        for index in stride(from: 0, to: scalars.count, by: 2) {
            guard let high = nibble(scalars[index]), let low = nibble(scalars[index + 1]) else { return nil }
            out.append(high << 4 | low)
        }
        return out
    }

    private static func nibble(_ scalar: Unicode.Scalar) -> UInt8? {
        switch scalar {
        case "0"..."9": return UInt8(scalar.value - 48)
        case "a"..."f": return UInt8(scalar.value - 87)
        default: return nil
        }
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
    /// `"mgmt_v1"`: the board takes `pb-start` with the bridge endpoint and the hub's management
    /// credential (message 0x06), and can then be unenrolled by that hub.
    public static let managementV1 = PowerBaseBLECapabilities(rawValue: 0x02)
    /// `"release_receipt_v1"`: the board hands out its release receipt on `pb-status` (message
    /// 0x07) after its hub unenrolled it.
    public static let releaseReceiptV1 = PowerBaseBLECapabilities(rawValue: 0x04)

    /// `"local_reset_v1"`: the board has a re-enrollment button and takes the local reset command
    /// (message 0x09 on `pb-start`) and its status (message 0x08 on `pb-status`).
    public static let localResetV1 = PowerBaseBLECapabilities(rawValue: 0x08)

    static let bridgeEndpointV1Name = "bridge_endpoint_v1"
    static let managementV1Name = "mgmt_v1"
    static let releaseReceiptV1Name = "release_receipt_v1"
    static let localResetV1Name = "local_reset_v1"
}

/// A board's release receipt (firmware repository, docs/power-base-management.md): the complete
/// management message `UNENROLL_DONE` with result `ERASED`, which the board makes only after it
/// erased its stored network, checked that, and stored its final record. A released board has no
/// Thread network left, so this is read here, inside the Security 2 session, and relayed to the
/// hub -- the only thing that completes a removal there.
///
/// It holds no secret (identifiers and a MAC). This type checks its shape only; whether it is
/// genuine is decided by the hub that issued the enrollment's key, never by the app.
public struct PowerBaseBLEReleaseReceipt: Equatable, Sendable {
    public static let length = 96
    static let messageType: UInt8 = 0x03
    static let resultOffset = 60
    static let resultErased: UInt8 = 2

    public let bytes: Data

    /// `nil` unless `bytes` is an `UNENROLL_DONE` of management protocol version 1 that says
    /// `ERASED`. In particular the board's "released" notice (result 1) is not a receipt.
    public init?(bytes: Data) {
        let b = [UInt8](bytes)
        guard b.count == Self.length, b[0] == 1, b[1] == Self.messageType, b[2] == 0, b[3] == 0,
              b[Self.resultOffset] == Self.resultErased, b[61] == 0, b[62] == 0, b[63] == 0 else { return nil }
        self.bytes = Data(b)
    }

    /// The EUI-64 the receipt names, 16 lower-case hex digits.
    public var eui64Hex: String { PowerBaseBLEHex.string(bytes.subdata(in: 4..<12)) }
    /// The hub the receipt is for, 32 lower-case hex digits.
    public var hubIDHex: String { PowerBaseBLEHex.string(bytes.subdata(in: 12..<28)) }
    /// The enrollment generation it belongs to, 32 lower-case hex digits.
    public var generationHex: String { PowerBaseBLEHex.string(bytes.subdata(in: 28..<44)) }
    /// The whole receipt as the hub's API takes it: 192 lower-case hex digits.
    public var hex: String { PowerBaseBLEHex.string(bytes) }
}

enum PowerBaseBLEHex {
    static func string(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(data.count * 2)
        for byte in data {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }
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
    /// `pb-start` with the management credential only: unknown management format, or a hub id,
    /// generation or key made of zeros. Nothing started.
    case invalidManagement = 0x1e
    /// The local reset command only: no physical re-enrollment window is open on the board (its
    /// button was not held, or the window's time is over). Nothing changed.
    case windowClosed = 0x1f
    /// The local reset command only: the board holds no registration it would resume, so there is
    /// nothing to reset. Nothing changed.
    case notEnrolled = 0x20

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
        case .invalidManagement: return "INVALID_MANAGEMENT"
        case .windowClosed: return "WINDOW_CLOSED"
        case .notEnrolled: return "NOT_ENROLLED"
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
    /// `pb-start` with the bridge endpoint and the management credential: a third message.
    static let startWithManagementRequestType: UInt8 = 0x06
    static let startWithManagementResponseType: UInt8 = 0x86
    static let receiptRequestType: UInt8 = 0x07
    static let receiptResponseType: UInt8 = 0x87
    static let receiptFormatVersion: UInt8 = 1
    /// `pb-status`: what became of a local reset.
    static let localResetStatusRequestType: UInt8 = 0x08
    static let localResetStatusResponseType: UInt8 = 0x88
    /// `pb-start`: the local reset command.
    static let localResetRequestType: UInt8 = 0x09
    static let localResetResponseType: UInt8 = 0x89

    public static let localResetStatusRequestLength = 28
    public static let localResetStatusResponseLength = 32
    public static let localResetRequestLength = 48

    public static let statusRequestLength = 20
    public static let statusResponseLength = 40
    public static let startRequestFixedLength = 44
    public static let startWithEndpointRequestFixedLength = 64
    public static let startWithManagementRequestFixedLength = 130
    public static let cancelRequestLength = 28
    public static let shortResponseLength = 4
    public static let receiptRequestLength = 12
    public static let receiptResponseLength = 112

    static let statusIssueChallenge: UInt8 = 0x01

    /// The Thread PSKd alphabet: `0-9 A-Z` without `I O Q Z`.
    static let pskdAlphabet = Set("0123456789ABCDEFGHJKLMNPRSTUVWXY".utf8)

    public static func isValidPSKd(_ pskd: String) -> Bool {
        let bytes = Array(pskd.utf8)
        return (6...32).contains(bytes.count) && bytes.allSatisfy(pskdAlphabet.contains)
    }

    // MARK: Requests

    /// `[0]` version `[1]` 0x01 `[2]` flags `[3]` 0 `[4..19]` request id to ask about (zero: none).
    /// `[0]` version `[1]` 0x07 `[2]` 0 `[3]` 0 `[4..11]` target. Sent on `pb-status`, only to a
    /// board that lists `release_receipt_v1`.
    public static func receiptRequest(target: PowerBaseBLEEUI64) -> Data {
        var data = Data([PowerBaseBLEProtocol.version, receiptRequestType, 0, 0])
        data.append(target.bytes)
        return data
    }

    /// `[0]` version `[1]` 0x87 `[2]` code `[3]` 0 `[4..11]` the board's EUI-64 `[12]` receipt
    /// format (1) `[13]` 1 = present `[14..15]` 0 `[16..111]` the receipt, or zeros.
    ///
    /// `nil`: the board has no receipt. Throws for anything that is not exactly one of the two
    /// documented answers for `target` -- a refusal, another board's EUI-64, a "present" flag with
    /// something that is not a receipt, or a receipt that names another board.
    public static func decodeReceiptResponse(_ response: Data, target: PowerBaseBLEEUI64) throws -> PowerBaseBLEReleaseReceipt? {
        let bytes = [UInt8](response)
        guard bytes.count == receiptResponseLength else { throw PowerBaseBLECodecError.length(bytes.count) }
        guard bytes[0] == PowerBaseBLEProtocol.version else { throw PowerBaseBLECodecError.version(bytes[0]) }
        guard bytes[1] == receiptResponseType else { throw PowerBaseBLECodecError.type(bytes[1]) }
        guard bytes[3] == 0, bytes[14] == 0, bytes[15] == 0 else { throw PowerBaseBLECodecError.reserved }
        guard let code = PowerBaseBLECode(rawValue: bytes[2]) else { throw PowerBaseBLECodecError.code(bytes[2]) }
        guard code == .ok else {
            guard code == .malformed || code == .unsupportedVersion || code == .wrongTarget else {
                throw PowerBaseBLECodecError.code(bytes[2])
            }
            throw PowerBaseBLECodecError.refused(code)
        }
        guard bytes[12] == receiptFormatVersion else { throw PowerBaseBLECodecError.field("receipt version") }
        guard Data(bytes[4..<12]) == target.bytes else { throw PowerBaseBLECodecError.field("eui64") }
        let body = Data(bytes[16...])
        switch bytes[13] {
        case 0:
            guard body.allSatisfy({ $0 == 0 }) else { throw PowerBaseBLECodecError.field("receipt") }
            return nil
        case 1:
            guard let receipt = PowerBaseBLEReleaseReceipt(bytes: body), receipt.bytes.subdata(in: 4..<12) == target.bytes else {
                throw PowerBaseBLECodecError.field("receipt")
            }
            return receipt
        default:
            throw PowerBaseBLECodecError.field("receipt present")
        }
    }

    // MARK: Local reset

    /// `[0]` version `[1]` 0x08 `[2]` 0 `[3]` 0 `[4..11]` target `[12..27]` operation id to ask
    /// about (zero: none). Sent on `pb-status`, only to a board that lists `local_reset_v1`.
    /// Asking changes nothing on the board and needs no challenge.
    public static func localResetStatusRequest(target: PowerBaseBLEEUI64, operationID: PowerBaseBLEOperationID?) -> Data {
        var data = Data([PowerBaseBLEProtocol.version, localResetStatusRequestType, 0, 0])
        data.append(target.bytes)
        data.append(operationID?.bytes ?? Data(count: PowerBaseBLEOperationID.length))
        return data
    }

    /// `[0]` version `[1]` 0x88 `[2]` code `[3]` 0 `[4..11]` the board's EUI-64 `[12]` local reset
    /// format (1) `[13]` condition `[14]` flags (0x01 window open, 0x02 operation known)
    /// `[15]` phase `[16]` reason `[17]` 0 `[18..19]` seconds left in the window `[20..31]` 0.
    ///
    /// Throws for anything that is not exactly a documented answer for `target`: a refusal,
    /// another board's EUI-64, a value outside its range, or fields that contradict each other.
    public static func decodeLocalResetStatusResponse(_ response: Data, target: PowerBaseBLEEUI64) throws -> PowerBaseBLELocalResetStatus {
        let bytes = [UInt8](response)
        guard bytes.count == localResetStatusResponseLength else { throw PowerBaseBLECodecError.length(bytes.count) }
        guard bytes[0] == PowerBaseBLEProtocol.version else { throw PowerBaseBLECodecError.version(bytes[0]) }
        guard bytes[1] == localResetStatusResponseType else { throw PowerBaseBLECodecError.type(bytes[1]) }
        guard bytes[3] == 0, bytes[17] == 0, bytes[20...].allSatisfy({ $0 == 0 }) else { throw PowerBaseBLECodecError.reserved }
        guard let code = PowerBaseBLECode(rawValue: bytes[2]) else { throw PowerBaseBLECodecError.code(bytes[2]) }
        guard code == .ok else {
            guard code == .malformed || code == .unsupportedVersion || code == .wrongTarget else {
                throw PowerBaseBLECodecError.code(bytes[2])
            }
            // A refusal carries no state: everything after the EUI-64 is zero (and for the first
            // two the EUI-64 as well). Anything else is not that refusal.
            guard bytes[12...].allSatisfy({ $0 == 0 }), code == .wrongTarget || bytes[4..<12].allSatisfy({ $0 == 0 }) else {
                throw PowerBaseBLECodecError.field("refusal")
            }
            throw PowerBaseBLECodecError.refused(code)
        }
        guard Data(bytes[4..<12]) == target.bytes else { throw PowerBaseBLECodecError.field("eui64") }
        guard bytes[12] == PowerBaseBLELocalResetStatus.formatVersion else { throw PowerBaseBLECodecError.field("local reset version") }
        guard let condition = PowerBaseBLELocalResetStatus.Condition(rawValue: bytes[13]) else { throw PowerBaseBLECodecError.field("condition") }
        guard bytes[14] & ~0x03 == 0 else { throw PowerBaseBLECodecError.field("flags") }
        let windowOpen = bytes[14] & 0x01 != 0
        let operationKnown = bytes[14] & 0x02 != 0
        let phase = PowerBaseBLELocalResetStatus.Phase(rawValue: bytes[15])
        guard bytes[16] <= PowerBaseBLELocalResetStatus.maximumReason else { throw PowerBaseBLECodecError.field("reason") }
        if operationKnown {
            guard phase != nil else { throw PowerBaseBLECodecError.field("phase") }
        } else {
            guard bytes[15] == 0, bytes[16] == 0 else { throw PowerBaseBLECodecError.field("phase") }
        }
        let seconds = Int(bytes[18]) << 8 | Int(bytes[19])
        if windowOpen {
            guard (1...PowerBaseBLELocalResetStatus.maximumWindowSeconds).contains(seconds) else { throw PowerBaseBLECodecError.field("window") }
        } else {
            guard seconds == 0 else { throw PowerBaseBLECodecError.field("window") }
        }
        return PowerBaseBLELocalResetStatus(
            eui64: target, condition: condition, isWindowOpen: windowOpen, windowSecondsLeft: seconds,
            operationPhase: operationKnown ? phase : nil, operationReason: bytes[16]
        )
    }

    /// The local reset command (48 bytes), sent on `pb-start`, only to a board that lists
    /// `local_reset_v1`: `[0]` version `[1]` 0x09 `[2]` local reset format (1) `[3]` 0
    /// `[4..11]` target `[12..27]` operation id `[28..43]` challenge `[44]` confirmation (0x01)
    /// `[45..47]` 0. It cannot be built without a `PowerBaseBLELocalResetConfirmation`.
    public static func localResetRequest(
        target: PowerBaseBLEEUI64, operationID: PowerBaseBLEOperationID, challenge: PowerBaseBLEChallenge,
        confirmation: PowerBaseBLELocalResetConfirmation
    ) -> Data {
        var data = Data([PowerBaseBLEProtocol.version, localResetRequestType, PowerBaseBLELocalResetStatus.formatVersion, 0])
        data.append(target.bytes)
        data.append(operationID.bytes)
        data.append(challenge.bytes)
        data.append(contentsOf: [confirmation.wireValue, 0, 0, 0])
        return data
    }

    /// The codes the local reset command can be answered with (pb_ble_admission.c).
    static let localResetCodes: Set<PowerBaseBLECode> = [
        .accepted, .duplicate, .malformed, .wrongTarget, .challengeInvalid, .challengeExpired, .busy, .requestConflict,
        .closed, .windowClosed, .notEnrolled,
    ]

    /// The answer to the local reset command: its own response type (0x89). A board that does not
    /// know the message answers with the version 1 type (0x82, `MALFORMED`), which this refuses as
    /// `.type` -- nothing in it is used. `.accepted` means the board took the command, not that it
    /// erased anything.
    public static func decodeLocalResetResponse(_ response: Data) throws -> PowerBaseBLECode {
        try decodeShortResponse(response, type: localResetResponseType, codes: localResetCodes)
    }

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

    /// The start that delivers the bridge endpoint and the hub's management credential
    /// (130 + PSKd bytes): the 0x04 layout up to `[63]` with type 0x06, then
    /// `[64]` management format (1) `[65]` 0 `[66..81]` hub id `[82..97]` enrollment generation
    /// `[98..129]` management key `[130..]` PSKd. `nil` for a PSKd outside the Thread alphabet or
    /// 6…32. The two earlier requests are unchanged; this is another message.
    public static func startRequest(
        target: PowerBaseBLEEUI64, requestID: PowerBaseBLERequestID, challenge: PowerBaseBLEChallenge, pskd: String,
        endpoint: PowerBaseBLEBridgeEndpoint, management: PowerBaseBLEManagementCredential
    ) -> Data? {
        guard isValidPSKd(pskd) else { return nil }
        let code = Data(pskd.utf8)
        var data = Data([PowerBaseBLEProtocol.version, startWithManagementRequestType, UInt8(code.count), 0])
        data.append(target.bytes)
        data.append(requestID.bytes)
        data.append(challenge.bytes)
        data.append(contentsOf: [PowerBaseBLEBridgeEndpoint.formatVersion, 0, UInt8(endpoint.port >> 8), UInt8(endpoint.port & 0xff)])
        data.append(endpoint.address)
        data.append(contentsOf: [PowerBaseBLEManagementCredential.formatVersion, 0])
        data.append(management.hubID)
        data.append(management.generation)
        data.append(management.key)
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
    /// The start with the management credential adds `INVALID_MANAGEMENT` to those.
    static let startWithManagementCodes: Set<PowerBaseBLECode> = startWithEndpointCodes.union([.invalidManagement])
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

    /// The answer to the start with the management credential: its own response type (0x86). A
    /// board that does not know the message answers with the version 1 type (0x82, `MALFORMED`),
    /// which this refuses as `.type` -- nothing in it is used.
    public static func decodeStartWithManagementResponse(_ response: Data) throws -> PowerBaseBLECode {
        try decodeShortResponse(response, type: startWithManagementResponseType, codes: startWithManagementCodes)
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
/// endpoint lists `"bridge_endpoint_v1"` there, firmware that also takes the management credential
/// `"mgmt_v1"`; older firmware has no list).
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
        if (document.pb_enroll.cap ?? []).contains(PowerBaseBLECapabilities.managementV1Name) {
            capabilities.insert(.managementV1)
        }
        if (document.pb_enroll.cap ?? []).contains(PowerBaseBLECapabilities.releaseReceiptV1Name) {
            capabilities.insert(.releaseReceiptV1)
        }
        if (document.pb_enroll.cap ?? []).contains(PowerBaseBLECapabilities.localResetV1Name) {
            capabilities.insert(.localResetV1)
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
