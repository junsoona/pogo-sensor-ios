import SwiftUI
import UIKit

/// An SF Symbol on a filled circle — the one icon style used by cards and rows across the app.
///
/// The symbol's point size is derived from the circle's diameter, never from Dynamic Type
/// directly: a `.font(.body)` symbol in a fixed 36pt frame keeps growing with the text size
/// and spills out of its circle at accessibility sizes. Here the circle itself grows with
/// Dynamic Type (relative to `textStyle`) up to `maximumScale`, and the symbol is sized from
/// the circle and its own measured proportions — so it keeps an inner margin at every size
/// while the neighbouring text keeps scaling normally.
struct IconCircle: View {
    static func powerBase(diameter: CGFloat) -> some View {
        IconCircle(systemName: "powerplug.fill", diameter: diameter, background: JogakboPalette.coral)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + $0.height * 0.2 }
    }

    /// Largest symbol point size ÷ circle diameter — what a roughly square symbol gets.
    static let symbolRatio: CGFloat = 0.46
    /// The box a symbol's drawn bounds must fit in, as fractions of the diameter. Its
    /// half-diagonal (≈ 0.43 × diameter) stays well inside the circle's radius, so even a
    /// wide glyph like `sofa.fill` (≈ 1.8× as wide as its point size) keeps a margin.
    static let maximumSymbolWidthRatio: CGFloat = 0.64
    static let maximumSymbolHeightRatio: CGFloat = 0.56

    /// The point size at which `systemName` fits the safe box for `diameter`.
    static func symbolPointSize(for systemName: String, diameter: CGFloat) -> CGFloat {
        let perPoint = symbolSizePerPoint(for: systemName)
        let fitting = min(
            diameter * symbolRatio,
            diameter * maximumSymbolWidthRatio / max(perPoint.width, 0.01),
            diameter * maximumSymbolHeightRatio / max(perPoint.height, 0.01)
        )
        return max(1, fitting.rounded(.down))
    }

    private static var symbolSizeCache: [String: CGSize] = [:]

    /// The symbol's drawn size per point of font size, measured once (at the heaviest weight
    /// the app uses) and cached. Unknown names measure as square.
    private static func symbolSizePerPoint(for systemName: String) -> CGSize {
        if let cached = symbolSizeCache[systemName] { return cached }
        let referencePointSize: CGFloat = 100
        let configuration = UIImage.SymbolConfiguration(pointSize: referencePointSize, weight: .bold, scale: .medium)
        let measured = UIImage(systemName: systemName, withConfiguration: configuration)?.size
            ?? CGSize(width: referencePointSize, height: referencePointSize)
        let perPoint = CGSize(width: measured.width / referencePointSize, height: measured.height / referencePointSize)
        symbolSizeCache[systemName] = perPoint
        return perPoint
    }

    private let systemName: String
    private let background: AnyShapeStyle
    private let foreground: AnyShapeStyle
    private let weight: Font.Weight
    private let maximumDiameter: CGFloat
    @ScaledMetric private var scaledDiameter: CGFloat

    init(
        systemName: String,
        diameter: CGFloat,
        background: some ShapeStyle = Color.blue,
        foreground: some ShapeStyle = Color.white,
        weight: Font.Weight = .semibold,
        relativeTo textStyle: Font.TextStyle = .body,
        maximumScale: CGFloat = 1.5
    ) {
        self.systemName = systemName
        self.background = AnyShapeStyle(background)
        self.foreground = AnyShapeStyle(foreground)
        self.weight = weight
        self.maximumDiameter = diameter * maximumScale
        _scaledDiameter = ScaledMetric(wrappedValue: diameter, relativeTo: textStyle)
    }

    private var diameter: CGFloat {
        min(scaledDiameter, maximumDiameter)
    }

    var body: some View {
        IconCircleShape(
            systemName: systemName,
            diameter: diameter,
            background: background,
            foreground: foreground,
            weight: weight
        )
        .accessibilityHidden(true)
    }
}

/// `IconCircle` at an exact, caller-computed diameter — for the icon picker, which sizes its
/// cells itself.
struct IconCircleShape: View {
    let systemName: String
    let diameter: CGFloat
    var background: AnyShapeStyle = AnyShapeStyle(Color.blue)
    var foreground: AnyShapeStyle = AnyShapeStyle(Color.white)
    var weight: Font.Weight = .semibold

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: IconCircle.symbolPointSize(for: systemName, diameter: diameter), weight: weight))
            .imageScale(.medium)
            .foregroundStyle(foreground)
            .frame(width: diameter, height: diameter)
            .background(background, in: Circle())
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        ForEach([DynamicTypeSize.xSmall, .large, .accessibility5], id: \.self) { size in
            HStack(spacing: 12) {
                IconCircle(systemName: "sofa.fill", diameter: 36)
                IconCircle(systemName: "door.garage.closed", diameter: 36, background: Color.orange)
                IconCircle(systemName: "wrench.and.screwdriver.fill", diameter: 36, background: Color.teal)
                Text("Dynamic Type")
            }
            .dynamicTypeSize(size)
        }
    }
    .padding()
}
