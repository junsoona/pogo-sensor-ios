#if DEBUG
import ESPProvisionSecurity2
import Foundation

/// Why one exchange with the board gave no answer. Never carries a payload.
public enum PowerBaseBLELinkError: Error, Equatable, Sendable {
    /// The board answered the write with an ATT error: its handler refused the request (for an
    /// encrypted endpoint: it could not decrypt it; for the handshake: wrong proof, a locked
    /// board, or session data it does not accept).
    case rejected
    case timeout
    case disconnected
    /// The message does not fit one characteristic value. It is never split: the board would take
    /// each piece as a request of its own.
    case messageTooLong(length: Int, limit: Int)
    case cancelled
    /// Any other transport problem; `detail` is a short technical word, never data.
    case failed(String)
}

/// One connection to one board: a request is written to the endpoint's characteristic (with
/// response) and the answer is read back from the same characteristic. One exchange at a time.
public protocol PowerBaseBLELink: Sendable {
    func exchange(endpoint: PowerBaseBLEProtocol.Endpoint, payload: Data) async throws -> Data
    /// Ends the connection. Safe to call more than once.
    func close() async
}

public enum PowerBaseBLEClientError: Error, Equatable, Sendable {
    /// `proto-ver` could not be read.
    case versionUnreadable(PowerBaseBLELinkError)
    /// The board speaks another security scheme, patch level or enrollment protocol.
    case unsupportedVersion(PowerBaseBLEVersion.Failure)
    /// The handshake's transport failed before the board judged the credentials.
    case handshakeInterrupted(PowerBaseBLELinkError)
    /// The board refused the first handshake message: BLE enrollment is closed or locked for this
    /// boot, or it does not accept this client's session data.
    case handshakeRefused
    /// The board refused the client's proof: the setup code or the EUI-64 is not this board's.
    case authenticationFailed
    /// The board could not prove it holds the verifier for this EUI-64 and setup code.
    case boardProofMismatch
    case handshakeMalformed(String)
    /// No usable Security 2 session: never established, closed, or discarded after a failure.
    case noSession
    /// An encrypted request got no usable answer. The session is discarded: its AES-GCM counters
    /// can no longer be trusted, and the board may or may not have acted on the request.
    case requestFailed(PowerBaseBLELinkError)
    /// The answer's AES-GCM tag did not verify. The session is discarded.
    case decryptionFailed
    /// The answer is not a version 1 message. Nothing in it was used; the session is discarded.
    case malformedResponse(PowerBaseBLECodecError)
    /// The board answered `pb-status` with `MALFORMED` or `UNSUPPORTED_VERSION`.
    case refusedByBoard(PowerBaseBLECode)
    case invalidInput(String)
}

