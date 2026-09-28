import UIKit
import XCTest
@testable import PogoHome

/// Geometry behind the two iPhone 13 mini layout bugs: symbols spilling out of their circles
/// at large Dynamic Type sizes, and the icon picker leaving an empty block at the end of each
/// row. The SwiftUI views only apply these numbers.
@MainActor
final class IconLayoutTests: XCTestCase {
    /// Every symbol drawn inside an `IconCircle` (room icons, sensor kinds, dashboard/status
    /// icons), at every diameter the app uses — base sizes and their capped Dynamic Type
    /// growth — must fit with a margin: its bounding box's half-diagonal stays inside the
    /// circle, and its width/height leave a clear margin inside the diameter.
    func testEverySymbolFitsInsideItsCircleAtEveryDiameter() throws {
        let symbols = RoomIconCatalog.allSymbolNames
            + SensorKind.allCases.map(\.symbolName)
            + ["sensor.fill", "exclamationmark.triangle.fill", "waveform.path.ecg", "checkmark.circle.fill",
               "wifi.exclamationmark", "arrow.triangle.2.circlepath", "hourglass", "square.grid.2x2", "square.dashed"]
        let diameters: [CGFloat] = [26, 30, 36, 38, 44, 46, 48, 54, 57, 64, 69, 72, 76]
        for diameter in diameters {
            for name in symbols {
                let pointSize = IconCircle.symbolPointSize(for: name, diameter: diameter)
                let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .bold, scale: .medium)
                let size = try XCTUnwrap(UIImage(systemName: name, withConfiguration: configuration), name).size
                // ≥ 17% of the diameter free on each side horizontally, ≥ 20% vertically…
                XCTAssertLessThanOrEqual(size.width, diameter * 0.66, "\(name) is too wide for a \(diameter)pt circle")
                XCTAssertLessThanOrEqual(size.height, diameter * 0.60, "\(name) is too tall for a \(diameter)pt circle")
                // …and even the bounding box's corners stay inside the circle with a margin.
                let halfDiagonal = (size.width * size.width + size.height * size.height).squareRoot() / 2
                XCTAssertLessThanOrEqual(halfDiagonal, diameter * 0.45, "\(name)'s corners leave a \(diameter)pt circle")
                XCTAssertGreaterThanOrEqual(pointSize, diameter * 0.25, "\(name) shrank to an unreadable size")
            }
        }
    }

    // MARK: - Icon picker columns

    func testFourIconsSpreadAcrossTheWholeRowAtSmallAndDefaultSizes() {
        // iPhone 13 mini inset-grouped Form row ≈ 303pt wide; 44pt is the smallest (xSmall text)
        // cell, 48pt the default.
        XCTAssertEqual(EvenColumnGrid.columnCount(availableWidth: 303, cellSize: 44, spacing: 12, itemCount: 4), 4,
                       "more columns fit, but never more than the icons in the row — they are spread instead")
        XCTAssertEqual(EvenColumnGrid.columnCount(availableWidth: 303, cellSize: 48, spacing: 12, itemCount: 4), 4)
        XCTAssertEqual(EvenColumnGrid.columnCount(availableWidth: 600, cellSize: 44, spacing: 12, itemCount: 4), 4)
    }

    func testColumnsDropAndStayBalancedAtAccessibilitySizes() {
        // 76pt (the cap): three fit in 303pt, but 4 icons as 3 + 1 looks broken → 2 + 2.
        XCTAssertEqual(EvenColumnGrid.columnCount(availableWidth: 303, cellSize: 76, spacing: 12, itemCount: 4), 2)
        XCTAssertEqual(EvenColumnGrid.columnCount(availableWidth: 150, cellSize: 76, spacing: 12, itemCount: 4), 1)
        XCTAssertEqual(EvenColumnGrid.columnCount(availableWidth: 303, cellSize: 76, spacing: 12, itemCount: 5), 3, "5 → 3 + 2")
        XCTAssertEqual(EvenColumnGrid.columnCount(availableWidth: 10, cellSize: 76, spacing: 12, itemCount: 4), 1, "never zero columns")
        XCTAssertEqual(EvenColumnGrid.columnCount(availableWidth: 303, cellSize: 48, spacing: 12, itemCount: 0), 1)
    }

    func testPickerCellsKeepATouchTargetAndFitTwoAcrossOnAnIPhone13Mini() {
        XCTAssertGreaterThanOrEqual(RoomIconPicker.minimumCellSize, 44)
        XCTAssertLessThanOrEqual(RoomIconPicker.maximumCellSize * 2 + 12, 303 - 40, "two capped cells must fit with room to spare")
    }
}
