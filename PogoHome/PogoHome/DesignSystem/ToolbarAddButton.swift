import SwiftUI

/// A tab's "+" toolbar button (방 추가, 기기 추가).
///
/// On the Mac the system draws an icon-only toolbar button's glass as a capsule as wide as the
/// icon — for a narrow "+" a tall, thin ellipse beside the other items. There the item's own
/// background is hidden and the button draws one circle, as tall as the other toolbar items, with
/// the "+" centered in it. iPhone and iPad keep the system's button, which is already round.
///
/// Either way it stays a `Button` with its `Label` title: VoiceOver reads the title, and keyboard
/// focus and activation work as for any toolbar button.
struct ToolbarAddButton: ToolbarContent {
    let title: LocalizedStringKey
    let placement: ToolbarItemPlacement
    let action: () -> Void

    init(_ title: LocalizedStringKey, placement: ToolbarItemPlacement, action: @escaping () -> Void) {
        self.title = title
        self.placement = placement
        self.action = action
    }

    var body: some ToolbarContent {
        #if targetEnvironment(macCatalyst)
        ToolbarItem(placement: placement) {
            Button(action: action) {
                Label(title, systemImage: "plus")
            }
            .buttonStyle(CircularToolbarButtonStyle())
        }
        .sharedBackgroundVisibility(.hidden)
        #else
        ToolbarItem(placement: placement) {
            Button(title, systemImage: "plus", action: action)
        }
        #endif
    }
}

#if targetEnvironment(macCatalyst)
/// An icon in a glass circle the height of the Mac toolbar's other items (the "더 보기" menu).
private struct CircularToolbarButtonStyle: ButtonStyle {
    /// The Mac toolbar's item height, in points.
    static let diameter: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.body.weight(.medium))
            .foregroundStyle(.primary)
            .frame(width: Self.diameter, height: Self.diameter)
            .contentShape(.circle)
            .glassEffect(.regular.interactive(), in: .circle)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
#endif
