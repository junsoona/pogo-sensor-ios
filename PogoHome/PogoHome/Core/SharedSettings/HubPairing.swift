import CryptoKit
import Foundation
import Security

/// The one-time code the hub operator creates with `pogohome-hubctl pair` (12 characters, shown as
/// `XXXX-XXXX-XXXX`). Typed forgivingly: any case, spaces and hyphens, `O` for `0`, `I`/`L` for `1`
/// — the same rules as the hub's `NormalizePairingCode`.
nonisolated enum HubPairingCode {
    static let length = 12
    private static let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// The 12 code characters, or `nil` when the input can't be a code.
    static func normalized(_ input: String) -> String? {
        var code = ""
        for character in input.uppercased() {
            if character == "-" || character == " " { continue }
            let mapped: Character = switch character {
            case "O": "0"
            case "I", "L": "1"
            default: character
            }
            guard alphabet.contains(mapped) else { return nil }
            code.append(mapped)
            if code.count > length { return nil }
        }
        return code.count == length ? code : nil
    }
}

/// The pairing proofs (hub: `device_auth.hpp`). The code itself is never sent: the app proves it
/// knows the code with an HMAC over the hub's id, the SHA-256 of the TLS certificate it actually
/// received, a fresh nonce and its name. The hub recomputes it with its own certificate, so an
/// impostor between the two (with another certificate) gets nothing. The hub's answer proves the
/// hub knows the code too; only then does the app keep the token and pin the certificate.
nonisolated enum HubPairingProof {
    private static let protocolLabel = "pogohome-pair-v1"

    static func client(code: String, hubID: String, certificateSHA256: String, clientNonce: String, deviceName: String) -> String {
        hmac(code: code, message: [protocolLabel, "client", hubID, certificateSHA256, clientNonce, sha256Hex(Data(deviceName.utf8))])
    }

    static func server(code: String, hubID: String, certificateSHA256: String, clientNonce: String, deviceID: String, token: String) -> String {
        hmac(code: code, message: [protocolLabel, "server", hubID, certificateSHA256, clientNonce, deviceID, sha256Hex(Data(token.utf8))])
    }

    /// 16 random bytes as lowercase hex.
    static func makeNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return hex(bytes)
    }

    static func sha256Hex(_ data: Data) -> String {
        hex(Array(SHA256.hash(data: data)))
    }

    /// Equal without revealing where two proofs first differ.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }

    private static func hmac(code: String, message parts: [String]) -> String {
        let key = SymmetricKey(data: Data(code.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(parts.joined(separator: "\n").utf8), using: key)
        return hex(Array(mac))
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum HubCertificate {
    /// SHA-256 of the certificate's DER encoding — the value the hub logs, `pogohome-hubctl
    /// fingerprint` prints, and devices pin.
    static func sha256Hex(of certificate: SecCertificate) -> String {
        HubPairingProof.sha256Hex(SecCertificateCopyData(certificate) as Data)
    }

    /// The leaf certificate a TLS server presented.
    static func leaf(of trust: SecTrust) -> SecCertificate? {
        (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
    }

    /// `XXXX XXXX …` groups of the first 16 hex digits, for showing a pinned certificate.
    static func shortFingerprint(_ sha256: String) -> String {
        let prefix = Array(sha256.prefix(16).uppercased())
        return stride(from: 0, to: prefix.count, by: 4).map { String(prefix[$0..<min($0 + 4, prefix.count)]) }.joined(separator: " ")
    }
}
