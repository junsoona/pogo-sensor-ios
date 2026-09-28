import SwiftUI

/// Lays out equally sized cells in columns that always span the full proposed width.
///
/// `LazyVGrid(columns: [GridItem(.adaptive(minimum:))])` creates as many columns as fit and
/// leaves the unused ones empty, so a four-icon row on a wide (or small-text) row ends in a
/// block of empty space. This layout instead picks the column count from how many cells fit,
/// balances it against the item count (4 items never become 3 + 1), and spreads the columns
/// evenly across the width, centering each cell in its column.
struct EvenColumnGrid: Layout {
    /// The cell's width and height — also its minimum column width.
    var cellSize: CGFloat
    /// Minimum horizontal gap between cells, and the gap between rows.
    var spacing: CGFloat

    /// Pure, so the policy can be unit tested: as many columns as fit, then the fewest
    /// columns that still need no more rows than that (balanced rows).
    static func columnCount(availableWidth: CGFloat, cellSize: CGFloat, spacing: CGFloat, itemCount: Int) -> Int {
        guard itemCount > 0 else { return 1 }
        let fitting = max(1, Int(((availableWidth + spacing) / (cellSize + spacing)).rounded(.down)))
        let columns = min(fitting, itemCount)
        let rows = Int((Double(itemCount) / Double(columns)).rounded(.up))
        return Int((Double(itemCount) / Double(rows)).rounded(.up))
    }

    private func columns(for width: CGFloat?, itemCount: Int) -> Int {
        guard let width, width.isFinite else { return max(1, itemCount) }
        return Self.columnCount(availableWidth: width, cellSize: cellSize, spacing: spacing, itemCount: itemCount)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let count = subviews.count
        guard count > 0 else { return .zero }
        let columns = columns(for: proposal.width, itemCount: count)
        let rows = Int((Double(count) / Double(columns)).rounded(.up))
        let naturalWidth = CGFloat(columns) * cellSize + CGFloat(columns - 1) * spacing
        let width = proposal.width.flatMap { $0.isFinite ? max($0, cellSize) : nil } ?? naturalWidth
        let height = CGFloat(rows) * cellSize + CGFloat(rows - 1) * spacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let count = subviews.count
        guard count > 0 else { return }
        let columns = columns(for: bounds.width, itemCount: count)
        let columnWidth = bounds.width / CGFloat(columns)
        for (index, subview) in subviews.enumerated() {
            let row = index / columns
            let column = index % columns
            let center = CGPoint(
                x: bounds.minX + columnWidth * (CGFloat(column) + 0.5),
                y: bounds.minY + CGFloat(row) * (cellSize + spacing) + cellSize / 2
            )
            subview.place(at: center, anchor: .center, proposal: ProposedViewSize(width: cellSize, height: cellSize))
        }
    }
}
