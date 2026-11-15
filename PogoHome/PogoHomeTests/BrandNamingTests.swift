import UIKit
import XCTest
@testable import PogoHome

/// The app is shown as “조각보 홈” and its sensors as “조각보 센서” in Korean, and by the brand's
/// romanization — “Jogakbo Home”, “Jogakbo sensors” (a proper noun, never translated) — in
/// English and Spanish. Every identifier that ties existing data and devices together keeps its
/// old value, and names the user saved are never rewritten.
final class BrandNamingTests: XCTestCase {
    private static let languages = ["ko", "en", "es"]
    /// The sensor brand.
    private static let brand = ["ko": "조각보", "en": "Jogakbo", "es": "Jogakbo"]
    /// The app's name.
    private static let appName = ["ko": "조각보 홈", "en": "Jogakbo Home", "es": "Jogakbo Home"]

    private func table(_ language: String, _ file: String) -> [String: String] {
        guard
            let url = Bundle.main.url(forResource: file, withExtension: nil, subdirectory: nil, localization: language),
            let dictionary = NSDictionary(contentsOf: url) as? [String: Any]
        else { return [:] }
        return dictionary.compactMapValues { $0 as? String }
    }

    /// Every form of every string the app shows, per language (plural forms included).
    private func shownStrings(_ language: String) -> [String: [String]] {
        var result = table(language, "Localizable.strings").mapValues { [$0] }
        if
            let url = Bundle.main.url(forResource: "Localizable.stringsdict", withExtension: nil, subdirectory: nil, localization: language),
            let plurals = NSDictionary(contentsOf: url) as? [String: [String: Any]]
        {
            for (key, entry) in plurals {
                let forms = entry.values.compactMap { $0 as? [String: Any] }.flatMap { rule in
                    rule.filter { !$0.key.hasPrefix("NSString") }.compactMap { $0.value as? String }
                }
                result[key, default: []] += forms
            }
        }
        return result
    }

    // MARK: - Brand

    func testTheAppIsNamedJogakboHomeInEveryLanguage() throws {
        let shown = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        XCTAssertTrue(["조각보 홈", "Jogakbo Home"].contains(shown), shown)
        for language in Self.languages {
            let brand = try XCTUnwrap(Self.brand[language])
            let appName = try XCTUnwrap(Self.appName[language])
            let names = table(language, "InfoPlist.strings")
            XCTAssertEqual(names["CFBundleDisplayName"], appName, language)
            XCTAssertEqual(names["CFBundleName"], appName, "\(language): the Mac menu bar and About window")
            for key in ["NSHomeKitUsageDescription", "NSLocalNetworkUsageDescription"] {
                let text = names[key] ?? ""
                XCTAssertTrue(text.contains(appName), "\(language) \(key): \(text)")
                XCTAssertFalse(text.contains("PogoHome"), "\(language) \(key): \(text)")
            }
            let strings = table(language, "Localizable.strings")
            XCTAssertEqual(strings["brand.appName"], appName, "\(language): the app's name (Watch title)")
            XCTAssertEqual(strings["brand.name"], brand, "\(language): the sensor brand label (widgets, Watch)")
        }
    }

    /// Wherever the Korean text names the app (“조각보 홈”), English and Spanish name it
    /// “Jogakbo Home” — and never where the Korean means the sensors or the cloth.
    func testTheAppNameAndTheSensorBrandStayApart() throws {
        let english = table("en", "Localizable.strings")
        XCTAssertGreaterThan(english.keys.filter { $0.contains("조각보 홈") }.count, 20)
        for language in ["en", "es"] {
            for (key, forms) in shownStrings(language) {
                let namesApp = key.contains("조각보 홈") || key == "brand.appName"
                for text in forms {
                    XCTAssertEqual(text.contains("Jogakbo Home"), namesApp, "\(language): \(key) → \(text)")
                }
            }
        }
        XCTAssertEqual(english["조각보 센서"], "Jogakbo Sensors")
        XCTAssertEqual(table("es", "Localizable.strings")["조각보 센서"], "Sensores Jogakbo")
    }

    /// The Rooms tab calls the user's own rooms “내 방”; Apple Home rooms stay a separate section.
    func testTheUsersRoomsAreCalledMyRooms() {
        XCTAssertEqual(table("en", "Localizable.strings")["내 방"], "My Rooms")
        XCTAssertEqual(table("es", "Localizable.strings")["내 방"], "Mis habitaciones")
        for language in ["en", "es"] {
            XCTAssertNil(table(language, "Localizable.strings")["조각보 방"], "\(language): the old section title is gone")
        }
    }

