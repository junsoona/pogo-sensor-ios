#if DEBUG
import Foundation
import PowerBaseBLEKit
import Security

// The hub's Power Base enrollment API ("Power Base enrollment" in the firmware repository's
// docs/pogohome-api-v1.md), for the DEBUG-only enrollment test. Nothing here is compiled into a
// Release build: the app does not register Power Bases yet.

/// A Power Base's Joiner EUI-64 as the hub accepts it: exactly 16 hex digits, not all zero. No
/// separators, no `*` (wildcard Joiner), no discerner.
nonisolated enum PowerBaseEUI64 {
    /// `input` in the hub's form (lowercase), or `nil` when it isn't a usable EUI-64. Only
    /// surrounding whitespace (a pasted line) is ignored.
    static func normalized(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = trimmed.unicodeScalars
        guard scalars.count == 16, scalars.allSatisfy(isASCIIHexDigit) else { return nil }
        let lowercased = trimmed.lowercased()
        guard lowercased != String(repeating: "0", count: 16) else { return nil }
        return lowercased
    }

    static func isASCIIHexDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "0"..."9", "a"..."f", "A"..."F": return true
        default: return false
        }
    }
}

/// A Thread Joiner passphrase (PSKd): 6…32 characters of `0-9 A-Z` without `I O Q Z`.
nonisolated enum ThreadPSKd {
    /// The Thread PSKd alphabet, exactly 32 characters — so 5 random bits pick one without bias.
    static let alphabet: [Character] = Array("0123456789ABCDEFGHJKLMNPRSTUVWXY")
    static let generatedLength = 12

    static func isValid(_ value: String) -> Bool {
        (6...32).contains(value.count) && value.allSatisfy { alphabet.contains($0) }
    }

    /// A new random code of `length` characters, or `nil` when the system has no secure
    /// randomness (then nothing may be sent). Each call is independent of every earlier one.
    static func generate(length: Int = generatedLength, randomBytes: (Int) -> [UInt8]? = SecureRandomBytes.system) -> String? {
        guard (6...32).contains(length), let bytes = randomBytes(length), bytes.count == length else { return nil }
        return String(bytes.map { alphabet[Int($0 & 0x1F)] })
    }
}

nonisolated enum SecureRandomBytes {
    /// `SecRandomCopyBytes`, the system's cryptographically secure generator.
    static func system(_ count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return status == errSecSuccess ? bytes : nil
    }
}

nonisolated enum PowerBaseEnrollmentSessionID {
    /// 32 lowercase hex digits (128 random bits), as the hub issues them.
    static func isValid(_ value: String) -> Bool {
        value.unicodeScalars.count == 32 && value.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}

/// The hub's `bridge_endpoint` of a session started with bridge endpoint delivery: where the Power
/// Base must send its bridge traffic -- the hub's OTBR Mesh-Local EID and the Linux bridge's
/// ingest port. The hub makes it; this device never chooses, types or derives one.
///
/// Decoding is strict: format version exactly 1, `address` an IPv6 literal that is a Thread
/// Mesh-Local EID, `port` 1…65535 (`PowerBaseBLEBridgeEndpoint`). An IPv4 address, an
/// IPv4-mapped or -compatible address, the unspecified address, loopback, multicast, link-local,
/// a zone id, a URL, a host name, an RLOC/ALOC or another format version makes the whole session
/// answer unusable -- nothing of it is delivered to a board.
nonisolated enum PowerBaseEnrollmentBridgeEndpoint {
    /// What the app asks for in the `POST` and the only `version` it reads.
    static let version = 1

    private enum CodingKeys: String, CodingKey {
        case version, address, port
    }

    /// The value of a `bridge_endpoint` key: `nil` for JSON `null` (not established yet).
    static func decodeIfPresent<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>, forKey key: Key
    ) throws -> PowerBaseBLEBridgeEndpoint? {
        guard container.contains(key), try !container.decodeNil(forKey: key) else { return nil }
        let object = try container.nestedContainer(keyedBy: CodingKeys.self, forKey: key)
        let version = try object.decode(Int.self, forKey: .version)
        guard version == Self.version else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: object, debugDescription: "bridge_endpoint version")
        }
        let address = try object.decode(String.self, forKey: .address)
        let port = try object.decode(Int.self, forKey: .port)
        do {
            return try PowerBaseBLEBridgeEndpoint(address: address, port: port)
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .address, in: object, debugDescription: "bridge_endpoint")
        }
    }
}

