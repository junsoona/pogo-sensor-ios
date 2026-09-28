import SwiftUI

/// The measures shared by the information rows of the Add Device sheet and its Power Base
/// screen, so every card, icon or number column and paragraph follows one rule on iPhone, iPad
/// and Mac. The Mac Catalyst list otherwise leaves only ~6pt above and below a row, which put
/// multi-line text against the card edges and the separators.
enum SheetRowLayout {
    /// Inside every card row.
    static let rowInsets = EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
    /// Between a row's title and its description.
    static let titleSpacing: CGFloat = 4
    /// Between the paragraphs of one row.
    static let paragraphSpacing: CGFloat = 8
    /// Extra leading between the lines of a paragraph.
    static let lineSpacing: CGFloat = 2
    /// Between the icon or number column and the text.
    static let columnSpacing: CGFloat = 12
    /// Mac: added between one section and the next section's header. The Catalyst list adds its
    /// own ~19pt after a card (~33pt after a footer) to this; iPhone and iPad keep the system's.
    static let macSectionSpacing: CGFloat = 8
    /// Below the last section, so its footer doesn't end against the sheet's edge or bar.
    static let bottomMargin: CGFloat = 20
}

extension View {
    /// The sheet list's spacing between sections and below the last one.
    func sheetListSpacing() -> some View {
        listSectionSpacing(PlatformSupport.isMacCatalyst ? .custom(SheetRowLayout.macSectionSpacing) : .default)
            .contentMargins(.bottom, SheetRowLayout.bottomMargin, for: .scrollContent)
    }

    /// Gives a section's rows the sheet's row insets.
    func sheetRowInsets() -> some View {
        listRowInsets(SheetRowLayout.rowInsets)
    }

    /// A paragraph that wraps to as many lines as it needs, left-aligned, with the sheet's line
    /// spacing. Never truncated or scaled down: a small window scrolls instead.
    func sheetParagraph() -> some View {
        lineSpacing(SheetRowLayout.lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A section footer: a little apart from its card, with the sheet's line spacing.
    func sheetFooter() -> some View {
        sheetParagraph()
            .padding(.top, 4)
    }
}

/// A row with a leading icon in a fixed-width column. The icon sits on the first line's
/// baseline and every line of `content` — however many it wraps to — starts at the same x, as
/// does the row separator below it.
struct SheetIconRow<Icon: View, Content: View>: View {
    private let icon: Icon
    private let spacing: CGFloat
    private let content: Content
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 24

    init(spacing: CGFloat = SheetRowLayout.titleSpacing, @ViewBuilder icon: () -> Icon, @ViewBuilder content: () -> Content) {
        self.icon = icon()
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SheetRowLayout.columnSpacing) {
            icon
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: spacing) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
    }
}

extension SheetIconRow where Icon == SymbolIcon {
    /// An SF Symbol icon, drawn as text so it shares the first line's baseline.
    init(systemImage: String, iconStyle: some ShapeStyle, spacing: CGFloat = SheetRowLayout.titleSpacing, @ViewBuilder content: () -> Content) {
        self.init(spacing: spacing, icon: { SymbolIcon(systemImage: systemImage, style: AnyShapeStyle(iconStyle)) }, content: content)
    }

    /// An SF Symbol icon in the surrounding style — inside a button, its tint, dimmed with the
    /// button.
    init(systemImage: String, spacing: CGFloat = SheetRowLayout.titleSpacing, @ViewBuilder content: () -> Content) {
        self.init(spacing: spacing, icon: { SymbolIcon(systemImage: systemImage, style: nil) }, content: content)
    }
}

/// A progress spinner for a `SheetIconRow`'s icon column. A spinner has no text baseline, so it
/// is centred on the first line of text.
struct SheetRowProgress: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
    }
}

struct SymbolIcon: View {
    let systemImage: String
    let style: AnyShapeStyle?

    var body: some View {
        if let style {
            Text(Image(systemName: systemImage)).foregroundStyle(style)
        } else {
            Text(Image(systemName: systemImage))
        }
    }
}

/// One numbered step: the number in a fixed-width column on the first line's baseline, the text
/// wrapping on its own left edge, the row separator starting there too. Every step, one line
/// or four, follows the same rule.
struct SheetNumberedStep: View {
    let number: Int
    let text: LocalizedStringKey
    @ScaledMetric(relativeTo: .body) private var numberWidth: CGFloat = 24

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SheetRowLayout.columnSpacing) {
            Text(verbatim: "\(number)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.tint)
                .frame(width: numberWidth)
            Text(text)
                .sheetParagraph()
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
        .accessibilityElement(children: .combine)
    }
}
