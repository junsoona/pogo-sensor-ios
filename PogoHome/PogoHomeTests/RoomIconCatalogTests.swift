import XCTest
@testable import PogoHome

/// Covers the room icon picker's data layer: enough real, renderable symbols across every
/// required category, and `SymbolAvailability`'s runtime fallback for a name the picker
/// doesn't (or can no longer) recognize — the actual grid/selection UI is a SwiftUI view
/// with no meaningful XCTest surface, so this locks down what backs it instead.
final class RoomIconCatalogTests: XCTestCase {
    func testCatalogHasAtLeastThirtyDistinctSymbols() {
        let all = RoomIconCatalog.allSymbolNames
        XCTAssertGreaterThanOrEqual(all.count, 30)
        XCTAssertEqual(Set(all).count, all.count, "every catalog symbol name must be unique")
    }

    func testCatalogCoversEveryRequiredCategory() {
        let requiredTitles: Set<String> = [
            "거실·휴식", "침실·유아실", "작업실·서재", "주방·식당", "욕실·세탁실",
            "현관·복도·계단", "차고·창고·공구실", "정원·발코니·야외", "운동·취미", "기타",
        ]
        let actualTitles = Set(RoomIconCatalog.categories.map { $0.title(in: .korean) })
        XCTAssertEqual(actualTitles, requiredTitles)
        for category in RoomIconCatalog.categories {
            XCTAssertFalse(category.symbolNames.isEmpty, "\(category.id) must offer at least one icon")
        }
        for language in [AppLanguage.english, .spanish] {
            let translated = Set(RoomIconCatalog.categories.map { $0.title(in: language) })
            XCTAssertEqual(translated.count, RoomIconCatalog.categories.count, "\(language.identifier) category titles must be distinct")
            XCTAssertTrue(translated.isDisjoint(with: requiredTitles), "\(language.identifier) category titles must be translated")
        }
    }

    func testEveryCatalogSymbolActuallyRendersOnThisOS() {
        for name in RoomIconCatalog.allSymbolNames {
            XCTAssertEqual(
                SymbolAvailability.resolvedName(for: name), name,
                "\(name) is in the catalog but does not resolve to itself — it may not exist on this OS"
            )
        }
    }

    func testUnavailableSymbolNameFallsBackToSquareDashed() {
        XCTAssertEqual(SymbolAvailability.resolvedName(for: "this.symbol.does.not.exist.pogohome"), "square.dashed")
    }

    func testKnownExistingSymbolResolvesToItself() {
        XCTAssertEqual(SymbolAvailability.resolvedName(for: "sofa.fill"), "sofa.fill")
    }
}
