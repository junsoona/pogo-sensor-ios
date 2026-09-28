import XCTest
@testable import PogoHome

@MainActor
final class SensorKindTests: XCTestCase {
    /// Fixed number formatting; the raw/index unit labels are localized, so those expectations
    /// read `unit` (see LocalizationCatalogTests for locale-specific formatting).
    private static let posix = Locale(identifier: "en_US_POSIX")

    func testAllTenKindsExistWithUniqueIdentifiers() {
        XCTAssertEqual(SensorKind.allCases.count, 10)
        XCTAssertEqual(Set(SensorKind.allCases.map(\.id)).count, 10)
    }

    func testDisplayNamesAndUnitsAreNotEmpty() {
        for kind in SensorKind.allCases {
            XCTAssertFalse(kind.displayName.isEmpty, "\(kind) displayName is empty")
            XCTAssertFalse(kind.unit.isEmpty, "\(kind) unit is empty")
            XCTAssertFalse(kind.symbolName.isEmpty, "\(kind) symbolName is empty")
        }
    }

    func testTemperatureFormat() {
        XCTAssertEqual(SensorKind.temperature.formattedValue(23.4, locale: Self.posix), "23.4 °C")
    }

    func testHumidityFormat() {
        XCTAssertEqual(SensorKind.humidity.formattedValue(48.0, locale: Self.posix), "48.0 %")
    }

    func testIlluminanceFormat() {
        XCTAssertEqual(SensorKind.illuminance.formattedValue(120.0, locale: Self.posix), "120 lx")
    }

    func testParticulateMatterFormats() {
        XCTAssertEqual(SensorKind.pm1.formattedValue(4.0, locale: Self.posix), "4.0 µg/m³")
        XCTAssertEqual(SensorKind.pm2_5.formattedValue(7.0, locale: Self.posix), "7.0 µg/m³")
        XCTAssertEqual(SensorKind.pm10.formattedValue(11.0, locale: Self.posix), "11.0 µg/m³")
    }

    func testVOCFormats() {
        XCTAssertEqual(SensorKind.vocRaw.formattedValue(120.0, locale: Self.posix), "120 \(SensorKind.vocRaw.unit)")
        XCTAssertEqual(SensorKind.vocIndex.formattedValue(85.0, locale: Self.posix), "85 \(SensorKind.vocIndex.unit)")
    }

    func testNOxFormats() {
        XCTAssertEqual(SensorKind.noxRaw.formattedValue(60.0, locale: Self.posix), "60 \(SensorKind.noxRaw.unit)")
        XCTAssertEqual(SensorKind.noxIndex.formattedValue(40.0, locale: Self.posix), "40 \(SensorKind.noxIndex.unit)")
    }
}
