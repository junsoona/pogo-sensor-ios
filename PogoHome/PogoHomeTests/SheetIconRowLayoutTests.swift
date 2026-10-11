import SwiftUI
import UIKit
import XCTest
@testable import PogoHome

/// The icon column of `SheetIconRow` (the rows of "Power Base 추가", "다른 허브에 연결하기", the
/// management sheet, the QR rows and Settings' hub rows): at every Dynamic Type size the symbol
/// is drawn whole and the text starts to the right of it.
///
/// Background (2026-10-08, iPhone 13 mini, largest accessibility size): the wave symbol left of
/// "주변에서 Power Base 찾기" was cut off on its right. The column was a fixed 24pt scaled with the
/// body font, and the symbol, drawn as text in that font, is wider than that.
@MainActor
final class SheetIconRowLayoutTests: XCTestCase {
    static let categories: [UIContentSizeCategory] = [
        .extraSmall, .small, .medium, .large, .extraLarge, .extraExtraLarge, .extraExtraExtraLarge,
        .accessibilityMedium, .accessibilityLarge, .accessibilityExtraLarge, .accessibilityExtraExtraLarge, .accessibilityExtraExtraExtraLarge,
    ]

    /// Every SF Symbol a `SheetIconRow` or `SymbolIcon` is given anywhere in the app.
    static let symbols = [
        "dot.radiowaves.left.and.right", "antenna.radiowaves.left.and.right.slash", "arrow.clockwise", "gearshape", "exclamationmark.triangle.fill",
        "info.circle", "info.circle.fill", "checkmark.circle.fill", "circle", "wifi.exclamationmark", "xmark.circle", "xmark.circle.fill",
        "questionmark.circle", "questionmark.circle.fill", "powerplug.fill", "xmark.octagon.fill", "trash", "timer", "stop.circle", "server.rack",
        "qrcode.viewfinder", "play.circle.fill", "arrow.triangle.swap", "doc.viewfinder", "photo", "hand.raised.circle.fill", "sensor.fill",
        "magnifyingglass", "list.bullet", "exclamationmark.circle", "desktopcomputer.trianglebadge.exclamationmark", "desktopcomputer",
        "clock.arrow.circlepath", "checkmark.shield", "checkmark", "arrow.uturn.backward", "arrow.up.circle", "arrow.triangle.2.circlepath",
        "minus.circle.fill", "camera", "photo.on.rectangle", "exclamationmark.magnifyingglass", "pause.circle",
    ]

    /// The size SwiftUI gives `view` when nothing constrains it, at `category`.
    static func naturalSize(of view: some View, at category: UIContentSizeCategory) -> CGSize {
        // The SwiftUI environment, not a UIKit trait override: an override on a controller that
        // is in no window is not what its content is measured with.
        let size = DynamicTypeSize(category) ?? .large
        let host = UIHostingController(rootView: view.fixedSize().dynamicTypeSize(size))
        host.view.layoutIfNeeded()
        return host.sizeThatFits(in: CGSize(width: 10_000, height: 10_000))
    }

