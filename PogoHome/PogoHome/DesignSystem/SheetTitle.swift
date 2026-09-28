import SwiftUI

extension View {
    /// The title of an editor sheet (use together with `SheetTitleRow` as the first row of
    /// the sheet's `Form`).
    ///
    /// Regular text sizes: an inline bar title that shrinks a little instead of truncating —
    /// between the Cancel/Save buttons there is only ~135pt on a 375pt-wide iPhone, which
    /// longer translations ("Añadir habitación") exceed.
    ///
    /// Accessibility text sizes: the Cancel/Save buttons grow with the text and leave no room
    /// for a readable title at all, so the bar keeps only the buttons and `SheetTitleRow`
    /// shows the full title, wrapped, at the top of the content instead.
    func sheetTitle(_ title: LocalizedStringKey) -> some View {
        modifier(SheetTitleModifier(title: title))
    }
}

private struct SheetTitleModifier: ViewModifier {
    let title: LocalizedStringKey
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if dynamicTypeSize.isAccessibilitySize {
                        // Shown in the content by `SheetTitleRow`; an empty principal item keeps
                        // the system from squeezing a truncated copy between the buttons.
                        Color.clear
                            .frame(width: 1, height: 1)
                            .accessibilityHidden(true)
                    } else {
                        Text(title)
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
            }
    }
}

/// The sheet title as the first, scrolling row of an editor `Form` — only at accessibility
/// text sizes (see `sheetTitle(_:)`); renders nothing otherwise.
struct SheetTitleRow: View {
    let title: LocalizedStringKey
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Text(title)
                .font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
        }
    }
}

extension View {
    /// An editor sheet's 취소 and 저장 (use together with `sheetTitle(_:)`).
    ///
    /// iPhone and iPad: in the navigation bar, as sheets there have them. Mac: at the bottom right
    /// as Mac sheets have them, 저장 the default button (Return) and 취소 on Esc — the Mac Catalyst
    /// sheet's bar draws every bar item in a fixed-size circle, which cut "Cancel" to "C…"
    /// whatever its placement, style or label.
    func editorSheetActions(isSaveDisabled: Bool = false, onCancel: @escaping () -> Void, onSave: @escaping () -> Void) -> some View {
        modifier(SheetActions(dismissTitle: "취소", onDismiss: onCancel, save: (onSave, isSaveDisabled)))
    }

    /// A sheet with nothing to save: just 닫기, placed like `editorSheetActions`.
    func sheetCloseAction(_ onClose: @escaping () -> Void) -> some View {
        modifier(SheetActions(dismissTitle: "닫기", onDismiss: onClose, save: nil))
    }
}

private struct SheetActions: ViewModifier {
    let dismissTitle: LocalizedStringKey
    let onDismiss: () -> Void
    let save: (action: () -> Void, isDisabled: Bool)?

    func body(content: Content) -> some View {
        if PlatformSupport.isMacCatalyst {
            // Below the scrolling content, not over it: a bar laid over the list blurred the
            // last footer under the buttons. The list ends at the divider, so its last row
            // scrolls fully into view above it.
            VStack(spacing: 0) {
                content
                Divider()
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    Button(dismissTitle, action: onDismiss)
                        .keyboardShortcut(.cancelAction)
                    if let save {
                        Button("저장", action: save.action)
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                            .disabled(save.isDisabled)
                    }
                }
                .controlSize(.large)
                .padding()
            }
            .background(Color(.systemGroupedBackground))
        } else {
            content
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(dismissTitle, action: onDismiss)
                    }
                    if let save {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("저장", action: save.action)
                                .fontWeight(.semibold)
                                .disabled(save.isDisabled)
                        }
                    }
                }
        }
    }
}
