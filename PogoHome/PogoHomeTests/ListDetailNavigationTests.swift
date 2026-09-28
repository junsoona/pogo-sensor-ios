import XCTest
@testable import PogoHome

/// ↑/↓ in the list beside a detail (`ListDetailList`) on the Mac and with an iPad keyboard.
final class ListDetailNavigationTests: XCTestCase {
    private let order = ["a", "b", "c"]

    func testMovesToTheNeighbor() {
        XCTAssertEqual(ListDetailNavigation.value(after: "b", moving: 1, in: order), "c")
        XCTAssertEqual(ListDetailNavigation.value(after: "b", moving: -1, in: order), "a")
    }

    func testStopsAtEitherEndInsteadOfWrapping() {
        XCTAssertEqual(ListDetailNavigation.value(after: "c", moving: 1, in: order), "c")
        XCTAssertEqual(ListDetailNavigation.value(after: "a", moving: -1, in: order), "a")
    }

    func testFromNothingStartsAtTheEndItMovesToward() {
        XCTAssertEqual(ListDetailNavigation.value(after: nil, moving: 1, in: order), "a")
        XCTAssertEqual(ListDetailNavigation.value(after: nil, moving: -1, in: order), "c")
    }

    /// A room or device removed while selected (still the binding's value, no longer a row).
    func testFromAValueNoLongerListedStartsOver() {
        XCTAssertEqual(ListDetailNavigation.value(after: "gone", moving: 1, in: order), "a")
        XCTAssertEqual(ListDetailNavigation.value(after: "gone", moving: -1, in: order), "c")
    }

    func testAnEmptyListHasNowhereToGo() {
        XCTAssertNil(ListDetailNavigation.value(after: "a", moving: 1, in: [String]()))
        XCTAssertNil(ListDetailNavigation.value(after: nil, moving: -1, in: [String]()))
    }
}
