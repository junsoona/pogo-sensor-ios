import XCTest
@testable import PogoHome

@MainActor
final class SensorKindTests: XCTestCase {
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
        XCTAssertEqual(SensorKind.temperature.formattedValue(23.4), "23.4 °C")
    }

    func testHumidityFormat() {
        XCTAssertEqual(SensorKind.humidity.formattedValue(48.0), "48.0 %")
    }

    func testIlluminanceFormat() {
        XCTAssertEqual(SensorKind.illuminance.formattedValue(120.0), "120 lx")
    }

    func testParticulateMatterFormats() {
        XCTAssertEqual(SensorKind.pm1.formattedValue(4.0), "4.0 µg/m³")
        XCTAssertEqual(SensorKind.pm2_5.formattedValue(7.0), "7.0 µg/m³")
        XCTAssertEqual(SensorKind.pm10.formattedValue(11.0), "11.0 µg/m³")
    }

    func testVOCFormats() {
        XCTAssertEqual(SensorKind.vocRaw.formattedValue(120.0), "120 Raw")
        XCTAssertEqual(SensorKind.vocIndex.formattedValue(85.0), "85 Index")
    }

    func testNOxFormats() {
        XCTAssertEqual(SensorKind.noxRaw.formattedValue(60.0), "60 Raw")
        XCTAssertEqual(SensorKind.noxIndex.formattedValue(40.0), "40 Index")
    }
}