    /// No shown text still names the old app or sensor brand, and English and Spanish readers
    /// get the romanized brand, never the Hangul spelling.
    func testNoShownStringUsesTheOldNames() throws {
        let oldName = try NSRegularExpression(pattern: "PogoHome|\\bPOGO\\b|\\bPogo\\b")
        for language in Self.languages {
            let strings = shownStrings(language)
            // Korean is the source language: its table holds only keyed entries; every other
            // Korean string is its own key, checked here too.
            XCTAssertGreaterThan(strings.count, language == "ko" ? 5 : 150, language)
            let checked = language == "ko" ? strings.merging(shownStrings("en").keys.map { ($0, [$0]) }) { own, _ in own } : strings
            for (key, forms) in checked {
                for text in forms {
                    let range = NSRange(text.startIndex..., in: text)
                    XCTAssertNil(oldName.firstMatch(in: text, range: range), "\(language): \(key) → \(text)")
                }
            }
            if language != "ko" {
                XCTAssertEqual(strings["조각보 센서"]?.first?.contains("Jogakbo"), true, "\(language): the brand is romanized, not translated")
                for (key, forms) in strings {
                    for text in forms {
                        XCTAssertFalse(text.contains("조각보"), "\(language): Korean-only brand spelling in \(key) → \(text)")
                    }
                }
            }
        }
    }

    func testOutdatedStateIsCalledOutdatedInformationEverywhere() {
        for language in Self.languages {
            let strings = table(language, "Localizable.strings")
            XCTAssertNil(strings["오래된 값"], "\(language): the old wording is gone")
        }
        XCTAssertEqual(table("en", "Localizable.strings")["오래된 정보"], "Outdated info")
        XCTAssertEqual(table("es", "Localizable.strings")["오래된 정보"], "Datos antiguos")
    }

    /// Settings › 앱 정보 › 이름에 담긴 뜻 is translated in full, naming the brand as each language
    /// spells it.
    func testTheNameStoryIsTranslatedWithEachLanguagesBrand() throws {
        let keys = [
            "이름에 담긴 뜻",
            "조각보는 자투리 천을 모아 바느질로 이어 만든 한국 전통 보자기입니다. 물건을 싸서 보관하거나 운반하고, 선물을 포장하거나 음식을 덮는 등 일상에서 다양하게 사용했습니다.",
            "이 프로젝트의 이름도 여기에서 시작했습니다. 서로 다른 천 조각이 하나의 보자기가 되듯, 여러 센서 모듈이 연결되어 하나의 블록을 이룬다는 뜻을 담았습니다.",
            "작은 조각들이 모여 하나가 되는 것. 그것이 조각보라는 이름에 담긴 생각입니다.",
        ]
        for language in ["en", "es"] {
            let strings = table(language, "Localizable.strings")
            let texts = try keys.map { try XCTUnwrap(strings[$0], "\(language): \($0)") }
            XCTAssertTrue(texts[1].hasPrefix("Jogakbo "), "\(language): \(texts[1])")
            XCTAssertTrue(texts[3].hasSuffix("Jogakbo."), "\(language): \(texts[3])")
            // The story is about the cloth: the app's name never replaces the word.
            XCTAssertFalse(texts.contains { $0.contains("Jogakbo Home") }, language)
        }
        XCTAssertEqual(table("en", "Localizable.strings")[keys[0]], "The Meaning Behind the Name")
        XCTAssertEqual(table("es", "Localizable.strings")[keys[0]], "El significado del nombre")
    }

    /// The logo on the name story is its own asset, apart from the app icon: the background-free
    /// original, in its own proportions.
    func testTheLogoIsItsOwnTransparentAsset() throws {
        let logo = try XCTUnwrap(UIImage(named: "JogakboLogo"))
        let cgImage = try XCTUnwrap(logo.cgImage)
        XCTAssertEqual(cgImage.width, 630)
        XCTAssertEqual(cgImage.height, 353)
        XCTAssertTrue([.first, .last, .premultipliedFirst, .premultipliedLast].contains(cgImage.alphaInfo), "\(cgImage.alphaInfo.rawValue)")
        XCTAssertNotEqual(logo.pngData(), UIImage(named: "AppIcon")?.pngData())
    }

