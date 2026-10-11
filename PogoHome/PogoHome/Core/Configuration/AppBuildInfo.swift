import Foundation

/// What this build of the app is (docs/versioning.md).
///
/// Three different things, kept apart:
/// - **Product version** (`CFBundleShortVersionString`, e.g. `1.0.0`) and **build number**
///   (`CFBundleVersion`, e.g. `2`): plain numbers from `Config/Version.xcconfig`, the same for the
///   app, its widgets and the Watch app.
/// - **Build kind**: `development` or `release`. A release is a build made in release mode from a
///   clean, committed source tree -- not simply the Release compiler configuration.
/// - **Source identity**: the Git commit, whether the tree had uncommitted changes, and a
///   fingerprint of the sources, which tells two different uncommitted trees on the same commit
///   apart.
///
/// The last two are only known for a build made with `Scripts/pogo_app_version.py build`. Any
/// other build says "unknown" for them; nothing is guessed. None of this is sent anywhere, and
/// nothing in the app decides what a hub or a board supports by comparing version strings.
nonisolated struct AppBuildInfo: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case development
        case release
        case unknown
    }

    /// `CFBundleShortVersionString`.
    var version: String
    /// `CFBundleVersion`.
    var buildNumber: String
    var kind: Kind
    /// The full commit SHA (40 hex digits), or `nil` when it is not known.
    var commit: String?
    /// Whether the sources had uncommitted changes; `nil` when not known.
    var isDirty: Bool?
    /// SHA-256 of the sources (64 hex digits), or `nil` when not known.
    var sourceFingerprint: String?
    /// `<commit12>[+dirty].<fingerprint12>`, or `nil` when not known.
    var buildID: String?

    /// "1.0.0 (2)".
    var versionAndBuild: String { "\(version) (\(buildNumber))" }

    /// Whether the source identity is known at all.
    var hasSourceIdentity: Bool { commit != nil || sourceFingerprint != nil }

    static let unknownValue = "unknown"

    /// From an `Info.plist` dictionary. A missing or malformed value is "not known": it is never
    /// replaced by a default that looks like a real one.
    init(infoDictionary: [String: Any]?) {
        let info = infoDictionary ?? [:]
        version = (info["CFBundleShortVersionString"] as? String) ?? Self.unknownValue
        buildNumber = (info["CFBundleVersion"] as? String) ?? Self.unknownValue
        kind = Kind(rawValue: (info["PogoBuildKind"] as? String) ?? "") ?? .unknown
        commit = Self.hex(info["PogoBuildCommit"], count: 40)
        sourceFingerprint = Self.hex(info["PogoBuildSourceFingerprint"], count: 64)
        switch info["PogoBuildDirty"] as? String {
        case "true": isDirty = true
        case "false": isDirty = false
        default: isDirty = nil
        }
        let id = info["PogoBuildID"] as? String
        buildID = Self.isBuildID(id) ? id : nil
    }

    static let current = AppBuildInfo(infoDictionary: Bundle.main.infoDictionary)

    /// Exactly `count` lower-case hex digits, or nothing.
    private static func hex(_ value: Any?, count: Int) -> String? {
        guard let text = value as? String, text.utf8.count == count,
              text.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else { return nil }
        return text
    }

    /// `<12 hex or "unknown">[+dirty].<12 hex>`.
    private static func isBuildID(_ value: String?) -> Bool {
        guard let value, value != unknownValue, value.utf8.count <= 31 else { return false }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, hex(String(parts[1]), count: 12) != nil else { return false }
        var head = String(parts[0])
        if head.hasSuffix("+dirty") { head.removeLast(6) }
        return head == unknownValue || hex(head, count: 12) != nil
    }
}
