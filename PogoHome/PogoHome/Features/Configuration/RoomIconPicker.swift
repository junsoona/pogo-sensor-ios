import SwiftUI

/// A reusable, categorized SF Symbol grid shared by room creation and room editing. Always
/// embedded directly in a parent `Form`/`View` — never presented as its own sheet or pushed
/// navigation destination — so selecting an icon can never dismiss whatever sheet hosts it
/// or reset sibling `@State` (e.g. a name `TextField`) the way an `onAppear`-driven picker
/// screen could (see `ModuleEditorSheet.hasLoadedInitialValues` for the sibling bug this
/// mirrors and avoids).
struct RoomIconPicker: View {
    @Binding var selection: String
    /// The circle (and tap target) size, following Dynamic Type — clamped so it never drops
    /// below the 44pt minimum touch target at small text sizes, and stops growing at a size
    /// where two circles still fit side by side on the narrowest iPhone form row.
    @ScaledMetric(relativeTo: .body) private var scaledCellSize: CGFloat = 48
    static let minimumCellSize: CGFloat = 44
    static let maximumCellSize: CGFloat = 76
    private let spacing: CGFloat = 12

    private var cellSize: CGFloat {
        min(max(scaledCellSize, Self.minimumCellSize), Self.maximumCellSize)
    }

    /// Backward compatibility: a room's previously-saved icon might not be in the current
    /// catalog at all (an older catalog, or a value that was never validated). It's still
    /// shown, highlighted, and kept selected until the user actively picks a different one —
    /// switching categories or opening the picker must never silently discard it.
    private var effectiveSelection: String {
        SymbolAvailability.resolvedName(for: selection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !RoomIconCatalog.allSymbolNames.contains(selection) {
                currentSelectionRow
            }
            ForEach(RoomIconCatalog.categories) { category in
                VStack(alignment: .leading, spacing: 8) {
                    Text(category.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    EvenColumnGrid(cellSize: cellSize, spacing: spacing) {
                        ForEach(category.icons, id: \.symbolName) { icon in
                            iconButton(for: icon.symbolName, label: Text(icon.suggestedRoomName))
                        }
                    }
                }
            }
        }
    }

    /// Surfaces a persisted-but-uncataloged icon (or one the OS can't render, already routed
    /// to `square.dashed` by `effectiveSelection`) as its own selected entry, instead of the
    /// grid appearing to have nothing highlighted at all.
    private var currentSelectionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("현재 아이콘")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            iconButton(for: effectiveSelection, label: Text("현재 아이콘"))
                .frame(width: cellSize, height: cellSize)
        }
    }

    /// Selection is shown by the filled circle plus an inset ring, both drawn inside the
    /// circle, and announced via the `.isSelected` trait. VoiceOver reads the room name the
    /// icon suggests (e.g. "거실") instead of the SF Symbol's file name.
    private func iconButton(for symbol: String, label: Text) -> some View {
        let isSelected = effectiveSelection == symbol
        return Button {
            selection = symbol
        } label: {
            IconCircleShape(
                systemName: symbol,
                diameter: cellSize,
                background: isSelected ? AnyShapeStyle(Color.blue) : AnyShapeStyle(Color(.tertiarySystemFill)),
                foreground: isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.primary)
            )
            .overlay {
                if isSelected {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.85), lineWidth: 2)
                        .padding(3)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    @Previewable @State var selection = "sofa.fill"
    Form {
        Section("아이콘") {
            RoomIconPicker(selection: $selection)
        }
    }
}