    // MARK: - Identifiers that must not change

    @MainActor
    func testIdentifiersThatTieDataTogetherAreUnchanged() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.junsoona.PogoHome")
        XCTAssertEqual(HomeGlanceStore.appGroupIdentifier, "group.com.junsoona.PogoHome")
        XCTAssertEqual(HomeGlanceLink.scheme, "pogohome")
        let schemes = (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])?
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertEqual(schemes, ["pogohome"])
        XCTAssertEqual(AppleHomeSettingsKeys.enabled, "pogohome.appleHome.enabled")
        XCTAssertEqual(AppleHomeSettingsKeys.pogoLinks, "pogohome.appleHome.pogoLinks")
        XCTAssertEqual(PogoSettingsKeys.dataSourceMode, "pogohome.settings.dataSourceMode")
        XCTAssertEqual(PogoSettingsKeys.liveBaseURL, "pogohome.settings.liveBaseURL")
        XCTAssertEqual(WatchSettingsKeys.selectedValueIDs, "pogohome.watch.selectedValueIDs")
    }

    /// Sensor categories follow current capabilities; board IDs and brand do not imply models.
    func testSensorModelsAndKindsKeepTheirNames() {
        for language in AppLanguage.supported {
            let gas = ModuleCatalog.descriptor(forRawIdentifier: "744dbdfffe65d357", apiRole: nil, sensorBitmap: 0x78, language: language)
            let dust = ModuleCatalog.descriptor(forRawIdentifier: "744dbdfffe65d07a", apiRole: nil, sensorBitmap: 0x380, language: language)
            XCTAssertTrue(gas.displayName.contains("NOx"))
            XCTAssertNotEqual(gas.displayName, dust.displayName)
            XCTAssertFalse(gas.displayName.contains("SGP41"), "the wire does not identify the hardware model")
            XCTAssertFalse(dust.displayName.contains("PMS5003"))
            XCTAssertFalse(gas.displayName.contains("조각보"))
        }
        XCTAssertNotEqual(SensorKind.temperature.displayName, SensorKind.humidity.displayName)
    }

    // MARK: - User data

    /// A module, room or home name the user typed — even one containing an old brand — is shown
    /// exactly as saved, and Apple Home names exactly as HomeKit reports them.
    @MainActor
    func testUserSavedNamesAreNeverRewritten() async throws {
        let module = SensorModule(
            id: UUID(uuidString: "00112233-4455-4677-8899-AABBCCDDEE01")!,
            name: "SGP41 가스 센서",
            hardwareIdentifier: "744dbdfffe65d357",
            roomID: ModuleCatalog.unspecifiedRoom.id,
            readings: [SensorReading(kind: .vocIndex, value: 100, timestamp: Date(), status: .normal)],
            isOnline: true,
            lastSeen: Date()
        )
        let snapshot = HomeSnapshot(timestamp: Date(), rooms: ModuleCatalog.allRooms, modules: [module])
        let model = AppModel(
            dataSource: FixedSnapshotDataSource(snapshot: snapshot),
            initialSnapshot: snapshot,
            configurationStore: InMemoryHomeConfigurationStore()
        )
        let room = try await model.createRoom(name: "PogoHome 작업실", symbolName: "desktopcomputer")
        try await model.updateModule(id: module.id, customName: "POGO 창가 센서", roomID: room.id)
        try await model.updateHomeName(input: "POGO 하우스")

        XCTAssertEqual(model.module(with: module.id)?.name, "POGO 창가 센서")
        XCTAssertEqual(model.module(with: module.id)?.hardwareName, "SGP41 가스 센서", "the model name stays next to the user's name")
        XCTAssertEqual(model.room(with: room.id)?.name, "PogoHome 작업실")
        XCTAssertEqual(model.homeName, "POGO 하우스")

        let accessory = AppleHomeFixtures.sensor(name: "POGO PMS5003")
        XCTAssertEqual(DeviceDirectory.appleHomeSummary(accessory, linkedPogoModuleID: nil).name, "POGO PMS5003")
    }
}

/// Serves one fixed snapshot.
private struct FixedSnapshotDataSource: SensorDataSource {
    let snapshot: HomeSnapshot

    func currentSnapshot() async throws -> HomeSnapshot { snapshot }

    func updates() -> AsyncStream<HomeSnapshot> {
        AsyncStream { $0.yield(snapshot) }
    }
}
