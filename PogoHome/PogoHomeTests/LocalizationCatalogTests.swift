import XCTest
@testable import PogoHome

/// Checks the *compiled* string tables in the app bundle, so a missing or broken translation
/// fails here rather than showing up as Korean text (or a crash-prone format string) in the
/// English or Spanish UI.
final class LocalizationCatalogTests: XCTestCase {
    private func table(_ language: String, _ file: String) -> [String: Any] {
        guard
            let url = Bundle.main.url(forResource: file, withExtension: nil, subdirectory: nil, localization: language),
            let dictionary = NSDictionary(contentsOf: url) as? [String: Any]
        else { return [:] }
        return dictionary
    }

    private func strings(_ language: String) -> [String: String] {
        table(language, "Localizable.strings") as? [String: String] ?? [:]
    }

    /// Every plural form of every `.stringsdict` entry.
    private func pluralForms(_ language: String) -> [String: [String]] {
        table(language, "Localizable.stringsdict").mapValues { entry in
            let rules = (entry as? [String: Any])?.values.compactMap { $0 as? [String: Any] } ?? []
            return rules.flatMap { rule in
                rule.filter { !$0.key.hasPrefix("NSString") }.compactMap { $0.value as? String }
            }
        }
    }

    /// The format arguments a string consumes, in order, positional (`%2$@`) or not.
    private func placeholders(_ format: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "%(?:(\\d+)\\$)?(lld|ld|d|@|lf|f)")
        let matches = regex.matches(in: format, range: NSRange(format.startIndex..., in: format))
        let parsed: [(Int?, String)] = matches.map { match in
            let position = Range(match.range(at: 1), in: format).flatMap { Int(format[$0]) }
            return (position, String(format[Range(match.range(at: 2), in: format)!]))
        }
        var sequential = 0
        return parsed.map { position, type in
            sequential += 1
            return "\(position ?? sequential):\(type)"
        }.sorted()
    }

    func testAppShipsKoreanEnglishAndSpanishWithKoreanAsDevelopmentLanguage() {
        XCTAssertEqual(Bundle.main.developmentLocalization, "ko")
        XCTAssertTrue(Set(["ko", "en", "es"]).isSubset(of: Set(Bundle.main.localizations)), "\(Bundle.main.localizations)")
    }

    func testEnglishAndSpanishTranslateEveryKey() {
        let english = Set(strings("en").keys).union(pluralForms("en").keys)
        let spanish = Set(strings("es").keys).union(pluralForms("es").keys)
        XCTAssertGreaterThan(english.count, 150)
        XCTAssertEqual(english.subtracting(spanish), [], "keys translated to English but not Spanish")
        XCTAssertEqual(spanish.subtracting(english), [], "keys translated to Spanish but not English")
    }

    /// A translation must consume the same arguments as the Korean source, or formatting
    /// would print garbage or crash.
    func testTranslationsKeepTheSourcePlaceholders() {
        let korean = strings("ko")
        let koreanPlurals = pluralForms("ko")
        for language in ["en", "es"] {
            for (key, value) in strings(language) {
                let source = korean[key] ?? key
                XCTAssertEqual(placeholders(value), placeholders(source), "\(language): \(key) → \(value)")
            }
            for (key, forms) in pluralForms(language) {
                let source = korean[key] ?? koreanPlurals[key]?.first ?? key
                for form in forms {
                    XCTAssertEqual(placeholders(form), placeholders(source), "\(language): \(key) → \(form)")
                }
            }
        }
    }

    func testPluralsAgreeWithTheCount() {
        func format(_ key: String, _ language: String, _ count: Int) -> String {
            let bundle = Bundle(url: Bundle.main.url(forResource: language, withExtension: "lproj")!)!
            // Plural rules follow the formatting locale, so format in the table's own language.
            return String(format: bundle.localizedString(forKey: key, value: nil, table: nil), locale: Locale(identifier: language), count)
        }
        XCTAssertEqual(format("rooms.count", "en", 1), "1 room")
        XCTAssertEqual(format("rooms.count", "en", 3), "3 rooms")
        XCTAssertEqual(format("rooms.count", "es", 1), "1 habitación")
        XCTAssertEqual(format("rooms.count", "es", 2), "2 habitaciones")
        XCTAssertEqual(format("rooms.count", "ko", 2), "2개")
        XCTAssertEqual(format("오프라인 기기 %lld개", "en", 1), "1 offline device")
        XCTAssertEqual(format("오프라인 기기 %lld개", "en", 2), "2 offline devices")
        XCTAssertEqual(format("오프라인 기기 %lld개", "ko", 2), "오프라인 기기 2개")
    }

    func testSensorValuesUseTheLocaleDecimalSeparator() {
        XCTAssertEqual(SensorKind.temperature.formattedValue(23.4, locale: Locale(identifier: "en_US")), "23.4 °C")
        XCTAssertEqual(SensorKind.temperature.formattedValue(23.4, locale: Locale(identifier: "es_ES")), "23,4 °C")
        XCTAssertEqual(SensorKind.pm2_5.formattedValue(7, locale: Locale(identifier: "ko_KR")), "7.0 µg/m³")
    }
}
