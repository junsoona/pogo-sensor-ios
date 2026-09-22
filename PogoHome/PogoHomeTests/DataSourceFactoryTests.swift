import XCTest
@testable import PogoHome

@MainActor
final class DataSourceFactoryTests: XCTestCase {
    func testResolvesAValidURLString() {
        let url = DataSourceFactory.resolvedLiveBaseURL(from: "http://192.168.1.50:8787")
        XCTAssertEqual(url.absoluteString, "http://192.168.1.50:8787")
    }

    func testFallsBackToDefaultForEmptyString() {
        let url = DataSourceFactory.resolvedLiveBaseURL(from: "   ")
        XCTAssertEqual(url.absoluteString, PogoAPIEndpoint.defaultBaseURLString)
    }

    func testFallsBackToDefaultForGarbageString() {
        let url = DataSourceFactory.resolvedLiveBaseURL(from: "not a url")
        XCTAssertEqual(url.absoluteString, PogoAPIEndpoint.defaultBaseURLString)
    }

    func testMakeDataSourceReturnsMockForMockMode() {
        let source = DataSourceFactory.makeDataSource(mode: .mock, liveBaseURLString: "http://ignored")
        XCTAssertTrue(source is MockSensorDataSource)
    }

    func testMakeDataSourceReturnsLiveForLiveMode() {
        let source = DataSourceFactory.makeDataSource(mode: .live, liveBaseURLString: PogoAPIEndpoint.defaultBaseURLString)
        XCTAssertTrue(source is LiveSensorDataSource)
    }
}