/// One enrollment session as the hub reports it. Decoding is strict about the documented fields
/// (all required, with their types; `state` one of the six documented values; ids well formed)
/// and ignores unknown additional ones, as the API's compatibility policy asks.
nonisolated struct PowerBaseEnrollmentSession: Equatable, Sendable, Decodable {
    enum State: String, Equatable, Sendable, Decodable {
        /// The hub is making sure the Commissioner is active, then adding the Joiner entry.
        case preparing
        /// The OTBR accepts this EUI-64 as a Joiner; the bridge hasn't heard from it since the start.
        case waitingForHeartbeat = "waiting_for_heartbeat"
        /// Final. The Linux bridge received a heartbeat from this Power Base after the start — the
        /// only state that means success.
        case heartbeatReceived = "heartbeat_received"
        /// Final. This device cancelled it.
        case cancelled
        /// Final. No new heartbeat within the window. The board may still have joined Thread.
        case expired
        /// Final. `error` says why.
        case failed

        var isFinal: Bool {
            switch self {
            case .preparing, .waitingForHeartbeat: return false
            case .heartbeatReceived, .cancelled, .expired, .failed: return true
            }
        }
    }

    let sessionID: String
    let eui64: String
    let state: State
    /// The state is final and the hub's cleanup (removing the Joiner entry) is done.
    let finished: Bool
    /// `none`, `adding`, `allowed`, `removing`, `removed` or `remove_failed` — shown, never decided on.
    let joinerEntry: String
    let error: String?
    let windowSeconds: Int
    let createdAtUnixMs: Int64
    let expiresAtUnixMs: Int64
    /// At the time of the answer; `0` once final. For guidance only — the hub decides the end.
    let expiresInMs: Int64
    let heartbeatReceivedAtUnixMs: Int64?
    let startedByDeviceID: String
    /// The hub's bridge endpoint for this session. `nil`: the key is absent (a session started
    /// without bridge endpoint delivery) or `null` (not established yet -- possible while
    /// `preparing`, and for a session that ended before it was).
    let bridgeEndpoint: PowerBaseBLEBridgeEndpoint?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case eui64
        case state
        case finished
        case joinerEntry = "joiner_entry"
        case error
        case windowSeconds = "window_seconds"
        case createdAtUnixMs = "created_at_unix_ms"
        case expiresAtUnixMs = "expires_at_unix_ms"
        case expiresInMs = "expires_in_ms"
        case heartbeatReceivedAtUnixMs = "heartbeat_received_at_unix_ms"
        case startedByDeviceID = "started_by_device_id"
        case bridgeEndpoint = "bridge_endpoint"
    }

    init(
        sessionID: String, eui64: String, state: State, finished: Bool, joinerEntry: String, error: String?,
        windowSeconds: Int, createdAtUnixMs: Int64, expiresAtUnixMs: Int64, expiresInMs: Int64,
        heartbeatReceivedAtUnixMs: Int64?, startedByDeviceID: String, bridgeEndpoint: PowerBaseBLEBridgeEndpoint? = nil
    ) {
        self.sessionID = sessionID
        self.eui64 = eui64
        self.state = state
        self.finished = finished
        self.joinerEntry = joinerEntry
        self.error = error
        self.windowSeconds = windowSeconds
        self.createdAtUnixMs = createdAtUnixMs
        self.expiresAtUnixMs = expiresAtUnixMs
        self.expiresInMs = expiresInMs
        self.heartbeatReceivedAtUnixMs = heartbeatReceivedAtUnixMs
        self.startedByDeviceID = startedByDeviceID
        self.bridgeEndpoint = bridgeEndpoint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sessionID = try container.decode(String.self, forKey: .sessionID)
        guard PowerBaseEnrollmentSessionID.isValid(sessionID) else {
            throw DecodingError.dataCorruptedError(forKey: .sessionID, in: container, debugDescription: "session_id")
        }
        let eui64 = try container.decode(String.self, forKey: .eui64)
        guard PowerBaseEUI64.normalized(eui64) == eui64 else {
            throw DecodingError.dataCorruptedError(forKey: .eui64, in: container, debugDescription: "eui64")
        }
        let windowSeconds = try container.decode(Int.self, forKey: .windowSeconds)
        let expiresInMs = try container.decode(Int64.self, forKey: .expiresInMs)
        guard windowSeconds > 0, expiresInMs >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .expiresInMs, in: container, debugDescription: "times")
        }
        self.init(
            sessionID: sessionID,
            eui64: eui64,
            state: try container.decode(State.self, forKey: .state),
            finished: try container.decode(Bool.self, forKey: .finished),
            joinerEntry: try container.decode(String.self, forKey: .joinerEntry),
            // Present, `null` or a string — a missing key is a malformed answer.
            error: try container.decode(String?.self, forKey: .error),
            windowSeconds: windowSeconds,
            createdAtUnixMs: try container.decode(Int64.self, forKey: .createdAtUnixMs),
            expiresAtUnixMs: try container.decode(Int64.self, forKey: .expiresAtUnixMs),
            expiresInMs: expiresInMs,
            heartbeatReceivedAtUnixMs: try container.decode(Int64?.self, forKey: .heartbeatReceivedAtUnixMs),
            startedByDeviceID: try container.decode(String.self, forKey: .startedByDeviceID),
            // Absent or `null`: none. Present: every field checked, or the answer is refused.
            bridgeEndpoint: try PowerBaseEnrollmentBridgeEndpoint.decodeIfPresent(from: container, forKey: .bridgeEndpoint)
        )
    }
}

