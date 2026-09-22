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
