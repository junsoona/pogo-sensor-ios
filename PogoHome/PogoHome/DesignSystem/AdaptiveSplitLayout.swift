import SwiftUI

/// Chooses the root of a tab's navigation stack: the phone layout — a card grid — or the
/// list-and-detail layout (`ListDetailLayout`). The stack itself stays the same across both.
///
/// The list-and-detail layout needs a regular horizontal size class *and* real width: an iPad
/// window can be regular yet narrow (a Mac window is always regular), and there a list column
/// would squeeze the detail into a strip. Anything narrower — iPhone, iPad Split View / Slide
/// Over, a small iPad or Mac window — keeps the card grid, which already adapts its column count.
struct AdaptiveSplitLayout<Compact: View, Wide: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ViewBuilder let compact: () -> Compact
    @ViewBuilder let wide: () -> Wide

    var body: some View {
        if horizontalSizeClass == .compact {
            // iPhone: exactly the phone layout, not measured.
            compact()
        } else {
            GeometryReader { proxy in
                if PogoTheme.usesSplitLayout(width: proxy.size.width, dynamicTypeSize: dynamicTypeSize) {
                    wide()
                } else {
                    compact()
                }
            }
        }
    }
}

/// The detail pane's empty state before anything is selected.
struct SplitDetailPlaceholder: View {
    let title: LocalizedStringKey
    let systemImage: String
    let message: LocalizedStringKey

    var body: some View {
        CenteredEmptyState {
            ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
        }
    }
}

/// One row of a list column (rooms, devices): icon, name, and a status line.
struct SplitListRow<Accessory: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let symbolName: String
    var tint: Color = .blue
    let title: String
    var subtitle: String?
    var isSubtitleAlert = false
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        // At accessibility sizes the icon is left out and every line wraps in full: the list
        // column is too narrow to cut a name after two lines.
        let lineLimit = dynamicTypeSize.isAccessibilitySize ? nil : 2
        HStack(spacing: 12) {
            if !dynamicTypeSize.isAccessibilitySize {
                IconCircle(systemName: symbolName, diameter: 30, background: tint)
                    // The row's name and status say it all; the room's icon isn't its own element.
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .lineLimit(lineLimit)
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(.caption)
                        .foregroundStyle(isSubtitleAlert ? Color.red : Color.secondary)
                        .lineLimit(lineLimit)
                }
            }
            Spacer(minLength: 0)
            accessory()
        }
        // One element: the icon is decoration, the accessory never a control in a list row.
        .accessibilityElement(children: .combine)
        .listDetailRowAccessibility()
        .padding(.vertical, 2)
    }
}

extension SplitListRow where Accessory == EmptyView {
    init(symbolName: String, tint: Color = .blue, title: String, subtitle: String? = nil, isSubtitleAlert: Bool = false) {
        self.init(symbolName: symbolName, tint: tint, title: title, subtitle: subtitle, isSubtitleAlert: isSubtitleAlert) {
            EmptyView()
        }
    }
}