    static func bodyPointSize(at category: UIContentSizeCategory) -> CGFloat {
        UIFont.preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: category)).pointSize
    }

    // MARK: - The rule

    /// The symbol's own width, the width of the column it is put in, and what the old column
    /// (24pt scaled with the body text style) was -- at every size.
    func testTheColumnIsNeverNarrowerThanTheSymbolItShowsAtAnySize() {
        var cutByTheOldColumn: [String] = []
        for category in Self.categories {
            let old = UIFontMetrics(forTextStyle: .body).scaledValue(for: 24, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
            let reference = Self.naturalSize(of: SymbolIcon(systemImage: SheetRowLayout.columnReferenceSymbol, style: nil), at: category).width
            for name in Self.symbols {
                let symbol = Self.naturalSize(of: SymbolIcon(systemImage: name, style: nil), at: category).width
                let column = Self.naturalSize(of: SheetIconColumn { SymbolIcon(systemImage: name, style: nil) }, at: category).width
                XCTAssertGreaterThanOrEqual(column, symbol - 0.01, "\(name) is cut off by its column at \(category.rawValue)")
                XCTAssertGreaterThanOrEqual(column, reference - 0.01, "\(name)'s column is narrower than the others' at \(category.rawValue)")
                XCTAssertLessThanOrEqual(column, max(symbol, reference) + 0.01, "\(name)'s column is wider than it has to be at \(category.rawValue)")
                if symbol > old + 0.5 { cutByTheOldColumn.append("\(name)@\(Int(Self.bodyPointSize(at: category)))pt") }
            }
        }
        // The defect this replaced, as numbers: the old column was narrower than the wave symbol
        // from "extra large" on, by almost 10pt at the largest size. On iPhone and iPad: a Mac
        // Catalyst window does not scale its text with Dynamic Type, and never had the defect.
        guard !PlatformSupport.isMacCatalyst else { return }
        let largest = UIContentSizeCategory.accessibilityExtraExtraExtraLarge
        let old = UIFontMetrics(forTextStyle: .body).scaledValue(for: 24, compatibleWith: UITraitCollection(preferredContentSizeCategory: largest))
        let wave = Self.naturalSize(of: SymbolIcon(systemImage: "dot.radiowaves.left.and.right", style: nil), at: largest).width
        XCTAssertGreaterThan(wave - old, 8, "the reproduced cause: \(wave)pt of symbol in a \(old)pt column")
        XCTAssertTrue(cutByTheOldColumn.contains("dot.radiowaves.left.and.right@53pt"))
    }

    /// The numbers and the spinner are not symbols; their column is the same one.
    func testNumbersAndSpinnersGetTheSameColumn() {
        for category in Self.categories {
            let reference = Self.naturalSize(of: SymbolIcon(systemImage: SheetRowLayout.columnReferenceSymbol, style: nil), at: category).width
            let number = Self.naturalSize(of: SheetIconColumn { Text(verbatim: "3").font(.headline.monospacedDigit()) }, at: category).width
            let spinner = Self.naturalSize(of: SheetIconColumn { SheetRowProgress() }, at: category).width
            XCTAssertEqual(number, reference, accuracy: 0.01, category.rawValue)
            XCTAssertEqual(spinner, reference, accuracy: 0.01, category.rawValue)
        }
    }

    // MARK: - What is drawn

    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for window in windows {
            window.isHidden = true
            window.rootViewController = nil
        }
        windows = []
    }

    /// `view` drawn `width` points wide on white, at `category`, twice the point resolution.
    private func draw(_ view: some View, width: CGFloat, at category: UIContentSizeCategory) async throws -> (image: CGImage, scale: CGFloat) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let size = DynamicTypeSize(category) ?? .large
        let content = view.dynamicTypeSize(size).frame(width: width, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8).background(Color.white).environment(\.colorScheme, .light)
        let host = UIHostingController(rootView: content)
        let height = host.sizeThatFits(in: CGSize(width: width, height: 5_000)).height
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: max(height, 20))
        window.backgroundColor = .white
        host.view.backgroundColor = .white
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        windows.append(window)
        try await Task.sleep(for: .milliseconds(150))
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return (try XCTUnwrap(image.cgImage), 2)
    }

    /// The bounding box, in points, of the pixels `matches` picks; `nil` when there are none.
    private func inkBox(in drawn: (image: CGImage, scale: CGFloat), where matches: (UInt8, UInt8, UInt8) -> Bool) throws -> CGRect? {
        let image = drawn.image
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if matches(pixels[i], pixels[i + 1], pixels[i + 2]) {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: CGFloat(minX) / drawn.scale, y: CGFloat(minY) / drawn.scale, width: CGFloat(maxX - minX + 1) / drawn.scale, height: CGFloat(maxY - minY + 1) / drawn.scale)
    }

    private static func isRed(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool { r > 150 && g < 110 && b < 110 }
    private static func isBlue(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool { b > 150 && r < 110 }   // system blue has green in it

    /// The row of the bug report -- the wave symbol and "주변에서 Power Base 찾기" -- and the rows
    /// with the other wide symbols, as wide as an iPhone 13 mini's list row, at the default and at
    /// the largest size: the symbol's drawn pixels are as wide as when nothing constrains it (it
    /// is whole), and the text's pixels begin to the right of them (nothing overlaps), however
    /// many lines the text takes.
    func testTheSymbolIsDrawnWholeAndTheTextBesideItOnAnIPhone13MiniRow() async throws {
        let rowWidth: CGFloat = 303   // 375 - 2 x 16 (inset list) - 2 x 20 (row insets)
        let rows: [(symbol: String, text: String)] = [
            ("dot.radiowaves.left.and.right", "주변에서 Power Base 찾기"),
            ("arrow.clockwise", "다시 찾기"),
            ("antenna.radiowaves.left.and.right.slash", "이 앱의 Bluetooth 사용이 허용되어 있지 않습니다. 설정에서 조각보 홈의 Bluetooth를 허용하세요."),
            ("exclamationmark.magnifyingglass", "아직 찾지 못했습니다. Power Base의 전원이 켜져 있는지, 가까이 있는지 확인하세요."),
            ("desktopcomputer.trianglebadge.exclamationmark", "Find Power Bases Nearby and Search Again"),
            ("wifi.exclamationmark", "Buscar Power Bases cerca"),
        ]
        for category in [UIContentSizeCategory.large, .extraExtraExtraLarge, .accessibilityExtraExtraExtraLarge] {
            for row in rows {
                let alone = try await draw(SymbolIcon(systemImage: row.symbol, style: AnyShapeStyle(Color.red)).fixedSize().padding(.horizontal, 6), width: 140, at: category)
                let whole = try XCTUnwrap(try inkBox(in: alone, where: Self.isRed), "\(row.symbol) draws nothing")
                let drawn = try await draw(
                    SheetIconRow(systemImage: row.symbol, iconStyle: Color.red) { Text(verbatim: row.text).foregroundStyle(Color.blue).sheetParagraph() },
                    width: rowWidth, at: category
                )
                let icon = try XCTUnwrap(try inkBox(in: drawn, where: Self.isRed), "\(row.symbol): no icon in the row")
                let text = try XCTUnwrap(try inkBox(in: drawn, where: Self.isBlue), "\(row.symbol): no text in the row")
                let label = "\(row.symbol) at \(category.rawValue)"
                XCTAssertEqual(icon.width, whole.width, accuracy: 1.0, "\(label): the symbol is not drawn whole (\(icon.width)pt of \(whole.width)pt)")
                XCTAssertEqual(icon.height, whole.height, accuracy: 1.0, "\(label): the symbol is cut vertically")
                XCTAssertGreaterThanOrEqual(icon.minX, 0, label)
                XCTAssertGreaterThanOrEqual(text.minX - icon.maxX, 6, "\(label): the text starts in, or against, the symbol")
                XCTAssertLessThanOrEqual(text.maxX, rowWidth, "\(label): the text runs out of the row")
                XCTAssertGreaterThan(text.width, 40, "\(label): there is no room left for the text")
            }
        }
    }

    /// What the report showed, drawn the way the row drew it before: the same symbol in the old
    /// 24pt-scaled column loses pixels at the largest size. (So the check above can fail.)
    func testTheOldColumnReallyCutTheWaveSymbolAtTheLargestSize() async throws {
        try XCTSkipIf(PlatformSupport.isMacCatalyst, "Mac Catalyst does not scale text with Dynamic Type: the old column never cut a symbol there")
        let category = UIContentSizeCategory.accessibilityExtraExtraExtraLarge
        let alone = try await draw(SymbolIcon(systemImage: "dot.radiowaves.left.and.right", style: AnyShapeStyle(Color.red)).fixedSize().padding(.horizontal, 6), width: 140, at: category)
        let whole = try XCTUnwrap(try inkBox(in: alone, where: Self.isRed))
        let old = try await draw(OldSheetIconRow(systemImage: "dot.radiowaves.left.and.right") { Text(verbatim: "주변에서 Power Base 찾기").foregroundStyle(Color.blue) }, width: 303, at: category)
        let icon = try XCTUnwrap(try inkBox(in: old, where: Self.isRed))
        XCTAssertLessThan(icon.width, whole.width - 3, "the old row drew \(icon.width)pt of a \(whole.width)pt symbol")
    }

    // MARK: - VoiceOver

    /// A button whose label is an icon row is read as its title, once: the symbol (and the
    /// invisible reference symbol that sizes the column) adds no name of its own.
    func testAButtonWithAnIconRowIsReadAsItsTitleOnly() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let title = "주변에서 Power Base 찾기"
        let view = VStack(alignment: .leading) {
            Button {} label: { SheetIconRow(systemImage: "dot.radiowaves.left.and.right") { Text(verbatim: title) } }
            SheetNumberedStep(number: 2, text: "두 번째 단계")
        }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 300)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        windows.append(window)
        try await Task.sleep(for: .milliseconds(300))
        // SwiftUI builds its accessibility tree only once something asks for accessibility; in a
        // test process nothing has. The simulator's accessibility library can be told that an
        // automation client is there (what UI tests do). Where that is not possible the tree
        // stays empty and this test says so instead of passing on nothing.
        typealias SetAutomationEnabled = @convention(c) (Int32) -> Void
        if let library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let symbol = dlsym(library, "_AXSSetAutomationEnabled") {
            unsafeBitCast(symbol, to: SetAutomationEnabled.self)(1)
        }
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        var labels: [String] = []
        func collect(_ object: Any) {
            guard let element = object as? NSObject else { return }
            if element.isAccessibilityElement, let label = element.accessibilityLabel, !label.isEmpty { labels.append(label) }
            if let children = element.accessibilityElements { children.forEach(collect) }
            if !element.isAccessibilityElement, let view = element as? UIView { view.subviews.forEach(collect) }
        }
        collect(window)
        try XCTSkipIf(labels.isEmpty, "this test host exposes no accessibility tree (not verified here)")
        XCTAssertEqual(labels.filter { $0 == title }.count, 1, "the button is read once, by its title: \(labels)")
        XCTAssertFalse(labels.contains { $0 != title && $0.contains("Power Base") }, "nothing else names the button: \(labels)")
        XCTAssertFalse(labels.contains { $0.lowercased().contains("radiowaves") || $0.contains("전파") || $0.contains("파형") }, "the symbol has no spoken name: \(labels)")
        XCTAssertTrue(labels.contains { $0.contains("2") && $0.contains("두 번째 단계") }, "a step is still read with its number: \(labels)")
    }

    // MARK: - The evidence

    /// Writes the measured widths to `POGO_SCREEN_RENDER_DIR/sheet-icon-widths.tsv` (when set):
    /// the evidence behind the column rule.
    func testMeasureSymbolWidths() throws {
        guard let directory = ProcessInfo.processInfo.environment["POGO_SCREEN_RENDER_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_POGO_SCREEN_RENDER_DIR to write the measurements")
        }
        var lines = ["symbol\t" + Self.categories.map { "\(Int(Self.bodyPointSize(at: $0)))pt" }.joined(separator: "\t") + "\twidth/point size (largest)"]
        // What a 24pt @ScaledMetric(relativeTo: .body) column is at each size.
        let scaled = Self.categories.map { UIFontMetrics(forTextStyle: .body).scaledValue(for: 24, compatibleWith: UITraitCollection(preferredContentSizeCategory: $0)) }
        lines.append("(24pt scaled with .body)\t" + scaled.map { String(format: "%.1f", $0) }.joined(separator: "\t") + "\t-")
        for name in Self.symbols {
            let widths = Self.categories.map { Self.naturalSize(of: SymbolIcon(systemImage: name, style: nil), at: $0).width }
            let ratio = widths.last! / Self.bodyPointSize(at: Self.categories.last!)
            lines.append(name + "\t" + widths.map { String(format: "%.1f", $0) }.joined(separator: "\t") + String(format: "\t%.3f", ratio))
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").appending("\n").write(to: output.appendingPathComponent("sheet-icon-widths.tsv"), atomically: true, encoding: .utf8)
    }
}

/// `SheetIconRow` as it was before 2026-10-08, for the reproduction only: the icon in a column of
/// 24pt scaled with the body text style.
private struct OldSheetIconRow<Content: View>: View {
    let systemImage: String
    @ViewBuilder let content: () -> Content
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 24

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SheetRowLayout.columnSpacing) {
            Text(Image(systemName: systemImage)).foregroundStyle(Color.red)
                .frame(width: iconWidth)
            VStack(alignment: .leading, spacing: SheetRowLayout.titleSpacing) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
