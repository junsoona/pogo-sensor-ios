import Foundation
import CryptoKit

/// Real PogoHome hardware identifies modules with short hex strings (e.g.
/// `"744dbdfffe65d357"`), not RFC 4122 UUIDs. The rest of the app (`SensorModule.id`,
/// `NavigationLink(value: UUID)`, `Identifiable`) is built around Foundation's `UUID`, so
/// this type validates the wire identifier and deterministically derives a stable `UUID`
/// from it — the same raw identifier always maps to the same `UUID`, across launches and
/// across mock/live sources, without the API needing to change its own ID format.
nonisolated enum ModuleIdentity {
    /// A wire identifier is valid if it's non-empty, contains only hex digits, and has an
    /// even number of characters (so it cleanly represents whole bytes).
    static func isValidRawIdentifier(_ raw: String) -> Bool {
        !raw.isEmpty && raw.count.isMultiple(of: 2) && raw.allSatisfy(\.isHexDigit)
    }

    /// Derives a stable `UUID` for a raw wire identifier via SHA-256, namespaced so it
    /// can never collide with UUIDs derived for an unrelated purpose elsewhere in the app.
    static func stableUUID(forRawIdentifier raw: String) -> UUID {
        let digest = SHA256.hash(data: Data("pogohome.module.v1:\(raw.lowercased())".utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
