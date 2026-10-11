// PogoHome addition -- not part of ESPProvision. The only public surface of this module: a thin
// wrapper that drives the vendored `ESPSecurity2` (Espressif's SRP-6a + AES-256-GCM client) and
// checks the shape of the device's handshake messages before handing them to it. It adds no
// cryptography: every key, proof and nonce is computed by the vendored code.
import Foundation

/// One Security 2 session with one connection. Single use: after any failure, make a new one on a
/// new connection. Not thread safe; its owner serialises the calls.
public final class Security2Handshake {
    public enum Failure: Error, Equatable, Sendable {
        /// The device answered with another security scheme than Security 2.
        case securityVersionMismatch
        /// The message isn't the expected step of the handshake, or a field has an impossible size.
        case malformed(String)
        /// The device reported a status other than success.
        case deviceStatus
        /// The device's public key is unusable (B mod N == 0).
        case invalidDevicePublicKey
        /// The device's proof doesn't match: it doesn't hold the verifier for this user and
        /// password. Nothing it says afterwards may be trusted.
        case deviceProofMismatch
        /// The steps were called out of order.
        case wrongState
    }

    /// ESP-IDF's `PUBLIC_KEY_LEN`: the only client public key size security2.c accepts.
    public static let publicKeyLength = 384
    /// AES-GCM: the tag every encrypted message ends with, and the device nonce's size.
    public static let tagLength = 16
    static let nonceLength = 12
    static let proofLength = 64

    private enum Step { case start, sentCommand0, sentCommand1, established, failed }

    private let security: ESPSecurity2
    private var step = Step.start

    /// `srpPrivateKey` is for tests only (a key whose public key starts with a zero byte); `nil`
    /// lets the vendored client draw a fresh random one.
    public init(username: String, password: String, srpPrivateKey: Data? = nil) {
        // `useCounterFlag`: the AES-GCM IV is the device nonce's first 8 bytes plus a big-endian
        // counter both sides advance after every encrypt and decrypt (`sec_patch_ver` 1).
        security = ESPSecurity2(username: username, password: password, useCounterFlag: true, srpPrivateKey: srpPrivateKey)
    }

    public var isEstablished: Bool { step == .established }

    /// The first message: the user name and the client's public key, always 384 bytes.
    public func command0() throws -> Data {
        guard step == .start else { throw Failure.wrongState }
        step = .failed
        guard let request = try security.getNextRequestInSession(data: nil) else { throw Failure.wrongState }
        guard Self.clientPublicKey(inCommand0: request)?.count == Self.publicKeyLength else {
            throw Failure.malformed("client_pubkey")
        }
        step = .sentCommand0
        return request
    }

    /// Takes the device's salt and public key, returns the client's proof.
    public func command1(response0: Data) throws -> Data {
        guard step == .sentCommand0 else { throw Failure.wrongState }
        step = .failed
        let message = try Self.sessionData(response0)
        guard message.sec2.msg == .s2SessionResponse0, case .sr0? = message.sec2.payload else {
            throw Failure.malformed("response0")
        }
        guard message.sec2.sr0.status == .success else { throw Failure.deviceStatus }
        let publicKey = message.sec2.sr0.devicePubkey
        guard !publicKey.isEmpty, publicKey.count <= Self.publicKeyLength else { throw Failure.malformed("device_pubkey") }
        guard !message.sec2.sr0.deviceSalt.isEmpty, message.sec2.sr0.deviceSalt.count <= 64 else {
            throw Failure.malformed("device_salt")
        }
        let request: Data?
        do {
            request = try security.getNextRequestInSession(data: response0)
        } catch AuthenticationFailure.invalidPublicKey {
            throw Failure.invalidDevicePublicKey
        } catch {
            throw Failure.malformed("response0")
        }
        guard let request else { throw Failure.wrongState }
        step = .sentCommand1
        return request
    }

    /// Checks the device's proof. Only after this may `encrypt`/`decrypt` be used.
    public func finish(response1: Data) throws {
        guard step == .sentCommand1 else { throw Failure.wrongState }
        step = .failed
        let message = try Self.sessionData(response1)
        guard message.sec2.msg == .s2SessionResponse1, case .sr1? = message.sec2.payload else {
            throw Failure.malformed("response1")
        }
        guard message.sec2.sr1.status == .success else { throw Failure.deviceStatus }
        guard message.sec2.sr1.deviceProof.count == Self.proofLength else { throw Failure.malformed("device_proof") }
        guard message.sec2.sr1.deviceNonce.count == Self.nonceLength else { throw Failure.malformed("device_nonce") }
        do {
            guard try security.getNextRequestInSession(data: response1) == nil else { throw Failure.wrongState }
        } catch AuthenticationFailure.keyProofMismatch {
            throw Failure.deviceProofMismatch
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.deviceProofMismatch
        }
        guard security.sessionKey != nil else { throw Failure.wrongState }
        step = .established
    }

    /// `ciphertext ‖ 16-byte tag`, or `nil` when there is no session or encryption failed. Advances
    /// the session's counter.
    public func encrypt(_ plaintext: Data) -> Data? {
        guard step == .established else { return nil }
        return security.encrypt(data: plaintext)
    }

    /// The plaintext, or `nil` when there is no session or the tag doesn't verify. Advances the
    /// session's counter only on success -- after a `nil` the session is out of step and must be
    /// discarded.
    public func decrypt(_ message: Data) -> Data? {
        // The vendored code slices off the last 16 bytes without checking that they exist.
        guard step == .established, message.count >= Self.tagLength else { return nil }
        return security.decrypt(data: message)
    }

    private static func sessionData(_ data: Data) throws -> SessionData {
        guard let message = try? SessionData(serializedData: data) else { throw Failure.malformed("protobuf") }
        guard message.secVer == .secScheme2, case .sec2? = message.proto else { throw Failure.securityVersionMismatch }
        return message
    }

    // MARK: - For tests (reached with `@testable import`)

    static func clientPublicKey(inCommand0 request: Data) -> Data? {
        guard let message = try? SessionData(serializedData: request), message.secVer == .secScheme2,
              message.sec2.msg == .s2SessionCommand0 else { return nil }
        return message.sec2.sc0.clientPubkey
    }

    /// A Command0 with any public key bytes -- what upstream sends when the key starts with zero.
    static func command0(username: String, publicKey: Data) throws -> Data {
        var message = SessionData()
        message.secVer = .secScheme2
        message.sec2.msg = .s2SessionCommand0
        message.sec2.sc0.clientPubkey = publicKey
        message.sec2.sc0.clientUsername = Data(username.utf8)
        return try message.serializedData()
    }

    /// `response1` with one bit of the device's proof flipped.
    static func tamperingDeviceProof(_ response1: Data) throws -> Data {
        var message = try SessionData(serializedData: response1)
        var proof = message.sec2.sr1.deviceProof
        guard !proof.isEmpty else { return response1 }
        proof[proof.startIndex] ^= 0x01
        message.sec2.sr1.deviceProof = proof
        return try message.serializedData()
    }
}