/// The protocol side of one connection: reads `proto-ver`, runs Espressif's Security 2 handshake
/// and sends `pb-status` / `pb-start` / `pb-cancel` inside the session.
///
/// - Everything goes through one serial path: a second call waits until the first exchange has
///   its answer, so the session's counters advance in the order the board sees.
/// - It never repeats anything on its own. A handshake is attempted once; after any failure of an
///   encrypted request the session is gone and every later call throws `.noSession` without
///   touching the link. The caller decides whether to connect and authenticate again.
/// - The SRP arithmetic runs on this actor, off the main thread.
public actor PowerBaseBLEBoardClient {
    private let link: PowerBaseBLELink
    private var handshake: Security2Handshake?
    private var versionChecked = false
    private var boardCapabilities: PowerBaseBLECapabilities = []
    private var authenticationAttempted = false
    private var closed = false

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(link: PowerBaseBLELink) {
        self.link = link
    }

    /// A Security 2 session is established and nothing has gone wrong since.
    public var hasSession: Bool { handshake?.isEstablished == true && !closed }

    // MARK: - Before the session

    /// Reads `proto-ver` and refuses anything but Security 2 patch 1 with enrollment protocol 1.
    public func checkVersion() async throws {
        await acquire()
        defer { release() }
        guard !closed else { throw PowerBaseBLEClientError.noSession }
        let response: Data
        do {
            // The official clients write "ESP"; the board ignores the value.
            response = try await link.exchange(endpoint: .version, payload: Data("ESP".utf8))
        } catch {
            throw PowerBaseBLEClientError.versionUnreadable(Self.linkError(error))
        }
        do {
            boardCapabilities = try PowerBaseBLEVersion.validate(response)
        } catch let failure as PowerBaseBLEVersion.Failure {
            throw PowerBaseBLEClientError.unsupportedVersion(failure)
        }
        versionChecked = true
    }

    /// What the board listed in `proto-ver` (`pb_enroll.cap`); empty before `checkVersion()`.
    public func capabilities() -> PowerBaseBLECapabilities { boardCapabilities }

    /// The Security 2 handshake, once. `eui64` is the user name; `setupCode` the password, exactly
    /// as the prepare tool wrote it. Neither is kept after the call.
    ///
    /// A failure here counts against the board's limit of five per boot, so this is never retried
    /// automatically -- not by this type and not by its caller.
    public func authenticate(eui64: PowerBaseBLEEUI64, setupCode: String, srpPrivateKeyForTesting: Data? = nil) async throws {
        await acquire()
        defer { release() }
        guard !closed, versionChecked, !authenticationAttempted else { throw PowerBaseBLEClientError.noSession }
        guard let password = PowerBaseSetupCode.normalized(setupCode), password == setupCode else {
            throw PowerBaseBLEClientError.invalidInput("setup_code")
        }
        authenticationAttempted = true
        let session = Security2Handshake(username: eui64.hex, password: password, srpPrivateKey: srpPrivateKeyForTesting)

        let command0: Data
        do {
            command0 = try session.command0()
        } catch {
            throw PowerBaseBLEClientError.handshakeMalformed("command0")
        }
        let response0: Data
        do {
            response0 = try await link.exchange(endpoint: .session, payload: command0)
        } catch PowerBaseBLELinkError.rejected {
            throw PowerBaseBLEClientError.handshakeRefused
        } catch {
            throw PowerBaseBLEClientError.handshakeInterrupted(Self.linkError(error))
        }

        let command1: Data
        do {
            command1 = try session.command1(response0: response0)
        } catch {
            throw Self.handshakeError(error)
        }
        let response1: Data
        do {
            response1 = try await link.exchange(endpoint: .session, payload: command1)
        } catch PowerBaseBLELinkError.rejected {
            // The board checked the proof and refused it.
            throw PowerBaseBLEClientError.authenticationFailed
        } catch {
            throw PowerBaseBLEClientError.handshakeInterrupted(Self.linkError(error))
        }

        do {
            try session.finish(response1: response1)
        } catch {
            throw Self.handshakeError(error)
        }
        guard !closed else { throw PowerBaseBLEClientError.noSession }
        handshake = session
    }

    // MARK: - Inside the session

    /// The board's identity and state. With `issueChallenge` the answer carries a fresh challenge
    /// for one `pb-start` in this session; with `requestID` it says what became of that request.
    public func status(issueChallenge: Bool = false, requestID: PowerBaseBLERequestID? = nil) async throws -> PowerBaseBLEStatus {
        let request = PowerBaseBLECodec.statusRequest(issueChallenge: issueChallenge, requestID: requestID)
        let response = try await secureExchange(endpoint: .status, plaintext: request)
        let status: PowerBaseBLEStatus
        do {
            status = try PowerBaseBLECodec.decodeStatusResponse(response)
        } catch PowerBaseBLECodecError.refused(let code) {
            discardSession()
            throw PowerBaseBLEClientError.refusedByBoard(code)
        } catch {
            discardSession()
            throw PowerBaseBLEClientError.malformedResponse(Self.codecError(error))
        }
        // The answer must fit the question.
        if !issueChallenge, status.challenge != nil {
            discardSession()
            throw PowerBaseBLEClientError.malformedResponse(.field("challenge"))
        }
        if requestID == nil, status.flags.contains(.requestMatch) {
            discardSession()
            throw PowerBaseBLEClientError.malformedResponse(.field("phase"))
        }
        return status
    }

    /// Hands the PSKd over. `.accepted` and `.duplicate` mean the board took the request -- not
    /// that a Joiner succeeded, and not that the hub heard anything.
    public func start(
        target: PowerBaseBLEEUI64, requestID: PowerBaseBLERequestID, challenge: PowerBaseBLEChallenge, pskd: String
    ) async throws -> PowerBaseBLECode {
        guard let request = PowerBaseBLECodec.startRequest(target: target, requestID: requestID, challenge: challenge, pskd: pskd) else {
            throw PowerBaseBLEClientError.invalidInput("pskd")
        }
        let response = try await secureExchange(endpoint: .start, plaintext: request)
        do {
            return try PowerBaseBLECodec.decodeStartResponse(response)
        } catch {
            discardSession()
            throw PowerBaseBLEClientError.malformedResponse(Self.codecError(error))
        }
    }

    /// Hands the PSKd over together with the Linux bridge endpoint (message 0x04). Only for a board
    /// that listed `bridge_endpoint_v1`: for any other board nothing is sent and this throws
    /// `.invalidInput("capability")` -- the first start message is never sent in its place.
    /// `.accepted` and `.duplicate` mean what they mean for the first start: the board took the
    /// request, nothing more.
    public func start(
        target: PowerBaseBLEEUI64, requestID: PowerBaseBLERequestID, challenge: PowerBaseBLEChallenge, pskd: String,
        endpoint: PowerBaseBLEBridgeEndpoint
    ) async throws -> PowerBaseBLECode {
        guard boardCapabilities.contains(.bridgeEndpointV1) else { throw PowerBaseBLEClientError.invalidInput("capability") }
        guard let request = PowerBaseBLECodec.startRequest(
            target: target, requestID: requestID, challenge: challenge, pskd: pskd, endpoint: endpoint
        ) else {
            throw PowerBaseBLEClientError.invalidInput("pskd")
        }
        let response = try await secureExchange(endpoint: .start, plaintext: request)
        do {
            return try PowerBaseBLECodec.decodeStartWithEndpointResponse(response)
        } catch {
            discardSession()
            throw PowerBaseBLEClientError.malformedResponse(Self.codecError(error))
        }
    }

    /// Asks the board to stop the attempt this client started, named by its request id.
    public func cancel(target: PowerBaseBLEEUI64, requestID: PowerBaseBLERequestID) async throws -> PowerBaseBLECode {
        let request = PowerBaseBLECodec.cancelRequest(target: target, requestID: requestID)
        let response = try await secureExchange(endpoint: .cancel, plaintext: request)
        do {
            return try PowerBaseBLECodec.decodeCancelResponse(response)
        } catch {
            discardSession()
            throw PowerBaseBLEClientError.malformedResponse(Self.codecError(error))
        }
    }

    /// Drops the session keys this type holds and ends the connection. The vendored Security 2
    /// object and Swift's own copies of the setup code are released, not overwritten.
    public func close() async {
        closed = true
        handshake = nil
        await link.close()
    }

    // MARK: - One request, one answer

    private func secureExchange(endpoint: PowerBaseBLEProtocol.Endpoint, plaintext: Data) async throws -> Data {
        await acquire()
        defer { release() }
        guard !closed, let session = handshake, session.isEstablished else { throw PowerBaseBLEClientError.noSession }
        guard let request = session.encrypt(plaintext) else {
            discardSession()
            throw PowerBaseBLEClientError.noSession
        }
        let response: Data
        do {
            response = try await link.exchange(endpoint: endpoint, payload: request)
        } catch {
            // Sent or not, answered or not: this side can't know which counter the board is at.
            // The ciphertext is never sent again.
            discardSession()
            throw PowerBaseBLEClientError.requestFailed(Self.linkError(error))
        }
        // Closed while the answer was on its way: the answer belongs to nobody.
        guard !closed, handshake === session else { throw PowerBaseBLEClientError.noSession }
        guard let answer = session.decrypt(response) else {
            discardSession()
            throw PowerBaseBLEClientError.decryptionFailed
        }
        return answer
    }

    private func discardSession() {
        handshake = nil
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the turn straight to the longest waiting caller, so calls run in arrival order.
    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    private static func linkError(_ error: Error) -> PowerBaseBLELinkError {
        if let error = error as? PowerBaseBLELinkError { return error }
        if error is CancellationError { return .cancelled }
        return .failed("link")
    }

    private static func codecError(_ error: Error) -> PowerBaseBLECodecError {
        error as? PowerBaseBLECodecError ?? .field("response")
    }

    private static func handshakeError(_ error: Error) -> PowerBaseBLEClientError {
        switch error as? Security2Handshake.Failure {
        case .deviceProofMismatch?: return .boardProofMismatch
        case .securityVersionMismatch?: return .handshakeMalformed("sec_ver")
        case .deviceStatus?: return .handshakeMalformed("status")
        case .invalidDevicePublicKey?: return .handshakeMalformed("device_pubkey")
        case .malformed(let field)?: return .handshakeMalformed(field)
        case .wrongState?, nil: return .handshakeMalformed("state")
        }
    }
}
#endif
