import SwiftUI
import UIKit

// One set of rules for every tab and detail screen on iPhone, iPad and Mac: who owns the title,
// what fills the background, and where an empty state sits.
//
// Titles, by role:
// - the app's name (조각보 홈): the system's — menu bar, Dock, window list — never in the content;
// - the home's name and the screen titles (방, 기기, 설정): a tab's root title (`tabRootTitle`);
// - a room's or device's name: its detail screen's title (`detailTitle`) — the navigation title
//   when pushed, the heading of the detail pane beside a list.
// Each tab has exactly one navigation stack; nothing nests a split view in the sidebar-adaptable
// `TabView` (see `ListDetailLayout`), so the Mac title bar and the iPad top bar are laid out the
// same way for every tab.

/// Where a detail screen (a room, a device) is shown.
enum DetailPlacement {
    /// Pushed on a navigation stack: its name is the navigation title.
    case screen
    /// In the detail pane beside a list (`ListDetailLayout`): the stack keeps the tab's title and
    /// the name heads the pane.
    case pane
}

extension EnvironmentValues {
    @Entry var detailPlacement: DetailPlacement = .screen
}

extension View {
    /// Fills all the space it's given with the canvas, under the bars too — every screen's and
    /// pane's background, so a short list or an empty state never leaves a patch of another color.
    func screenBackground() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PogoTheme.canvas)
    }

    /// A `List` or `Form` on the canvas instead of its own background.
    func listScreenBackground() -> some View {
        scrollContentBackground(.hidden)
            .screenBackground()
    }

    /// A tab's root title: the home's name, 방, 기기, 설정 — on iPhone and iPad the large title under
    /// the bar, the same for every tab and both layouts of a tab; on the Mac, the window's title
    /// bar beside the sidebar.
    func tabRootTitle(_ title: Text) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
    }

    /// A room's or device's name as its detail screen's title, with the screen's actions (편집,
    /// 다시 읽기): in the navigation bar when pushed, in the pane's header beside a list.
    func detailTitle<Actions: View>(_ title: String, @ViewBuilder actions: () -> Actions) -> some View {
        modifier(DetailTitle(title: title, actions: actions()))
    }

    func detailTitle(_ title: String) -> some View {
        detailTitle(title) { EmptyView() }
    }

    /// A row of `ListDetailList`: a tap (or ↑/↓ in the list) shows `value` in the pane, and the
    /// row stays marked while it's shown. Marked by the app rather than by `List(selection:)`,
    /// whose highlight a list in a navigation stack clears every time it reappears — after a
    /// pushed screen or another tab — while the pane still shows the item.
    func listDetailRow<Value: Hashable>(_ value: Value, selection: Binding<Value?>) -> some View {
        modifier(ListDetailRow(value: value, selection: selection))
    }
}

private struct ListDetailRow<Value: Hashable>: ViewModifier {
    @Environment(\.isListDetailListFocused) private var isListFocused
    @Environment(\.focusListDetailList) private var focusList
    let value: Value
    @Binding var selection: Value?

    func body(content: Content) -> some View {
        let isSelected = selection == value
        content
            .contentShape(.rect)
            // A gesture, not a button: a control inside the row (an Apple Home device's power
            // icon) keeps working by itself.
            .onTapGesture {
                select()
                focusList()
            }
            .listRowBackground(
                // Stronger while the list has keyboard focus, so it's clear where ↑/↓ go.
                PogoTheme.tile.overlay(Color.accentColor.opacity(isSelected ? (isListFocused ? 0.3 : 0.15) : 0))
            )
            // `ListDetailList` scrolls to this when ↑/↓ select it.
            .id(value)
            // The row puts these on its own label element (`listDetailRowAccessibility()`), not on
            // every element in it: an Apple Home row's power button keeps its own action.
            .environment(\.listDetailRowAccessibility, ListDetailRowAccessibility(isSelected: isSelected, select: select))
    }

    /// Choosing the row that's already shown changes nothing: the pane isn't rebuilt, and an
    /// Apple Home device isn't read again.
    private func select() {
        if selection != value { selection = value }
    }
}

/// A `listDetailRow`'s selection state and action, for VoiceOver.
struct ListDetailRowAccessibility {
    var isSelected: Bool
    var select: () -> Void
}

extension View {
    /// Marks the row's label element as a button, selected while the pane shows the row, whose
    /// activation selects it. Nothing outside a `listDetailRow`.
    func listDetailRowAccessibility() -> some View {
        modifier(ListDetailRowAccessibilityModifier())
    }
}

private struct ListDetailRowAccessibilityModifier: ViewModifier {
    @Environment(\.listDetailRowAccessibility) private var row

