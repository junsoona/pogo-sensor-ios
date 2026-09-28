import SwiftUI

/// Settings › 앱 정보 › 이름에 담긴 뜻: where the name 조각보 (Jogakbo) comes from. Opened only
/// from Settings, never shown by itself.
///
/// Dressed like a jogakbo: colored patches joined by running stitches, in the logo's own colors.
/// The story text is about the traditional cloth, so it keeps the word 조각보; only the heading
/// is the app's name.
struct NameMeaningView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LogoHero()

                Text(verbatim: Brand.appName)
                    .font(.largeTitle.weight(.bold))
                    .fontDesign(.rounded)
                    .accessibilityAddTraits(.isHeader)

                StitchedDivider()

                StoryCard(tint: JogakboPalette.coral) {
                    paragraph(Text("조각보는 자투리 천을 모아 바느질로 이어 만든 한국 전통 보자기입니다. 물건을 싸서 보관하거나 운반하고, 선물을 포장하거나 음식을 덮는 등 일상에서 다양하게 사용했습니다.", comment: "About the name: what a jogakbo is"))
                }
                StoryCard(tint: JogakboPalette.marigold) {
                    paragraph(Text("이 프로젝트의 이름도 여기에서 시작했습니다. 서로 다른 천 조각이 하나의 보자기가 되듯, 여러 센서 모듈이 연결되어 하나의 블록을 이룬다는 뜻을 담았습니다.", comment: "About the name: why the project is named after it"))
                }
                StoryCard(tint: JogakboPalette.leaf) {
                    paragraph(Text("작은 조각들이 모여 하나가 되는 것. 그것이 조각보라는 이름에 담긴 생각입니다.", comment: "About the name: closing sentence"))
                        .fontWeight(.semibold)
                }
            }
            // A comfortable line length, centered, in wide iPad and Mac windows.
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding()
            .padding(.bottom, 24)
        }
        .screenBackground()
        .navigationTitle(Text("이름에 담긴 뜻", comment: "Settings row and screen title: the meaning of the app's name"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Body text that always wraps in full, whatever the text size.
    private func paragraph(_ text: Text) -> some View {
        text
            .font(.body)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The colors of the logo's lettering.
private enum JogakboPalette {
    static let coral = Color(red: 1.00, green: 0.43, blue: 0.43)
    static let marigold = Color(red: 0.99, green: 0.71, blue: 0.08)
    static let leaf = Color(red: 0.34, green: 0.71, blue: 0.43)
    static let patches = [coral, marigold, leaf]
}

/// The running stitch of the logo's lettering.
private let runningStitch = StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [5, 4])

/// The logo, large, on a patchwork of the brand colors. The patches sit behind its white outline,
/// so the outline and the character read against both light and dark backgrounds.
private struct LogoHero: View {
    var body: some View {
        Image(.jogakboLogo)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 380)
            .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
            .padding(.horizontal, 20)
            .padding(.vertical, 26)
            .frame(maxWidth: .infinity)
            .background {
                PatchworkBackdrop()
                    .clipShape(.rect(cornerRadius: PogoTheme.cardCornerRadius))
            }
            .overlay {
                RoundedRectangle(cornerRadius: PogoTheme.cardCornerRadius - 5)
                    .inset(by: 6)
                    .stroke(.white.opacity(0.85), style: runningStitch)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("조각보 로고", comment: "Accessibility label of the Jogakbo logo on the name story screen"))
            .accessibilityAddTraits(.isImage)
    }
}

/// Uneven rows of patches, each outlined by a running stitch, like a jogakbo.
private struct PatchworkBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    /// Row heights and each row's patch widths, as fractions — fixed, so the cloth never shifts.
    private static let rows: [(height: CGFloat, widths: [CGFloat])] = [
        (0.30, [0.24, 0.17, 0.31, 0.28]),
        (0.38, [0.15, 0.33, 0.22, 0.30]),
        (0.32, [0.36, 0.26, 0.38]),
    ]

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(PogoTheme.tile))
            let stitch = Color.white.opacity(colorScheme == .dark ? 0.55 : 0.9)
            var y: CGFloat = 0
            var index = 0
            for row in Self.rows {
                let height = row.height * size.height
                var x: CGFloat = 0
                for width in row.widths {
                    let rect = CGRect(x: x, y: y, width: width * size.width, height: height)
                    let color = JogakboPalette.patches[index % JogakboPalette.patches.count]
                    // Alternate stronger and softer patches, as with scraps of different cloth.
                    let opacity = (colorScheme == .dark ? [0.58, 0.40, 0.49] : [0.40, 0.24, 0.32])[index % 3]
                    context.fill(Path(rect), with: .color(color.opacity(opacity)))
                    context.stroke(Path(roundedRect: rect.insetBy(dx: 4, dy: 4), cornerRadius: 3), with: .color(stitch), style: runningStitch)
                    x += rect.width
                    index += 1
                }
                y += height
                index += 1
            }
        }
        .accessibilityHidden(true)
    }
}

/// Three small patches and a stitched seam between the heading and the story.
private struct StitchedDivider: View {
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(JogakboPalette.patches[index])
                    .frame(width: 12, height: 12)
                    .rotationEffect(.degrees(index == 1 ? 45 : 0))
            }
            Line()
                .stroke(.secondary, style: runningStitch)
                .frame(height: 2)
                .padding(.leading, 4)
        }
        .accessibilityHidden(true)
    }

    private nonisolated struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.minX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
        }
    }
}

/// A paragraph on a card edged with a running stitch, with a colored patch in its corner.
private struct StoryCard<Content: View>: View {
    let tint: Color
    @ViewBuilder let content: Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            // Accessibility sizes keep more of the width for the words.
            .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 14 : 20)
            .padding(.vertical, 18)
            .background(PogoTheme.tile, in: .rect(cornerRadius: PogoTheme.cardCornerRadius))
            .overlay(alignment: .topTrailing) {
                UnevenRoundedRectangle(bottomLeadingRadius: 10, topTrailingRadius: PogoTheme.cardCornerRadius)
                    .fill(tint.opacity(0.85))
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
            }
            .overlay {
                RoundedRectangle(cornerRadius: PogoTheme.cardCornerRadius - 5)
                    .inset(by: 6)
                    .stroke(tint.opacity(0.75), style: runningStitch)
                    .accessibilityHidden(true)
            }
    }
}

#Preview {
    NavigationStack {
        NameMeaningView()
    }
}
