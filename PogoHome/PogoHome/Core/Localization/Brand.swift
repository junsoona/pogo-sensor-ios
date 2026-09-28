import Foundation

/// The brand. A proper noun, never translated: Hangul in Korean and its romanization “Jogakbo”
/// in every other language, so it reads naturally everywhere.
nonisolated enum Brand {
    /// The sensors' brand and the short source label next to their status (widgets, Watch):
    /// “조각보” / “Jogakbo”, as in “조각보 센서”.
    static var name: String {
        String(localized: "brand.name", defaultValue: "조각보", comment: "The sensor brand and the short label naming them as a source, a proper noun: 조각보 in Korean, the romanization Jogakbo in other languages; never translated")
    }

    /// The app's own name: “조각보 홈” / “Jogakbo Home”. Matches `CFBundleDisplayName`.
    static var appName: String {
        String(localized: "brand.appName", defaultValue: "조각보 홈", comment: "The app's name, a proper noun: 조각보 홈 in Korean, Jogakbo Home in other languages; never translated")
    }
}