/// Why an enrollment request didn't give a usable session. Never carries the PSKd or the token.
nonisolated enum PowerBaseEnrollmentError: Error, Equatable, Sendable {
    /// `401`: the hub doesn't know this device's token (revoked, or its device list was reset).
    case unauthorized
    /// `403` with the hub's code (`tls_required`, …).
    case forbidden(String)
    /// `404 enrollment_disabled`: the bridge runs without `--api-enroll-helper`.
    case enrollmentDisabled
    /// `404 session_not_found`: unknown, forgotten, or another device's session.
    case sessionNotFound
    /// `404`/`405` without an enrollment code: a bridge that has no enrollment routes.
    case notSupported
    /// `409 enrollment_in_progress`. `ownSession` is this device's own running session (the hub
    /// includes it only for the device that started it); `nil`: another device's.
    case enrollmentInProgress(ownSession: PowerBaseEnrollmentSession?)
    /// `409 power_base_already_connected`: a Base with this EUI-64 is online right now.
    case powerBaseAlreadyConnected
    /// `409 session_already_final` (a `DELETE` after the end), with the final session.
    case sessionAlreadyFinal(PowerBaseEnrollmentSession)
    /// `400`/`411`/`413`/`422` with the hub's code (`invalid_eui64`, `invalid_pskd`, …).
    case rejected(String)
    /// The hub does not deliver bridge endpoints: it refused the request that asked for one
    /// (`400 invalid_request` from a bridge older than the option, which accepts exactly two
    /// fields, or `422 unsupported_bridge_endpoint_version`). No session exists. The app does not
    /// ask again without the option and does not make up an address.
    case bridgeEndpointNotSupported
    /// `503` with the hub's reason (`startup`, `stopping`, `auth_unavailable`, …).
    case unavailable(String)
    /// `500 internal_error`.
    case internalError
    /// The hub presented a different certificate than the one pinned at pairing. Nothing was sent.
    case certificateMismatch
    /// No answer: hub off, network down, timeout.
    case unreachable(String)
    /// An answer outside the API contract.
    case badResponse(String)

    /// Worth asking again in a second while a session runs (the hub or the network may recover).
    var isTransient: Bool {
        switch self {
        case .unreachable, .unavailable, .internalError, .badResponse: return true
        default: return false
        }
    }
}
#endif
