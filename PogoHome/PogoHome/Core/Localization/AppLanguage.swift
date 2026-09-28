import Foundation

/// One of the app's shipped UI languages, used to resolve *app-provided* names (default room
/// names, icon suggestions, the default home name) into display text.
///
/// Plain UI copy uses `String(localized:)`/SwiftUI's `LocalizedStringKey` and always follows
/// the language iOS picked for the app. Names go through this type instead so the
/// storage/overlay logic that decides between "user-typed, shown verbatim" and "app default,
/// shown in the current language" can be unit-tested in every language regardless of the
/// simulator's own language setting.
nonisolated struct AppLanguage: Hashable, Sendable {
    /// An `.lproj` name in the app bundle: `ko`, `en` or `es`.
    let identifier: String

    init(_ identifier: String) {
        self.identifier = identifier
    }

    static let korean = AppLanguage("ko")
    static let english = AppLanguage("en")
    static let spanish = AppLanguage("es")
    static let supported: [AppLanguage] = [.korean, .english, .spanish]

    /// The language the app UI is actually shown in: the first of the user's per-app/system
    /// preferred languages the bundle ships, else the development language (Korean). iOS
    /// relaunches the app when this changes, so reading it once per launch is enough.
    static var current: AppLanguage {
        AppLanguage(Bundle.main.preferredLocalizations.first ?? korean.identifier)
    }

    var locale: Locale { Locale(identifier: identifier) }

    /// The compiled string tables for exactly this language. Falls back to the main bundle
    /// (i.e. the current UI language) if the `.lproj` is somehow missing.
    private var bundle: Bundle {
        Bundle.main.url(forResource: identifier, withExtension: "lproj").flatMap(Bundle.init(url:)) ?? .main
    }

    /// `resource`'s key looked up in this language's table. `resource` is a literal at the
    /// call site so Xcode's string extraction still sees every key.
    ///
    /// A key missing from the table resolves to the key itself, which is the Korean source
    /// text — the compiled Korean table only lists keys whose value differs from the key, so
    /// this is what makes `.korean` work, and it never falls back to the *current* language.
    func string(_ resource: LocalizedStringResource) -> String {
        Self.native(bundle.localizedString(forKey: resource.key, value: resource.key, table: resource.table))
    }

    /// A localized format string (looked up by `key`, e.g. `"%@ %lld"`), filled in with this
    /// language's number formatting.
    func format(_ key: String, _ arguments: any CVarArg...) -> String {
        let format = bundle.localizedString(forKey: key, value: key, table: nil)
        return Self.native(String(format: format, locale: locale, arguments: arguments))
    }

    /// These names are compared and sorted (duplicate checks, suggestion numbering, lists).
    /// A bridged `NSString` straight from `Bundle`/`String(format:)` was observed to order
    /// wrongly against native strings on iOS 27 (`"거실" < "거실 2"` evaluating to false), so
    /// every name leaves here as a native Swift string.
    private static func native(_ string: String) -> String {
        var copy = string
        copy.makeContiguousUTF8()
        return copy
    }
}
