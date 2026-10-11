import Foundation

/// Why a string read from a QR code is not a Power Base setup QR code. Never carries the string,
/// or any part of it.
public enum PowerBaseSetupQRError: Error, Equatable, Sendable, CaseIterable {
    /// Something else: a link, another product's code, a setup code on its own.
    case notPowerBaseCode
    /// A Power Base setup QR code of a version this code does not read.
    case unsupportedVersion
    /// The right beginning and version, but not the one shape that version has.
    case malformed
    case invalidEUI64
    case invalidSetupCode
}

/// What a Power Base setup QR code says (firmware repository, docs/power-base.md "QR 설정 코드"):
///
///     POGO-PB:1:<eui64>:<setup_code>
///
/// 53 bytes of ASCII and nothing else: the EUI-64 as 16 lower-case hex digits (not all zero) and
/// the setup code as 26 characters of RFC 4648 base32, upper case, without padding, that decode
/// to exactly 16 bytes and encode back to the same 26 characters.
///
/// This is stricter than `PowerBaseSetupCode.normalized`, which serves typing: here nothing is
/// trimmed, raised, replaced or searched for. A string either is such a code, byte for byte, or
/// it is refused.
///
/// The EUI-64 says which board the code was made for. It proves nothing: the board is
/// authenticated with the setup code (Security 2) and then asked for its own EUI-64, as before.
public struct PowerBaseSetupQRPayload: Equatable, Sendable {
    public static let formatVersion = 1
    public static let encodedLength = 53

    public let eui64: PowerBaseBLEEUI64
    /// 26 characters, as `PowerBaseSetupCode.normalized` would return them.
    public let setupCode: String

    private static let prefix = Array("POGO-PB:".utf8)
    private static let separator = UInt8(ascii: ":")
    private static let euiRange = 10..<26
    private static let codeRange = 27..<53

    /// Reads `text` as it came out of the QR code.
    public init(parsing text: String) throws {
        // Bytes, not characters: two strings Swift calls equal can be different bytes.
        let bytes = Array(text.utf8)
        guard bytes.count >= Self.prefix.count, Array(bytes[..<Self.prefix.count]) == Self.prefix else {
            throw PowerBaseSetupQRError.notPowerBaseCode
        }
        let afterPrefix = bytes[Self.prefix.count...]
        guard let versionEnd = afterPrefix.firstIndex(of: Self.separator) else { throw PowerBaseSetupQRError.malformed }
        let version = afterPrefix[..<versionEnd]
        guard !version.isEmpty, version.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else {
            throw PowerBaseSetupQRError.malformed
        }
        guard Array(version) == [UInt8(ascii: "1")] else { throw PowerBaseSetupQRError.unsupportedVersion }
        guard bytes.count == Self.encodedLength, bytes[Self.euiRange.upperBound] == Self.separator else {
            throw PowerBaseSetupQRError.malformed
        }

        var eui = Data(capacity: 8)
        var high: UInt8?
        for byte in bytes[Self.euiRange] {
            let nibble: UInt8
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): nibble = byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): nibble = byte - UInt8(ascii: "a") + 10
            default: throw PowerBaseSetupQRError.invalidEUI64
            }
            if let first = high {
                eui.append(first << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        // All zero is refused there.
        guard let eui64 = PowerBaseBLEEUI64(bytes: eui) else { throw PowerBaseSetupQRError.invalidEUI64 }

        let code = Array(bytes[Self.codeRange])
        guard let secret = Self.base32Decoded(code), secret.count == 16, Self.base32Encoded(secret) == code else {
            throw PowerBaseSetupQRError.invalidSetupCode
        }
        self.eui64 = eui64
        self.setupCode = String(decoding: code, as: UTF8.self)
    }

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)

    /// The bytes of unpadded upper-case base32; `nil` for any other character. Bits left over at
    /// the end are dropped here and caught by encoding the result again.
    private static func base32Decoded(_ characters: [UInt8]) -> [UInt8]? {
        var output: [UInt8] = []
        var buffer: UInt32 = 0
        var bits = 0
        for character in characters {
            let value: UInt32
            switch character {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): value = UInt32(character - UInt8(ascii: "A"))
            case UInt8(ascii: "2")...UInt8(ascii: "7"): value = UInt32(character - UInt8(ascii: "2")) + 26
            default: return nil
            }
            buffer = (buffer << 5 | value) & 0xFFF
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8(truncatingIfNeeded: buffer >> UInt32(bits)))
            }
        }
        return output
    }

    private static func base32Encoded(_ bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        var buffer: UInt32 = 0
        var bits = 0
        for byte in bytes {
            buffer = (buffer << 8 | UInt32(byte)) & 0x1FFF
            bits += 8
            while bits >= 5 {
                bits -= 5
                output.append(alphabet[Int(buffer >> UInt32(bits) & 0x1F)])
            }
        }
        if bits > 0 { output.append(alphabet[Int(buffer << UInt32(5 - bits) & 0x1F)]) }
        return output
    }
}

// Holds a setup code: whatever prints or inspects it by accident shows nothing.
extension PowerBaseSetupQRPayload: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "PowerBaseSetupQRPayload(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