    func body(content: Content) -> some View {
        if let row {
            content
                .accessibilityAddTraits(row.isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { row.select() }
        } else {
            content
        }
    }
}

extension EnvironmentValues {
    @Entry var listDetailRowAccessibility: ListDetailRowAccessibility?
    /// Whether the `ListDetailList` around a row has keyboard focus.
    @Entry var isListDetailListFocused = false
    /// Gives the `ListDetailList` around a row keyboard focus (after a click on a row).
    @Entry var focusListDetailList: () -> Void = {}
}

/// Where ↑/↓ lead in a list of selectable values: the neighbor in `order`, stopping at either end;
/// from nothing (or a value that's gone), the first value going down and the last going up.
/// `nil` only for an empty list.
nonisolated enum ListDetailNavigation {
    static func value<Value: Hashable>(after current: Value?, moving offset: Int, in order: [Value]) -> Value? {
        guard !order.isEmpty else { return nil }
        guard let current, let index = order.firstIndex(of: current) else {
            return offset < 0 ? order.last : order.first
        }
        return order[min(max(index + offset, 0), order.count - 1)]
    }
}

/// The list column of `ListDetailLayout`, with the Mac's (and a hardware keyboard's) list keys:
/// ↑/↓ move the selection through `order` — the rows' own order — and the pane follows; the
/// selected row scrolls into view. A click on a row, coming back from a pushed screen and
/// switching back to the tab all give the list the keys, as a Mac sidebar has them.
struct ListDetailList<Value: Hashable, Content: View>: View {
    @Binding var selection: Value?
    /// Every value a row selects, in the order the rows appear.
    let order: [Value]
    @ViewBuilder let content: Content
    /// Whether ↑/↓ come to this list (`ListKeyReceiver` is the window's key target).
    @State private var hasKeys = false
    /// Bumped to ask `ListKeyReceiver` to take the keys.
    @State private var keyRequest = 0

    var body: some View {
        ScrollViewReader { proxy in
            List {
                content
            }
            .listStyle(.insetGrouped)
            .listScreenBackground()
            .background {
                ListKeyReceiver(request: keyRequest, hasKeys: $hasKeys) { offset in
                    move(by: offset)
                }
            }
            .onChange(of: selection) { _, value in
                guard let value else { return }
                // No anchor: scrolls only as far as needed, and not at all for a visible row.
                withAnimation(.snappy) { proxy.scrollTo(value) }
            }
            .environment(\.isListDetailListFocused, hasKeys)
            .environment(\.focusListDetailList, { keyRequest += 1 })
            .onAppear {
                // Back from a pushed screen or another tab: the list takes the keys again.
                keyRequest += 1
            }
        }
    }

    private func move(by offset: Int) {
        guard let next = ListDetailNavigation.value(after: selection, moving: offset, in: order),
              next != selection else { return }
        selection = next
    }
}

/// Takes ↑/↓ for `ListDetailList`. SwiftUI's focus (`focusable`, `@FocusState`) can't do it on the
/// Mac: the tab sidebar keeps the keyboard focus, so a click on a row left ↓ switching tabs, and
/// the first key press only woke the focus up. This view, filling the list's background, becomes
/// the first responder and the focused item on request, handles only ↑/↓, and passes every other
/// key on; it lets go as soon as anything else (a sidebar row, a text field) takes the focus.
private struct ListKeyReceiver: UIViewRepresentable {
    let request: Int
    @Binding var hasKeys: Bool
    let onMove: (Int) -> Void

    func makeUIView(context: Context) -> ReceiverView {
        ReceiverView()
    }

    func updateUIView(_ view: ReceiverView, context: Context) {
        view.onMove = onMove
        view.onKeysChange = { hasKeys in
            if self.hasKeys != hasKeys { self.hasKeys = hasKeys }
        }
        if view.lastRequest != request {
            view.lastRequest = request
            // After this layout pass, so the view is in its window.
            DispatchQueue.main.async { view.takeKeys() }
        }
    }

    final class ReceiverView: UIView {
        var onMove: ((Int) -> Void)?
        var onKeysChange: ((Bool) -> Void)?
        var lastRequest = 0

        override init(frame: CGRect) {
            super.init(frame: frame)
            focusEffect = nil
            isAccessibilityElement = false
        }

        required init?(coder: NSCoder) { nil }

        // Rows and their controls get the clicks; this view only listens to the keyboard (it stays
        // interaction-enabled, which focus requires).
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

        override var canBecomeFirstResponder: Bool { true }
        override var canBecomeFocused: Bool { true }

        /// A request that came while the view was out of its window — while a pushed screen
        /// covered the list, or during a relayout — to carry out once it's back.
        private var wantsKeys = false

        func takeKeys(isRetry: Bool = false) {
            guard window != nil else {
                wantsKeys = true
                return
            }
            wantsKeys = false
            // Coming back from a pushed screen: when the pop finishes, UIKit hands keyboard focus
            // to the tab sidebar, so the list takes the keys only after that.
            if let coordinator = runningTransition() {
                coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                    DispatchQueue.main.async { self?.takeKeys() }
                }
                return
            }
            becomeFirstResponder()
            if let focusSystem = UIFocusSystem.focusSystem(for: self) {
                focusSystem.requestFocusUpdate(to: self)
                focusSystem.updateFocusIfNeeded()
            }
            // A focus update already under way (UIKit's own, after a transition) ignores the
            // request; ask once more when it's done.
            if !isRetry, UIFocusSystem.focusSystem(for: self)?.focusedItem != nil, !isFocused {
                DispatchQueue.main.async { self.takeKeys(isRetry: true) }
            }
            reportKeys()
        }

