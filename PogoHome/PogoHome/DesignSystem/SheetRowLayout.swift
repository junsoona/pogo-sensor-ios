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
    /// The symbol whose width is the width of the icon column (`SheetIconColumn`): about 24pt at
    /// the default text size, and the widest of the symbols the rows ordinarily show.
    static let columnReferenceSymbol = "dot.radiowaves.left.and.right"
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

/// The icon (or number, or spinner) column of a sheet row.
///
/// Its width is the width of one reference symbol drawn, invisibly, in the row's own font -- so
/// the column grows exactly as the symbols in it grow with Dynamic Type. A fixed 24pt scaled with
/// `@ScaledMetric` did not: that follows the text style's metrics (2.8 times at the largest
/// accessibility size) while a symbol drawn as text follows the font's point size (3.2 times), and
/// the column cut the wide symbols off from "extra large" on. The column is also never narrower
/// than what it shows (`fixedSize`): a symbol wider than the reference widens its own row instead
/// of being cut.
///
/// An icon is decorative: hidden from VoiceOver, which reads the row's text and would otherwise
/// read the symbol's name before a button's own. A step's number is not (`isDecorative: false`).
struct SheetIconColumn<Icon: View>: View {
    private let icon: Icon
    private let isDecorative: Bool

    init(isDecorative: Bool = true, @ViewBuilder icon: () -> Icon) {
        self.icon = icon()
        self.isDecorative = isDecorative
    }

    var body: some View {
        ZStack {
            Text(Image(systemName: SheetRowLayout.columnReferenceSymbol))
                .hidden()
                .accessibilityHidden(true)
            icon
                .accessibilityHidden(isDecorative)
        }
        .fixedSize()
    }
}

/// A row with a leading icon in a column of one width. The icon sits on the first line's
/// baseline and every line of `content` — however many it wraps to — starts at the same x, as
/// does the row separator below it.
struct SheetIconRow<Icon: View, Content: View>: View {
    private let icon: Icon
    private let spacing: CGFloat
    private let content: Content

    init(spacing: CGFloat = SheetRowLayout.titleSpacing, @ViewBuilder icon: () -> Icon, @ViewBuilder content: () -> Content) {
        self.icon = icon()
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SheetRowLayout.columnSpacing) {
            SheetIconColumn { icon }
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

/// One numbered step: the number in the same column as a row's icon, on the first line's
/// baseline, the text wrapping on its own left edge, the row separator starting there too. Every
/// step, one line or four, follows the same rule.
struct SheetNumberedStep: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SheetRowLayout.columnSpacing) {
            // Not hidden from VoiceOver like an icon: the number is part of what the step says.
            SheetIconColumn(isDecorative: false) {
                Text(verbatim: "\(number)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.tint)
            }
            Text(text)
                .sheetParagraph()
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
        .accessibilityElement(children: .combine)
    }
}
