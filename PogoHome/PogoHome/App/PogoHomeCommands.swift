import SwiftUI

extension FocusedValues {
    /// The key window's navigator (`AppSceneRoot`).
    @Entry var appNavigator: AppNavigator?
}

/// Menu bar items (Mac, iPad with a keyboard) for moving between the tabs: ⌘1–⌘4, and ⌘, for
/// Settings as Mac apps do. They act on the key window only.
struct PogoHomeCommands: Commands {
    @FocusedValue(\.appNavigator) private var navigator

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(String(localized: "설정…", comment: "Menu item: opens the Settings tab")) {
                navigator?.selectedTab = .settings
            }
            .keyboardShortcut(",", modifiers: .command)
            .disabled(navigator == nil)
        }

        CommandMenu(Text("이동", comment: "Menu bar menu for switching tabs")) {
            tabButton("홈", tab: .home, key: "1")
            tabButton("방", tab: .rooms, key: "2")
            tabButton("기기", tab: .devices, key: "3")
            tabButton("설정", tab: .settings, key: "4")
        }
    }

    private func tabButton(_ title: LocalizedStringKey, tab: AppNavigator.Tab, key: KeyEquivalent) -> some View {
        Button(title) {
            navigator?.selectedTab = tab
        }
        .keyboardShortcut(key, modifiers: .command)
        .disabled(navigator == nil)
    }
}
