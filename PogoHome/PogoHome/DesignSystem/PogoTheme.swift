import SwiftUI

/// Shared layout constants and status colors so features stay visually consistent
/// without a full custom design system.
enum PogoTheme {
    static let cardCornerRadius: CGFloat = 18
    static let cardPadding: CGFloat = 14
    static let sectionSpacing: CGFloat = 26
    static let gridSpacing: CGFloat = 12

    static let canvas = Color(.systemGroupedBackground)
    static let tile = Color(.secondarySystemGroupedBackground)

    /// Card grid columns: two-up (on an iPhone) at regular text sizes, one full-width column at
    /// accessibility sizes, where a ~165pt-wide card can no longer fit its value and labels.
    static func cardColumns(for dynamicTypeSize: DynamicTypeSize, minimumWidth: CGFloat = 160) -> [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible(), spacing: gridSpacing)]
        }
        return [GridItem(.adaptive(minimum: minimumWidth), spacing: gridSpacing)]
    }

    /// Narrowest content width that gets a list next to a detail (`AdaptiveSplitLayout`): an
    /// iPad mini in portrait (744pt) does, an iPad half of Split View (~500pt) doesn't.
    static let splitLayoutMinimumWidth: CGFloat = 700
    /// At accessibility text sizes a ~300pt list column breaks room names mid-word, so the
    /// list sits beside the detail only in a landscape-iPad-sized window.
    static let accessibilitySplitLayoutMinimumWidth: CGFloat = 1100

    static func usesSplitLayout(width: CGFloat, dynamicTypeSize: DynamicTypeSize) -> Bool {
        width >= (dynamicTypeSize.isAccessibilitySize ? accessibilitySplitLayoutMinimumWidth : splitLayoutMinimumWidth)
    }

    /// Widest a list column beside a detail (`ListDetailLayout`) grows with Dynamic Type.
    static let listColumnMaximumWidth: CGFloat = 420
    /// How long the detail beside a list waits before reading an Apple Home device, so ↑/↓
    /// through the list read only the device the selection stops on.
    static let listDetailReadDelay: Duration = .milliseconds(400)
    /// Widest an empty state's text runs (`CenteredEmptyState`), in any window.
    static let emptyStateMaxWidth: CGFloat = 520

    /// Wide layouts (iPad, Mac) show status cards side by side from this content width on.
    static let wideDashboardMinimumWidth: CGFloat = 640

    static func color(for kind: SensorKind) -> Color {
        switch kind.category {
        case .climate: return .orange
        case .airQuality: return .teal
        case .light: return .yellow
        case .gas: return .indigo
        }
    }

    /// Color is always paired with an SF Symbol and text elsewhere (`StatusBadge`),
    /// so status is never communicated by color alone.
    static func color(for status: SensorStatus) -> Color {
        switch status {
        case .normal: return .green
        case .conditioning: return .blue
        case .stale: return .orange
        case .unavailable: return .gray
        case .error: return .red
        }
    }
}