        private func runningTransition() -> UIViewControllerTransitionCoordinator? {
            var responder: UIResponder? = next
            while let current = responder {
                if let controller = current as? UIViewController {
                    return controller.navigationController?.transitionCoordinator ?? controller.transitionCoordinator
                }
                responder = current.next
            }
            return nil
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, wantsKeys else { return }
            // After the transition that brought the list back has put its views in place.
            DispatchQueue.main.async { self.takeKeys() }
        }

        override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
            super.didUpdateFocus(in: context, with: coordinator)
            reportKeys()
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            DispatchQueue.main.async { self.reportKeys() }
            return resigned
        }

        private func reportKeys() {
            onKeysChange?(isFirstResponder || isFocused)
        }

        private func offset(for presses: Set<UIPress>) -> Int? {
            guard presses.count == 1, let key = presses.first?.key, key.modifierFlags.isDisjoint(with: [.command, .control, .alternate]) else {
                return nil
            }
            switch key.keyCode {
            case .keyboardUpArrow: return -1
            case .keyboardDownArrow: return 1
            default: return nil
            }
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if let offset = offset(for: presses) {
                onMove?(offset)
            } else {
                super.pressesBegan(presses, with: event)
            }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if offset(for: presses) == nil { super.pressesEnded(presses, with: event) }
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if offset(for: presses) == nil { super.pressesCancelled(presses, with: event) }
        }
    }
}

private struct DetailTitle<Actions: View>: ViewModifier {
    @Environment(\.detailPlacement) private var placement
    let title: String
    let actions: Actions

    func body(content: Content) -> some View {
        switch placement {
        case .screen:
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        actions
                    }
                }
        case .pane:
            // A bar, not an overlay: the pane's content starts below it and scrolls under it with
            // the system's scroll edge effect, as under the navigation bar.
            content
                .safeAreaBar(edge: .top, spacing: 0) {
                    PaneHeader(title: title, actions: actions)
                }
        }
    }
}

/// The detail pane's title row: the selected room's or device's name at the content's leading
/// edge, its actions trailing in the toolbar's glass style.
private struct PaneHeader<Actions: View>: View {
    let title: String
    let actions: Actions

    var body: some View {
        ZStack(alignment: .leading) {
            // As tall as one action button whether or not the pane has any, so the title sits at
            // the same height in every pane.
            Button("편집") {}
                .hidden()
                .accessibilityHidden(true)
            HStack(alignment: .center, spacing: 12) {
                Text(verbatim: title)
                    .font(.title2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 8) {
                    actions
                }
            }
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

/// An empty state filling a screen or pane: nothing selected, nothing to show, waiting for the
/// connection, a room or device that's gone, no Apple Home access. Centered in the space the
/// title, bars and pane header leave, at most `PogoTheme.emptyStateMaxWidth` wide; it scrolls
/// instead of clipping at large text sizes or in a short window.
struct CenteredEmptyState<Content: View>: View {
    @ViewBuilder let content: Content
    /// The scroll view's height minus its insets (bars, pane header, safe area).
    @State private var visibleHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: PogoTheme.emptyStateMaxWidth)
                .padding(.horizontal)
                .frame(maxWidth: .infinity, minHeight: visibleHeight)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.containerSize.height
        } action: { _, height in
            visibleHeight = max(height, 0)
        }
        .screenBackground()
    }
}

/// Wide iPad and Mac windows: a list beside the selected item's detail, both inside the tab's one
/// navigation stack — its title and toolbar belong to the tab, the pane is headed by the selected
/// item's name, and a device opened from the pane is pushed on the same stack like everywhere else.
///
/// Not a `NavigationSplitView`: nested in the sidebar-adaptable `TabView`, one becomes a second
/// sidebar. On the Mac, once shown it changed the window's title bar for every tab of that window
/// (titles slid over the sidebar's top edge, one tab's title stayed on another, white bands beside
/// the detail); on iPad it added a second sidebar button and a list column cut off square under the
/// status bar.
struct ListDetailLayout<ListContent: View, Detail: View>: View {
    /// The list column's width at the default text size; grows with Dynamic Type, capped.
    @ScaledMetric private var listWidth: CGFloat
    @ViewBuilder let list: ListContent
    @ViewBuilder let detail: Detail

    init(listWidth: CGFloat, @ViewBuilder list: () -> ListContent, @ViewBuilder detail: () -> Detail) {
        _listWidth = ScaledMetric(wrappedValue: listWidth, relativeTo: .body)
        self.list = list()
        self.detail = detail()
    }

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: min(listWidth, PogoTheme.listColumnMaximumWidth))
            Divider()
            detail
                .environment(\.detailPlacement, .pane)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .screenBackground()
    }
}
